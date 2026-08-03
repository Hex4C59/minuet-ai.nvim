local helpers = require 'tests.helpers'

---@param controller table
---@param source 'fim'|'duet'
---@param intent 'manual'|'auto'|'after_accept'
---@param bufnr? integer
local function begin(controller, source, intent, bufnr)
    return controller.begin {
        source = source,
        intent = intent,
        bufnr = bufnr or 1,
        changedtick = 10,
    }
end

---@param overrides? table
local function make_ops(overrides)
    local calls = {
        accept = 0,
        cancel = 0,
        dismiss = 0,
    }
    local ops = {
        cancel = function(reason)
            calls.cancel = calls.cancel + 1
            calls.reason = reason
        end,
        can_accept = function()
            return true
        end,
        accept = function()
            calls.accept = calls.accept + 1
        end,
        dismiss = function(reason, explicit)
            calls.dismiss = calls.dismiss + 1
            calls.reason = reason
            calls.explicit = explicit
        end,
        is_visible = function()
            return true
        end,
    }
    return vim.tbl_extend('force', ops, overrides or {}), calls
end

return {
    {
        name = 'suggestion controller allocates monotonic leases and releases terminal state',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local first = begin(controller, 'fim', 'manual')
            helpers.expect_truthy(first)
            controller.finish(first, 'accepted')

            local second = begin(controller, 'duet', 'manual')
            helpers.expect_truthy(second.id > first.id)
            helpers.expect_truthy(second.generation > first.generation)
            helpers.expect_falsy(controller.is_current(first))
            helpers.expect_truthy(controller.is_current(second))
            helpers.expect_equal(second.prompt, nil)
            helpers.expect_equal(second.response, nil)
        end,
    },
    {
        name = 'suggestion controller enforces pending and visible automatic priority',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local fim = begin(controller, 'fim', 'auto')
            local fim_ops, fim_calls = make_ops()
            controller.attach(fim, fim_ops)

            local duet = begin(controller, 'duet', 'auto')
            helpers.expect_truthy(duet)
            helpers.expect_equal(fim_calls.cancel, 1)
            helpers.expect_equal(fim_calls.reason, 'superseded')
            local duet_ops, duet_calls = make_ops()
            controller.attach(duet, duet_ops)
            controller.mark_visible(duet)

            helpers.expect_equal(begin(controller, 'fim', 'auto'), nil)
            helpers.expect_equal(begin(controller, 'duet', 'after_accept'), nil)
            helpers.expect_equal(duet_calls.cancel, 0)

            local manual = begin(controller, 'fim', 'manual')
            helpers.expect_truthy(manual)
            helpers.expect_equal(duet_calls.cancel, 1)
            helpers.expect_falsy(controller.is_current(duet))
        end,
    },
    {
        name = 'suggestion controller blocks automatic FIM behind pending Duet and fences old generations',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local duet = begin(controller, 'duet', 'auto')
            local ops = make_ops()
            controller.attach(duet, ops)
            helpers.expect_equal(begin(controller, 'fim', 'auto'), nil)

            local replacement = begin(controller, 'duet', 'auto')
            helpers.expect_truthy(replacement)
            helpers.expect_falsy(controller.is_current(duet))
            helpers.expect_falsy(controller.mark_visible(duet))
            helpers.expect_truthy(controller.is_current(replacement))
        end,
    },
    {
        name = 'suggestion controller terminal and buffer invalidation operations are idempotent',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local lease = begin(controller, 'duet', 'manual', 7)
            local ops, calls = make_ops()
            controller.attach(lease, ops)
            controller.mark_visible(lease)

            helpers.expect_falsy(controller.invalidate_buffer(8, 'buffer_changed'))
            helpers.expect_truthy(controller.dismiss(lease))
            helpers.expect_falsy(controller.dismiss(lease))
            helpers.expect_equal(calls.dismiss, 1)
            helpers.expect_equal(calls.explicit, true)
            helpers.expect_equal(controller.current(), nil)

            local next_lease = begin(controller, 'fim', 'manual', 8)
            local next_ops, next_calls = make_ops()
            controller.attach(next_lease, next_ops)
            helpers.expect_truthy(controller.invalidate_buffer(8, 'buffer_unloaded', 'fim'))
            helpers.expect_equal(next_calls.cancel, 1)
            helpers.expect_equal(next_calls.reason, 'buffer_unloaded')
            helpers.expect_falsy(controller.invalidate_buffer(8, 'buffer_unloaded', 'fim'))
        end,
    },
    {
        name = 'suggestion controller failed preflight releases the lease for fallback',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local lease = begin(controller, 'duet', 'manual')
            local ops, calls = make_ops {
                can_accept = function()
                    return false, 'apply_validation'
                end,
            }
            controller.attach(lease, ops)
            controller.mark_visible(lease)

            helpers.expect_falsy(controller.accept_visible())
            helpers.expect_equal(calls.accept, 0)
            helpers.expect_equal(calls.cancel, 1)
            helpers.expect_equal(calls.reason, 'apply_validation')
            helpers.expect_equal(controller.current(), nil)
        end,
    },
    {
        name = 'suggestion controller accepting state suppresses duplicate actions and recovers from errors',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local lease = begin(controller, 'fim', 'manual')
            local ops, calls = make_ops()
            controller.attach(lease, ops)
            controller.mark_visible(lease)

            helpers.expect_truthy(controller.accept_visible())
            helpers.expect_truthy(controller.accept_visible())
            helpers.expect_equal(calls.accept, 1)
            helpers.expect_equal(lease.phase, 'accepting')
            controller.finish(lease, 'accepted')

            local failing = begin(controller, 'duet', 'manual')
            local failing_ops = make_ops {
                accept = function()
                    error 'accept fixture failure'
                end,
            }
            controller.attach(failing, failing_ops)
            controller.mark_visible(failing)
            local ok, err = pcall(controller.accept_visible)
            helpers.expect_falsy(ok)
            helpers.expect_match(err, 'accept fixture failure')
            helpers.expect_equal(controller.current(), nil)
        end,
    },
    {
        name = 'suggestion controller reset cancels the active owner once',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local lease = begin(controller, 'fim', 'manual')
            local ops, calls = make_ops()
            controller.attach(lease, ops)
            controller.reset()
            controller.reset()
            helpers.expect_equal(calls.cancel, 1)
            helpers.expect_equal(controller.current(), nil)
        end,
    },
    {
        name = 'suggestion controller resumes only a current accepting lease after remote focus',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local lease = begin(controller, 'duet', 'manual')
            controller.attach(lease, make_ops())

            helpers.expect_falsy(controller.resume_visible(lease))
            helpers.expect_truthy(controller.mark_visible(lease))
            local generation = lease.generation
            helpers.expect_truthy(controller.mark_accepting(lease))
            helpers.expect_truthy(controller.resume_visible(lease))
            helpers.expect_equal(lease.phase, 'visible')
            helpers.expect_equal(lease.generation, generation)
            helpers.expect_truthy(controller.is_current(lease))

            controller.finish(lease, 'accepted')
            helpers.expect_falsy(controller.resume_visible(lease))
        end,
    },
    {
        name = 'suggestion controller invalidates a cross-buffer lease from either anchor',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local lease = begin(controller, 'duet', 'manual', 7)
            local ops, calls = make_ops()
            controller.attach(lease, ops)
            lease.target_bufnr = 9
            lease.target_changedtick = 11
            lease.cross_buffer = true

            helpers.expect_truthy(controller.invalidate_buffer(9, 'buffer_changed', 'duet'))
            helpers.expect_equal(calls.cancel, 1)

            lease = begin(controller, 'duet', 'manual', 7)
            ops, calls = make_ops()
            controller.attach(lease, ops)
            lease.target_bufnr = 9
            helpers.expect_truthy(controller.invalidate_buffer(7, 'buffer_unloaded', 'duet'))
            helpers.expect_equal(calls.cancel, 1)
        end,
    },
}
