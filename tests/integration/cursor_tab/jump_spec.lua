local helpers = require 'tests.helpers'

---@param overrides? table
---@param run fun(fixture: table)
local function with_remote_candidate(overrides, run)
    local bufnr
    local duet
    local namespace = vim.api.nvim_create_namespace 'minuet-phase2-diagnostic-fixture'

    local ok, err = xpcall(function()
        helpers.setup_root_config(vim.tbl_deep_extend('force', {
            duet = {
                provider = 'phase2_test',
                scope = 'buffer',
                jump_requires_confirmation = true,
                candidates = {
                    cursor = false,
                    recent_edits = false,
                    diagnostics = true,
                    max_candidates = 8,
                },
                editable_region = {
                    lines_before = 0,
                    lines_after = 0,
                },
                recent_edits = {
                    enabled = false,
                },
                auto_trigger = {
                    enabled = false,
                },
                preview = {
                    cursor = '|',
                    jump_text = 'Next edit: line %d',
                    jump_sign = '>>',
                },
            },
        }, overrides or {}))

        local requests = {}
        package.loaded['minuet.duet.backends.phase2_test'] = {
            complete = function(context, callback, lifecycle)
                requests[#requests + 1] = {
                    context = context,
                    callback = callback,
                    lifecycle = lifecycle,
                }
            end,
        }

        bufnr = helpers.create_buffer({
            'local origin = true',
            '',
            'local middle = true',
            '',
            'local target = 1',
            'return target',
        }, { 1, 0 })
        vim.bo[bufnr].buftype = ''
        vim.bo[bufnr].undolevels = -1
        vim.bo[bufnr].undolevels = 1000
        vim.api.nvim_buf_set_name(bufnr, ('/tmp/minuet-phase2-%d.lua'):format(bufnr))
        vim.diagnostic.set(namespace, bufnr, {
            {
                lnum = 4,
                col = 6,
                severity = vim.diagnostic.severity.ERROR,
                message = 'DIAGNOSTIC_SECRET_SENTINEL',
            },
        })

        duet = helpers.reload 'minuet.duet'
        duet.setup()
        run {
            bufnr = bufnr,
            duet = duet,
            namespace = namespace,
            requests = requests,
            tab = helpers.reload 'minuet.tab',
        }
    end, debug.traceback)

    if duet then
        pcall(vim.api.nvim_clear_autocmds, { group = duet.augroup })
    end
    pcall(function()
        require('minuet.duet.scheduler').reset()
    end)
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        pcall(vim.diagnostic.reset, namespace, bufnr)
        helpers.delete_buffer(bufnr)
    end
    package.loaded['minuet.duet.backends.phase2_test'] = nil

    if not ok then
        error(err)
    end
end

---@param fixture table
local function show_remote_edit(fixture)
    helpers.expect_truthy(fixture.duet.action.predict())
    helpers.expect_equal(#fixture.requests, 1)
    helpers.expect_equal(fixture.requests[1].context.original_lines, { 'local target = 1' })
    helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 0 })

    fixture.requests[1].callback [[<editable_region>
local target = 2<cursor_position/>
</editable_region>]]
    helpers.wait_until(function()
        return fixture.duet.action.is_visible()
    end, 500, 'remote Duet preview did not become visible')
end

return {
    {
        name = 'cursor tab remote candidate jumps first and applies only on the second Tab',
        run = function()
            with_remote_candidate(nil, function(fixture)
                show_remote_edit(fixture)
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 0 })
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5], 'local target = 1')

                local preview = require 'minuet.duet.preview'
                local marks = vim.api.nvim_buf_get_extmarks(fixture.bufnr, preview.ns_id, 0, -1, { details = true })
                helpers.expect_equal(#marks, 2)
                helpers.expect_match(vim.inspect(marks), 'Next edit: line 5')
                helpers.expect_match(vim.inspect(marks), 'sign_text = ">>"')
                helpers.expect_falsy(vim.inspect(marks):find('DIAGNOSTIC_SECRET_SENTINEL', 1, true))
                helpers.expect_falsy(vim.inspect(marks):find('local target = 2', 1, true))

                helpers.expect_truthy(fixture.tab.accept())
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 5, 6 })
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5], 'local target = 1')
                local lease = require('minuet.suggestion').current()
                helpers.expect_equal(lease.phase, 'visible')
                helpers.expect_equal(lease.jumped, true)
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.accepted, 0)

                helpers.expect_truthy(fixture.tab.accept())
                helpers.wait_until(function()
                    return vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5] == 'local target = 2'
                end, 500, 'second Tab did not apply the remote edit')
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.accepted, 1)
                helpers.expect_equal(require('minuet.suggestion').current(), nil)

                vim.cmd 'undo'
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5], 'local target = 1')
            end)
        end,
    },
    {
        name = 'cursor tab invalidates a remote suggestion when its diagnostic candidate disappears',
        run = function()
            with_remote_candidate(nil, function(fixture)
                show_remote_edit(fixture)
                vim.diagnostic.reset(fixture.namespace, fixture.bufnr)
                helpers.wait_until(function()
                    return require('minuet.suggestion').current() == nil
                end, 500, 'removed diagnostic did not invalidate the active candidate')

                helpers.expect_equal(#fixture.requests, 1)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5], 'local target = 1')
                helpers.expect_falsy(fixture.duet.action.is_visible())
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.stale, 1)
            end)
        end,
    },
    {
        name = 'cursor tab revalidates after a remote jump and never overwrites a user edit',
        run = function()
            with_remote_candidate(nil, function(fixture)
                show_remote_edit(fixture)
                helpers.expect_truthy(fixture.tab.accept())
                vim.api.nvim_buf_set_lines(fixture.bufnr, 4, 5, false, { 'local target = 99' })

                local fallback_calls = 0
                helpers.expect_equal(
                    fixture.tab.accept_or_fallback(function()
                        fallback_calls = fallback_calls + 1
                        return 'fallback'
                    end),
                    'fallback'
                )
                helpers.expect_equal(fallback_calls, 1)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5], 'local target = 99')
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.accepted, 0)
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.stale, 1)
                helpers.expect_falsy(fixture.duet.action.is_visible())
            end)
        end,
    },
    {
        name = 'cursor tab can opt out of remote jump confirmation',
        run = function()
            with_remote_candidate({
                duet = {
                    jump_requires_confirmation = false,
                },
            }, function(fixture)
                show_remote_edit(fixture)
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 0 })
                helpers.expect_truthy(fixture.tab.accept())
                helpers.wait_until(function()
                    return vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5] == 'local target = 2'
                end, 500, 'single Tab did not apply with confirmation disabled')
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.accepted, 1)
            end)
        end,
    },
    {
        name = 'cursor tab dismisses remote hints before and after jumping without writes',
        run = function()
            with_remote_candidate(nil, function(fixture)
                show_remote_edit(fixture)
                helpers.expect_truthy(fixture.duet.action.dismiss())
                helpers.expect_falsy(fixture.duet.action.is_visible())
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5], 'local target = 1')
            end)
            with_remote_candidate(nil, function(fixture)
                show_remote_edit(fixture)
                helpers.expect_truthy(fixture.tab.accept())
                helpers.expect_truthy(fixture.duet.action.dismiss())
                helpers.expect_falsy(fixture.duet.action.is_visible())
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[5], 'local target = 1')
            end)
        end,
    },
}
