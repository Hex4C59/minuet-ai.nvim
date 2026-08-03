local helpers = require 'tests.helpers'

---@param delayed boolean
---@param run fun(fixture: table)
local function with_semantic_duet(delayed, run)
    helpers.setup_root_config {
        duet = {
            provider = 'semantic_test',
            candidates = {
                cursor = true,
                recent_edits = false,
                diagnostics = false,
                references = true,
                text = true,
                max_candidates = 8,
            },
            editable_region = { lines_before = 0, lines_after = 0 },
            recent_edits = { enabled = false },
            auto_trigger = { enabled = false },
        },
    }
    local semantic_callback
    local cancelled = 0
    package.loaded['minuet.duet.symbols'] = {
        collect = function(_, callback)
            semantic_callback = callback
            if not delayed then
                callback {
                    identifiers = { 'changedCall' },
                    references = { { row = 4, col = 0, name = 'changedCall' } },
                    text_matches = { { row = 4, col = 0, name = 'changedCall' } },
                    definitions = {},
                    symbols = {},
                    timed_out = false,
                }
            end
            return function()
                cancelled = cancelled + 1
            end
        end,
        reset = function() end,
        invalidate = function() end,
    }
    local requests = {}
    package.loaded['minuet.duet.backends.semantic_test'] = {
        complete = function(context, callback)
            requests[#requests + 1] = { context = context, callback = callback }
        end,
    }
    local bufnr = helpers.create_buffer({ 'origin', '', 'middle', '', 'changedCall()' }, { 1, 0 })
    vim.bo[bufnr].buftype = ''
    local duet = helpers.reload 'minuet.duet'
    duet.setup()
    local ok, err = xpcall(function()
        run {
            bufnr = bufnr,
            duet = duet,
            requests = requests,
            semantic_callback = function(value)
                semantic_callback(value)
            end,
            cancelled = function()
                return cancelled
            end,
        }
    end, debug.traceback)
    pcall(vim.api.nvim_clear_autocmds, { group = duet.augroup })
    pcall(function()
        require('minuet.duet.scheduler').reset()
    end)
    helpers.delete_buffer(bufnr)
    if not ok then
        error(err)
    end
end

return {
    {
        name = 'duet semantic reference selects a remote current-buffer region and keeps two-step Tab',
        run = function()
            with_semantic_duet(false, function(fixture)
                helpers.expect_truthy(fixture.duet.action.predict())
                helpers.expect_equal(#fixture.requests, 1)
                helpers.expect_equal(fixture.requests[1].context.original_lines, { 'changedCall()' })
                helpers.expect_match(fixture.requests[1].context.context_evidence, 'Candidate source: reference')
                fixture.requests[1].callback [[<editable_region>
changedCall(1)<cursor_position/>
</editable_region>]]
                helpers.wait_until(function()
                    return fixture.duet.action.is_visible()
                end, 500)
                helpers.expect_truthy(require('minuet.tab').accept())
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 5, 0 })
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 4, 5, false), { 'changedCall()' })
                helpers.expect_truthy(require('minuet.tab').accept())
                helpers.wait_until(function()
                    return vim.api.nvim_buf_get_lines(fixture.bufnr, 4, 5, false)[1] == 'changedCall(1)'
                end, 500)
            end)
        end,
    },
    {
        name = 'duet cancels a pending semantic waiter and fences its late callback',
        run = function()
            with_semantic_duet(true, function(fixture)
                helpers.expect_truthy(fixture.duet.action.predict())
                helpers.expect_equal(#fixture.requests, 0)
                vim.api.nvim_buf_set_lines(fixture.bufnr, 0, 1, false, { 'user edit' })
                vim.api.nvim_exec_autocmds('TextChanged', { buffer = fixture.bufnr })
                helpers.expect_equal(fixture.cancelled(), 1)
                fixture.semantic_callback {
                    identifiers = {},
                    references = {},
                    text_matches = {},
                    definitions = {},
                    symbols = {},
                    timed_out = false,
                }
                helpers.expect_equal(#fixture.requests, 0)
            end)
        end,
    },
}
