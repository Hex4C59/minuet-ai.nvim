local helpers = require 'tests.helpers'

---@param run fun(fixture: table)
local function with_cursor_tab(run)
    local original_mode = vim.fn.mode
    local original_pumvisible = vim.fn.pumvisible
    local original_recording = vim.fn.reg_recording
    local original_executing = vim.fn.reg_executing
    local original_cmdwin = vim.fn.getcmdwintype
    local original_virtualedit = vim.o.virtualedit
    local bufnr
    local duet
    local virtualtext

    local ok, err = xpcall(function()
        helpers.setup_root_config {
            provider = 'test_fim',
            debounce = 5,
            throttle = 0,
            virtualtext = {
                show_on_completion_menu = true,
            },
            duet = {
                provider = 'test_duet',
                editable_region = {
                    lines_before = 0,
                    lines_after = 0,
                },
                recent_edits = {
                    enabled = false,
                },
                auto_trigger = {
                    enabled = true,
                    debounce = 15,
                    throttle = 0,
                    on_insert_leave = true,
                    after_accept = true,
                    max_buffer_size = 1000000,
                    enable_predicates = {},
                },
            },
        }

        local fim_requests = {}
        local duet_requests = {}
        package.loaded['minuet.backends.test_fim'] = {
            complete = function(_, callback, lifecycle)
                fim_requests[#fim_requests + 1] = { callback = callback, lifecycle = lifecycle }
            end,
        }
        package.loaded['minuet.duet.backends.test_duet'] = {
            complete = function(_, callback, lifecycle)
                duet_requests[#duet_requests + 1] = { callback = callback, lifecycle = lifecycle }
            end,
        }

        vim.fn.mode = function()
            return 'i'
        end
        vim.fn.pumvisible = function()
            return 0
        end
        vim.fn.reg_recording = function()
            return ''
        end
        vim.fn.reg_executing = function()
            return ''
        end
        vim.fn.getcmdwintype = function()
            return ''
        end

        vim.o.virtualedit = 'onemore'
        bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
        vim.bo[bufnr].buftype = ''
        duet = helpers.reload 'minuet.duet'
        virtualtext = helpers.reload 'minuet.virtualtext'
        duet.setup()
        virtualtext.setup()

        run {
            bufnr = bufnr,
            duet = duet,
            duet_requests = duet_requests,
            fim_requests = fim_requests,
            tab = helpers.reload 'minuet.tab',
            virtualtext = virtualtext,
        }
    end, debug.traceback)

    pcall(function()
        require('minuet.duet.scheduler').reset()
    end)
    if duet then
        pcall(vim.api.nvim_clear_autocmds, { group = duet.augroup })
    end
    if virtualtext then
        pcall(vim.api.nvim_clear_autocmds, { group = virtualtext.augroup })
    end
    if bufnr then
        helpers.delete_buffer(bufnr)
    end
    vim.fn.mode = original_mode
    vim.fn.pumvisible = original_pumvisible
    vim.fn.reg_recording = original_recording
    vim.fn.reg_executing = original_executing
    vim.fn.getcmdwintype = original_cmdwin
    vim.o.virtualedit = original_virtualedit

    if not ok then
        error(err)
    end
end

local function fire_text_changed(bufnr)
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
end

return {
    {
        name = 'cursor tab keeps a visible FIM owner ahead of automatic Duet',
        run = function()
            with_cursor_tab(function(fixture)
                fixture.virtualtext.action.next()
                fixture.fim_requests[1].callback { ' + 1' }
                helpers.expect_truthy(fixture.virtualtext.action.is_visible())

                fire_text_changed(fixture.bufnr)
                vim.wait(60)
                helpers.expect_equal(#fixture.duet_requests, 0)
                helpers.expect_truthy(fixture.virtualtext.action.is_visible())
                helpers.expect_equal(require('minuet.suggestion').current().source, 'fim')
            end)
        end,
    },
    {
        name = 'cursor tab lets automatic Duet replace pending FIM and fences its late callback',
        run = function()
            with_cursor_tab(function(fixture)
                fixture.virtualtext.action.next()
                helpers.expect_equal(#fixture.fim_requests, 1)
                fire_text_changed(fixture.bufnr)
                helpers.wait_until(function()
                    return #fixture.duet_requests == 1
                end, 500, 'automatic Duet did not replace pending FIM')

                fixture.fim_requests[1].callback { 'late FIM' }
                helpers.expect_falsy(fixture.virtualtext.action.is_visible())
                fixture.duet_requests[1].callback [[<editable_region>
return 2<cursor_position/>
</editable_region>]]
                helpers.wait_until(function()
                    return fixture.duet.action.is_visible()
                end, 500, 'Duet preview did not become visible')
                helpers.expect_equal(require('minuet.suggestion').current().source, 'duet')
            end)
        end,
    },
    {
        name = 'cursor tab blocks automatic FIM while Duet is pending',
        run = function()
            with_cursor_tab(function(fixture)
                fixture.duet.action.predict()
                helpers.expect_equal(#fixture.duet_requests, 1)
                vim.b[fixture.bufnr].minuet_virtual_text_auto_trigger = true
                vim.api.nvim_exec_autocmds('InsertEnter', { buffer = fixture.bufnr })
                vim.wait(60)
                helpers.expect_equal(#fixture.fim_requests, 0)
                helpers.expect_equal(require('minuet.suggestion').current().source, 'duet')
            end)
        end,
    },
    {
        name = 'cursor tab stale race after preflight never writes or invokes late fallback',
        run = function()
            with_cursor_tab(function(fixture)
                fixture.duet.action.predict()
                fixture.duet_requests[1].callback [[<editable_region>
return 2<cursor_position/>
</editable_region>]]
                helpers.wait_until(function()
                    return fixture.duet.action.is_visible()
                end, 500)

                local fallback_calls = 0
                helpers.expect_equal(
                    fixture.tab.accept_or_fallback(function()
                        fallback_calls = fallback_calls + 1
                        return 'fallback'
                    end),
                    ''
                )
                vim.api.nvim_buf_set_lines(fixture.bufnr, 0, -1, false, { 'user changed' })
                helpers.wait_until(function()
                    return require('minuet.suggestion').current() == nil
                end, 500, 'stale scheduled apply did not release the lease')

                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false), { 'user changed' })
                helpers.expect_equal(fallback_calls, 0)
                local cycles = require('minuet.metrics').get().channels.duet.cycles
                helpers.expect_equal(cycles.accepted, 0)
                helpers.expect_equal(cycles.stale, 1)
            end)
        end,
    },
    {
        name = 'cursor tab Duet acceptance schedules exactly one next prediction',
        run = function()
            with_cursor_tab(function(fixture)
                fixture.duet.action.predict()
                fixture.duet_requests[1].callback [[<editable_region>
return 2<cursor_position/>
</editable_region>]]
                helpers.wait_until(function()
                    return fixture.duet.action.is_visible()
                end, 500)

                helpers.expect_equal(fixture.tab.accept_or_fallback 'fallback', '')
                helpers.wait_until(function()
                    return vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[1] == 'return 2'
                end, 500, 'Duet suggestion was not applied')
                helpers.wait_until(function()
                    return #fixture.duet_requests == 2
                end, 500, 'accepted Duet did not schedule the next prediction')
                vim.wait(60)
                helpers.expect_equal(#fixture.duet_requests, 2)
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.accepted, 1)
            end)
        end,
    },
    {
        name = 'cursor tab FIM acceptance schedules exactly one Duet prediction',
        run = function()
            with_cursor_tab(function(fixture)
                fixture.virtualtext.action.next()
                fixture.fim_requests[1].callback { ' + 1' }
                helpers.expect_truthy(fixture.virtualtext.action.is_visible())

                helpers.expect_equal(fixture.tab.accept_or_fallback 'fallback', '')
                helpers.wait_until(function()
                    return vim.api.nvim_buf_get_lines(fixture.bufnr, 0, -1, false)[1] == 'return 1 + 1'
                end, 500, 'FIM suggestion was not applied')
                helpers.wait_until(function()
                    return #fixture.duet_requests == 1
                end, 500, 'accepted FIM did not schedule a Duet prediction')
                vim.wait(60)
                helpers.expect_equal(#fixture.duet_requests, 1)
                helpers.expect_equal(require('minuet.metrics').get().channels.completion.cycles.accepted, 1)
            end)
        end,
    },
}
