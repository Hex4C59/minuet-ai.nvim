local helpers = require 'tests.helpers'

---@param overrides? table
---@param run fun(fixture: table)
local function with_scheduler(overrides, run)
    local original_mode = vim.fn.mode
    local original_pumvisible = vim.fn.pumvisible
    local original_recording = vim.fn.reg_recording
    local original_executing = vim.fn.reg_executing
    local original_cmdwin = vim.fn.getcmdwintype
    local bufnr
    local scheduler

    local ok, err = xpcall(function()
        helpers.setup_root_config(vim.tbl_deep_extend('force', {
            duet = {
                auto_trigger = {
                    enabled = true,
                    debounce = 15,
                    throttle = 0,
                    on_insert_leave = true,
                    after_accept = true,
                    max_buffer_size = 1000000,
                    enable_predicates = {},
                },
                recent_edits = {
                    enabled = 'lazy',
                },
            },
        }, overrides or {}))

        local recorder_setup = 0
        package.loaded['minuet.duet.edits'] = {
            ensure_setup = function()
                recorder_setup = recorder_setup + 1
            end,
        }
        vim.fn.mode = function()
            return 'n'
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

        bufnr = helpers.create_buffer({ 'alpha' }, { 1, 0 })
        vim.bo[bufnr].buftype = ''
        local calls = {}
        scheduler = helpers.reload 'minuet.duet.scheduler'
        scheduler.setup(function(intent)
            calls[#calls + 1] = intent
            scheduler.note_request_started()
            return true
        end)

        run {
            bufnr = bufnr,
            calls = calls,
            scheduler = scheduler,
            recorder_setup = function()
                return recorder_setup
            end,
        }
    end, debug.traceback)

    if scheduler then
        scheduler.reset()
    end
    if bufnr then
        helpers.delete_buffer(bufnr)
    end
    vim.fn.mode = original_mode
    vim.fn.pumvisible = original_pumvisible
    vim.fn.reg_recording = original_recording
    vim.fn.reg_executing = original_executing
    vim.fn.getcmdwintype = original_cmdwin
    vim.o.paste = false

    if not ok then
        error(err)
    end
end

---@param fixture table
---@param text string
local function change(fixture, text)
    vim.api.nvim_buf_set_lines(fixture.bufnr, 0, -1, false, { text })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = fixture.bufnr })
end

