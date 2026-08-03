local helpers = require 'tests.helpers'

---@param overrides? table
---@param run fun(fixture: table)
local function with_virtualtext(overrides, run)
    local original_mode = vim.fn.mode
    local original_pumvisible = vim.fn.pumvisible
    local buffers = {}
    local metrics
    local virtualtext

    local ok, err = xpcall(function()
        helpers.setup_root_config(vim.tbl_deep_extend('force', {
            provider = 'test',
            virtualtext = {
                show_on_completion_menu = true,
            },
        }, overrides or {}))

        metrics = helpers.reload 'minuet.metrics'
        metrics._reset()
        metrics.setup {}

        local requests = {}
        package.loaded['minuet.backends.test'] = {
            complete = function(_, callback, lifecycle)
                requests[#requests + 1] = {
                    callback = callback,
                    lifecycle = lifecycle,
                }
            end,
        }

        local menu_visible = false
        vim.fn.mode = function()
            return 'i'
        end
        vim.fn.pumvisible = function()
            return menu_visible and 1 or 0
        end

        virtualtext = helpers.reload 'minuet.virtualtext'
        virtualtext.setup()

        local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
        buffers[#buffers + 1] = bufnr

        run {
            bufnr = bufnr,
            metrics = metrics,
            requests = requests,
            virtualtext = virtualtext,
            create_buffer = function(lines, cursor)
                local new_bufnr = helpers.create_buffer(lines, cursor)
                buffers[#buffers + 1] = new_bufnr
                return new_bufnr
            end,
            set_menu_visible = function(value)
                menu_visible = value
            end,
        }
    end, debug.traceback)

    vim.fn.mode = original_mode
    vim.fn.pumvisible = original_pumvisible
    if virtualtext then
        pcall(vim.api.nvim_clear_autocmds, { group = virtualtext.augroup })
    end
    for _, bufnr in ipairs(buffers) do
        helpers.delete_buffer(bufnr)
    end
    if metrics then
        metrics._reset()
    end

    if not ok then
        error(err)
    end
end

return {
    {
        name = 'virtualtext counts cumulative callbacks and repeated renders once per cycle',
        run = function()
            with_virtualtext(nil, function(fixture)
                fixture.virtualtext.action.next()
                helpers.expect_equal(#fixture.requests, 1)
                helpers.expect_equal(fixture.requests[1].lifecycle.frontend, 'virtualtext')
                helpers.expect_truthy(fixture.requests[1].lifecycle.cycle_id)

                fixture.requests[1].callback { 'alpha', 'beta' }
                fixture.requests[1].callback { 'alpha', 'beta', 'gamma' }
                fixture.virtualtext.action.next()
                fixture.virtualtext.action.prev()

                local cycles = fixture.metrics.get().channels.completion.cycles
                helpers.expect_equal(cycles.started, 1)
                helpers.expect_equal(cycles.with_result, 1)
                helpers.expect_equal(cycles.preview_shown, 1)
                helpers.expect_truthy(fixture.virtualtext.action.is_visible())
            end)
        end,
    },
    {
        name = 'virtualtext suppresses preview metrics while the completion menu is visible',
        run = function()
            with_virtualtext({
                virtualtext = {
                    show_on_completion_menu = false,
                },
            }, function(fixture)
                fixture.virtualtext.action.accept()
                fixture.virtualtext.action.dismiss()
                fixture.set_menu_visible(true)

                fixture.virtualtext.action.next()
                fixture.requests[1].callback { 'hidden' }

                local cycles = fixture.metrics.get().channels.completion.cycles
                helpers.expect_equal(cycles.started, 1)
                helpers.expect_equal(cycles.with_result, 1)
                helpers.expect_equal(cycles.preview_shown, 0)
                helpers.expect_equal(cycles.accepted, 0)
                helpers.expect_equal(cycles.dismissed, 0)
                helpers.expect_falsy(fixture.virtualtext.action.is_visible())
            end)
        end,
    },
    {
        name = 'virtualtext keeps matching typed prefixes and classifies divergence as stale',
        run = function()
            with_virtualtext(nil, function(fixture)
                local group = vim.api.nvim_create_augroup('MinuetVirtualtextLifecycleSpec', { clear = true })
                local reasons = {}
                vim.api.nvim_create_autocmd('User', {
                    group = group,
                    pattern = 'MinuetSuggestionLifecycle',
                    callback = function(args)
                        if args.data.kind == 'stale' then
                            reasons[#reasons + 1] = args.data.reason
                        end
                    end,
                })

                fixture.virtualtext.action.next()
                fixture.requests[1].callback { 'foo' }

                vim.api.nvim_buf_set_lines(fixture.bufnr, 0, -1, false, { 'f ' })
                vim.api.nvim_win_set_cursor(0, { 1, 1 })
                vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = fixture.bufnr, modeline = false })
                helpers.expect_equal(fixture.metrics.get().channels.completion.cycles.stale, 0)
                helpers.expect_truthy(fixture.virtualtext.action.is_visible())

                vim.api.nvim_buf_set_text(fixture.bufnr, 0, 1, 0, 1, { 'x' })
                vim.api.nvim_win_set_cursor(0, { 1, 2 })
                vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = fixture.bufnr, modeline = false })

                helpers.expect_equal(fixture.metrics.get().channels.completion.cycles.stale, 1)
                helpers.expect_equal(reasons, { 'context_changed' })
                helpers.expect_falsy(fixture.virtualtext.action.is_visible())
                pcall(vim.api.nvim_del_augroup_by_id, group)
            end)
        end,
    },
    {
        name = 'virtualtext records acceptance only after the buffer write succeeds',
        run = function()
            with_virtualtext(nil, function(fixture)
                fixture.virtualtext.action.next()
                fixture.requests[1].callback { 'hello' }
                fixture.virtualtext.action.accept()

                helpers.expect_equal(fixture.metrics.get().channels.completion.cycles.accepted, 0)
                helpers.wait_until(function()
                    return vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[1] == 'hello'
                end, 1000, 'virtual text acceptance was not written')

                fixture.virtualtext.action.dismiss()
                fixture.virtualtext.action.next()

                local cycles = fixture.metrics.get().channels.completion.cycles
                helpers.expect_equal(cycles.accepted, 1)
                helpers.expect_equal(cycles.accepted_visible, 1)
                helpers.expect_equal(cycles.dismissed, 0)
                helpers.expect_equal(cycles.stale, 0)
                helpers.expect_equal(#fixture.requests, 2)
            end)
        end,
    },
    {
        name = 'virtualtext automatic cleanup records stale but never explicit dismissal',
        run = function()
            with_virtualtext(nil, function(fixture)
                fixture.virtualtext.action.next()
                fixture.requests[1].callback { 'visible' }
                vim.api.nvim_exec_autocmds('InsertLeave', { buffer = fixture.bufnr, modeline = false })

                local cycles = fixture.metrics.get().channels.completion.cycles
                helpers.expect_equal(cycles.stale, 1)
                helpers.expect_equal(cycles.dismissed, 0)
                helpers.expect_falsy(fixture.virtualtext.action.is_visible())
            end)
        end,
    },
    {
        name = 'virtualtext treats a fully typed matching suggestion as consumed rather than stale',
        run = function()
            with_virtualtext(nil, function(fixture)
                fixture.virtualtext.action.next()
                fixture.requests[1].callback { 'x' }

                vim.api.nvim_buf_set_lines(fixture.bufnr, 0, -1, false, { 'x ' })
                vim.api.nvim_win_set_cursor(0, { 1, 1 })
                vim.api.nvim_exec_autocmds('CursorMovedI', { buffer = fixture.bufnr, modeline = false })

                vim.api.nvim_exec_autocmds('InsertLeave', { buffer = fixture.bufnr, modeline = false })
                fixture.virtualtext.action.next()

                local cycles = fixture.metrics.get().channels.completion.cycles
                helpers.expect_equal(cycles.stale, 0)
                helpers.expect_equal(cycles.dismissed, 0)
                helpers.expect_equal(cycles.started, 2)
            end)
        end,
    },
    {
        name = 'virtualtext deduplicates cycle acceptance across line-wise accepts',
        run = function()
            with_virtualtext(nil, function(fixture)
                fixture.virtualtext.action.next()
                fixture.requests[1].callback { 'one\ntwo' }

                fixture.virtualtext.action.accept_line()
                helpers.wait_until(function()
                    return fixture.metrics.get().channels.completion.cycles.accepted == 1
                end, 1000, 'first line acceptance was not recorded')
                fixture.virtualtext.action.accept_line()
                vim.wait(20)

                helpers.expect_equal(fixture.metrics.get().channels.completion.cycles.accepted, 1)
            end)
        end,
    },
    {
        name = 'virtualtext rejects an old non-empty callback after a newer cycle starts',
        run = function()
            with_virtualtext(nil, function(fixture)
                local group = vim.api.nvim_create_augroup('MinuetVirtualtextSupersededSpec', { clear = true })
                local stale_reason
                vim.api.nvim_create_autocmd('User', {
                    group = group,
                    pattern = 'MinuetSuggestionLifecycle',
                    callback = function(args)
                        if args.data.kind == 'stale' then
                            stale_reason = args.data.reason
                        end
                    end,
                })

                fixture.virtualtext.action.next()
                fixture.virtualtext.action.next()
                helpers.expect_equal(#fixture.requests, 2)

                fixture.requests[1].callback { 'old' }
                helpers.expect_falsy(fixture.virtualtext.action.is_visible())
                fixture.requests[2].callback { 'new' }

                local cycles = fixture.metrics.get().channels.completion.cycles
                helpers.expect_equal(cycles.started, 2)
                helpers.expect_equal(cycles.with_result, 2)
                helpers.expect_equal(cycles.stale, 1)
                helpers.expect_equal(cycles.preview_shown, 1)
                helpers.expect_equal(stale_reason, 'superseded')
                helpers.expect_truthy(fixture.virtualtext.action.is_visible())
                pcall(vim.api.nvim_del_augroup_by_id, group)
            end)
        end,
    },
    {
        name = 'virtualtext keeps a callback associated with its originating buffer',
        run = function()
            with_virtualtext(nil, function(fixture)
                fixture.virtualtext.action.next()
                local second_bufnr = fixture.create_buffer({ 'second' }, { 1, 0 })

                fixture.requests[1].callback { 'first-only' }

                helpers.expect_equal(vim.api.nvim_get_current_buf(), second_bufnr)
                helpers.expect_falsy(fixture.virtualtext.action.is_visible())
                vim.api.nvim_set_current_buf(fixture.bufnr)
                helpers.expect_falsy(fixture.virtualtext.action.is_visible())

                local cycles = fixture.metrics.get().channels.completion.cycles
                helpers.expect_equal(cycles.with_result, 1)
                helpers.expect_equal(cycles.preview_shown, 0)
                helpers.expect_equal(cycles.stale, 1)
            end)
        end,
    },
    {
        name = 'virtualtext explicit dismiss is idempotent and suppresses late stale classification',
        run = function()
            with_virtualtext(nil, function(fixture)
                fixture.virtualtext.action.next()
                fixture.virtualtext.action.dismiss()
                fixture.virtualtext.action.dismiss()
                fixture.requests[1].callback { 'late' }

                local cycles = fixture.metrics.get().channels.completion.cycles
                helpers.expect_equal(cycles.dismissed, 1)
                helpers.expect_equal(cycles.stale, 0)
                helpers.expect_equal(cycles.preview_shown, 0)
            end)
        end,
    },
}
