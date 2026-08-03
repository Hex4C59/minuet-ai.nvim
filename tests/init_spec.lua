local helpers = require 'tests.helpers'

return {
    {
        name = 'root setup leaves Tab unmapped and automatic Duet disabled by default',
        run = function()
            helpers.ensure_runtime()
            helpers.reset_minuet_modules()
            pcall(vim.api.nvim_del_user_command, 'Minuet')
            local before = vim.fn.maparg('<Tab>', 'i', false, true)
            local minuet = require 'minuet'
            minuet.setup {
                notify = false,
                duet = {
                    recent_edits = {
                        enabled = false,
                    },
                },
                lsp = {
                    completion = { enable = false },
                    inline_completion = { enable = false },
                },
            }

            helpers.expect_equal(vim.fn.maparg('<Tab>', 'i', false, true), before)
            helpers.expect_equal(minuet.config.duet.auto_trigger.enabled, false)
            helpers.expect_falsy(require('minuet.duet.scheduler')._inspect().timer_active)
            helpers.expect_equal(vim.api.nvim_get_autocmds { group = 'MinuetDuetScheduler' }, {})

            require('minuet.duet.scheduler').reset()
            require('minuet.metrics')._reset()
            pcall(vim.api.nvim_del_user_command, 'Minuet')
            for _, name in ipairs {
                'MinuetDuet',
                'MinuetDuetEdits',
                'MinuetDuetScheduler',
                'MinuetLSP',
                'MinuetVirtualText',
            } do
                pcall(vim.api.nvim_del_augroup_by_name, name)
            end
            helpers.reset_minuet_modules()
        end,
    },
    {
        name = 'root Minuet command dispatches private stats and offline report',
        run = function()
            local sentinel = 'COMMAND_PRIVATE_SENTINEL_5d83'
            local notifications, restore_notifications = helpers.capture_notifications()

            local ok, err = xpcall(function()
                helpers.ensure_runtime()
                helpers.reset_minuet_modules()
                pcall(vim.api.nvim_del_user_command, 'Minuet')

                local minuet = require 'minuet'
                minuet.setup {
                    notify = false,
                    provider_options = {
                        openai_compatible = {
                            name = sentinel,
                            model = sentinel,
                        },
                    },
                    duet = {
                        recent_edits = {
                            enabled = false,
                        },
                    },
                    lsp = {
                        completion = {
                            enable = false,
                        },
                        inline_completion = {
                            enable = false,
                        },
                    },
                }

                local completions = vim.fn.getcompletion('Minuet s', 'cmdline')
                helpers.expect_truthy(vim.tbl_contains(completions, 'stats'), 'command completion omitted stats')
                local report_completions = vim.fn.getcompletion('Minuet r', 'cmdline')
                helpers.expect_truthy(
                    vim.tbl_contains(report_completions, 'report'),
                    'command completion omitted report'
                )

                vim.cmd 'Minuet stats'
                local message
                for _, notification in ipairs(notifications) do
                    if
                        type(notification.msg) == 'string' and notification.msg:find('Minuet session metrics', 1, true)
                    then
                        message = notification.msg
                    end
                end

                helpers.expect_truthy(message, 'Minuet stats did not dispatch a summary')
                helpers.expect_truthy(message:find('completion:', 1, true))
                helpers.expect_truthy(message:find('duet:', 1, true))
                helpers.expect_truthy(message:find('visible acceptance n/a', 1, true))
                helpers.expect_falsy(message:find('0.0%', 1, true))
                helpers.expect_falsy(message:find(sentinel, 1, true))

                local missing = vim.fn.tempname() .. '.jsonl'
                vim.cmd('Minuet report ' .. vim.fn.fnameescape(missing))
                local report_message
                for _, notification in ipairs(notifications) do
                    if
                        type(notification.msg) == 'string'
                        and notification.msg:find('Cursor Tab quality report', 1, true)
                    then
                        report_message = notification.msg
                    end
                end
                helpers.expect_truthy(report_message, 'Minuet report did not dispatch a summary')
                helpers.expect_truthy(report_message:find('100 more visible suggestions required', 1, true))
                helpers.expect_falsy(report_message:find(missing, 1, true))
                helpers.expect_falsy(report_message:find(sentinel, 1, true))
            end, debug.traceback)

            local metrics = package.loaded['minuet.metrics']
            if metrics and metrics._reset then
                metrics._reset()
            end
            restore_notifications()
            pcall(vim.api.nvim_del_user_command, 'Minuet')
            for _, name in ipairs {
                'MinuetDuet',
                'MinuetDuetEdits',
                'MinuetDuetScheduler',
                'MinuetLSP',
                'MinuetVirtualText',
            } do
                pcall(vim.api.nvim_del_augroup_by_name, name)
            end
            helpers.reset_minuet_modules()

            if not ok then
                error(err)
            end
        end,
    },
}