return {
    {
        name = 'duet.scheduler disabled mode creates no recorder timer autocmd or request',
        run = function()
            with_scheduler({ duet = { auto_trigger = { enabled = false } } }, function(fixture)
                helpers.expect_equal(fixture.recorder_setup(), 0)
                helpers.expect_falsy(fixture.scheduler._inspect().timer_active)
                helpers.expect_equal(vim.api.nvim_get_autocmds { group = 'MinuetDuetScheduler' }, {})
                vim.api.nvim_exec_autocmds('TextChangedI', { buffer = fixture.bufnr })
                vim.wait(30)
                helpers.expect_equal(#fixture.calls, 0)
            end)
        end,
    },
    {
        name = 'duet.scheduler debounces rapid edits into one automatic prediction',
        run = function()
            with_scheduler(nil, function(fixture)
                helpers.expect_equal(fixture.recorder_setup(), 1)
                change(fixture, 'one')
                change(fixture, 'two')
                change(fixture, 'three')
                helpers.expect_truthy(fixture.scheduler._inspect().timer_active)
                helpers.expect_equal(#fixture.calls, 0)
                helpers.wait_until(function()
                    return #fixture.calls == 1
                end, 500, 'debounced duet prediction did not run')
                helpers.expect_equal(fixture.calls, { 'auto' })
                helpers.expect_falsy(fixture.scheduler._inspect().timer_active)
            end)
        end,
    },
    {
        name = 'duet.scheduler reschedules once for throttle instead of polling',
        run = function()
            with_scheduler({ duet = { auto_trigger = { debounce = 5, throttle = 60 } } }, function(fixture)
                fixture.scheduler.note_request_started()
                change(fixture, 'throttled')
                vim.wait(25)
                helpers.expect_equal(#fixture.calls, 0)
                helpers.expect_truthy(fixture.scheduler._inspect().timer_active)
                helpers.wait_until(function()
                    return #fixture.calls == 1
                end, 500, 'throttled duet prediction did not run')
                vim.wait(80)
                helpers.expect_equal(#fixture.calls, 1)
            end)
        end,
    },
    {
        name = 'duet.scheduler InsertLeave requires a dirty burst and supersedes debounce',
        run = function()
            with_scheduler({ duet = { auto_trigger = { debounce = 1000 } } }, function(fixture)
                vim.api.nvim_exec_autocmds('InsertLeave', { buffer = fixture.bufnr })
                vim.wait(20)
                helpers.expect_equal(#fixture.calls, 0)

                change(fixture, 'dirty')
                vim.api.nvim_exec_autocmds('InsertLeave', { buffer = fixture.bufnr })
                helpers.wait_until(function()
                    return #fixture.calls == 1
                end, 500, 'InsertLeave did not trigger a dirty prediction')
                helpers.expect_equal(fixture.calls[1], 'auto')
            end)
        end,
    },
    {
        name = 'duet.scheduler after-accept calls coalesce into one prediction',
        run = function()
            with_scheduler(nil, function(fixture)
                fixture.scheduler.after_accept(fixture.bufnr)
                fixture.scheduler.after_accept(fixture.bufnr)
                helpers.wait_until(function()
                    return #fixture.calls == 1
                end, 500, 'after-accept prediction did not run')
                helpers.expect_equal(fixture.calls, { 'after_accept' })
            end)
        end,
    },
    {
        name = 'duet.scheduler explicit dismiss suppresses the same changedtick only',
        run = function()
            with_scheduler(nil, function(fixture)
                change(fixture, 'dismissed')
                fixture.scheduler.dismissed(fixture.bufnr, vim.api.nvim_buf_get_changedtick(fixture.bufnr))
                vim.wait(50)
                helpers.expect_equal(#fixture.calls, 0)

                change(fixture, 'new generation')
                helpers.wait_until(function()
                    return #fixture.calls == 1
                end, 500, 'new edit did not clear dismiss suppression')
            end)
        end,
    },
    {
        name = 'duet.scheduler rejects popup paste macro and unsafe buffers',
        run = function()
            with_scheduler(nil, function(fixture)
                vim.fn.pumvisible = function()
                    return 1
                end
                change(fixture, 'menu')
                vim.wait(40)
                helpers.expect_equal(#fixture.calls, 0)

                fixture.scheduler.setup(function(intent)
                    fixture.calls[#fixture.calls + 1] = intent
                    return true
                end)
                vim.fn.pumvisible = function()
                    return 0
                end
                vim.o.paste = true
                change(fixture, 'paste')
                vim.wait(40)
                helpers.expect_equal(#fixture.calls, 0)

                fixture.scheduler.setup(function(intent)
                    fixture.calls[#fixture.calls + 1] = intent
                    return true
                end)
                vim.o.paste = false
                vim.fn.reg_recording = function()
                    return 'q'
                end
                change(fixture, 'macro')
                vim.wait(40)
                helpers.expect_equal(#fixture.calls, 0)

                fixture.scheduler.setup(function(intent)
                    fixture.calls[#fixture.calls + 1] = intent
                    return true
                end)
                vim.fn.reg_recording = function()
                    return ''
                end
                vim.bo[fixture.bufnr].binary = true
                change(fixture, 'binary')
                vim.wait(40)
                helpers.expect_equal(#fixture.calls, 0)
            end)
        end,
    },
    {
        name = 'duet.scheduler rejects oversized credential and predicate-failed buffers',
        run = function()
            with_scheduler({ duet = { auto_trigger = { max_buffer_size = 1 } } }, function(fixture)
                change(fixture, 'oversized')
                vim.wait(40)
                helpers.expect_equal(#fixture.calls, 0)
            end)

            with_scheduler({
                duet = {
                    auto_trigger = {
                        enable_predicates = {
                            function()
                                return false
                            end,
                        },
                    },
                },
            }, function(fixture)
                change(fixture, 'predicate')
                vim.wait(40)
                helpers.expect_equal(#fixture.calls, 0)
            end)

            with_scheduler(nil, function(fixture)
                local defaults = require 'minuet.duet.config'
                require('minuet').config.duet.auto_trigger.enable_predicates =
                    vim.deepcopy(defaults.auto_trigger.enable_predicates)
                vim.api.nvim_buf_set_name(fixture.bufnr, '/tmp/minuet-scheduler/.env.local')
                change(fixture, 'credential')
                vim.wait(40)
                helpers.expect_equal(#fixture.calls, 0)
            end)
        end,
    },
    {
        name = 'duet.scheduler buffer leave and repeated setup close pending timers',
        run = function()
            with_scheduler({ duet = { auto_trigger = { debounce = 1000 } } }, function(fixture)
                change(fixture, 'pending')
                helpers.expect_truthy(fixture.scheduler._inspect().timer_active)
                vim.api.nvim_exec_autocmds('BufLeave', { buffer = fixture.bufnr })
                helpers.expect_falsy(fixture.scheduler._inspect().timer_active)

                change(fixture, 'again')
                helpers.expect_truthy(fixture.scheduler._inspect().timer_active)
                fixture.scheduler.setup(function(intent)
                    fixture.calls[#fixture.calls + 1] = intent
                    return true
                end)
                helpers.expect_falsy(fixture.scheduler._inspect().timer_active)
            end)
        end,
    },
    {
        name = 'duet.scheduler applies declarative filetype debounce overrides',
        run = function()
            with_scheduler({
                duet = {
                    auto_trigger = {
                        debounce = 1000,
                        filetype = {
                            lua = { debounce = 5 },
                        },
                    },
                },
            }, function(fixture)
                vim.bo[fixture.bufnr].filetype = 'lua'
                change(fixture, 'filetype policy')
                helpers.wait_until(function()
                    return #fixture.calls == 1
                end, 500, 'filetype debounce override was not applied')
            end)
        end,
    },
}
