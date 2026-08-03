local helpers = require 'tests.helpers'

---@param controller table
---@param source 'fim'|'duet'
---@param overrides? table
---@return minuet.SuggestionLease, table
local function visible_lease(controller, source, overrides)
    local calls = { accept = 0 }
    local lease = controller.begin {
        source = source,
        intent = 'manual',
        bufnr = 1,
        changedtick = 1,
    }
    local ops = vim.tbl_extend('force', {
        cancel = function() end,
        can_accept = function()
            return true
        end,
        accept = function()
            calls.accept = calls.accept + 1
        end,
        dismiss = function() end,
        is_visible = function()
            return true
        end,
    }, overrides or {})
    controller.attach(lease, ops)
    controller.mark_visible(lease)
    return lease, calls
end

return {
    {
        name = 'tab accepts visible Duet and FIM owners without invoking fallback',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local tab = helpers.reload 'minuet.tab'
            local duet, duet_calls = visible_lease(controller, 'duet')
            local fallback_calls = 0

            helpers.expect_equal(
                tab.accept_or_fallback(function()
                    fallback_calls = fallback_calls + 1
                    return 'fallback'
                end),
                ''
            )
            helpers.expect_equal(duet_calls.accept, 1)
            helpers.expect_equal(fallback_calls, 0)
            controller.finish(duet, 'accepted')

            local fim, fim_calls = visible_lease(controller, 'fim')
            helpers.expect_truthy(tab.accept())
            helpers.expect_equal(fim_calls.accept, 1)
            controller.finish(fim, 'accepted')
        end,
    },
    {
        name = 'tab preserves function string empty and default fallbacks',
        run = function()
            helpers.setup_root_config()
            local tab = helpers.reload 'minuet.tab'
            local calls = 0
            helpers.expect_equal(
                tab.accept_or_fallback(function()
                    calls = calls + 1
                    return 'kept'
                end),
                'kept'
            )
            helpers.expect_equal(calls, 1)
            helpers.expect_equal(tab.accept_or_fallback 'literal', 'literal')
            helpers.expect_equal(
                tab.accept_or_fallback(function()
                    return ''
                end),
                ''
            )
            helpers.expect_equal(tab.accept_or_fallback(), '<Tab>')
        end,
    },
    {
        name = 'tab runs fallback after stale synchronous preflight',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local tab = helpers.reload 'minuet.tab'
            local cancel_reason
            visible_lease(controller, 'duet', {
                can_accept = function()
                    return false, 'apply_validation'
                end,
                cancel = function(reason)
                    cancel_reason = reason
                end,
            })
            local calls = 0
            helpers.expect_equal(
                tab.accept_or_fallback(function()
                    calls = calls + 1
                    return 'fallback'
                end),
                'fallback'
            )
            helpers.expect_equal(calls, 1)
            helpers.expect_equal(cancel_reason, 'apply_validation')
            helpers.expect_equal(controller.current(), nil)
        end,
    },
    {
        name = 'tab accepting state consumes key repeat without scheduling twice',
        run = function()
            helpers.setup_root_config()
            local controller = helpers.reload 'minuet.suggestion'
            local tab = helpers.reload 'minuet.tab'
            local _, calls = visible_lease(controller, 'fim')
            helpers.expect_equal(tab.accept_or_fallback 'fallback', '')
            helpers.expect_equal(tab.accept_or_fallback 'fallback', '')
            helpers.expect_equal(calls.accept, 1)
        end,
    },
    {
        name = 'tab does not swallow fallback errors',
        run = function()
            helpers.setup_root_config()
            local tab = helpers.reload 'minuet.tab'
            local ok, err = pcall(tab.accept_or_fallback, function()
                error 'fallback fixture failure'
            end)
            helpers.expect_falsy(ok)
            helpers.expect_match(err, 'fallback fixture failure')
        end,
    },
}
