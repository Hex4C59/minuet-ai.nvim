local helpers = require 'tests.helpers'

return {
    {
        name = 'lualine ignores late and duplicate finishes while preserving legacy events',
        run = function()
            helpers.setup_root_config()
            package.loaded['lualine.component'] = {
                extend = function()
                    return {
                        super = {
                            init = function(instance, options)
                                instance.options = options or {}
                            end,
                        },
                    }
                end,
            }

            local component = helpers.reload 'minuet.lualine'
            local instance = setmetatable({}, { __index = component })
            instance:init {
                spinner_symbols = { '-', '+' },
            }

            local function event(pattern, data)
                vim.api.nvim_exec_autocmds('User', {
                    pattern = pattern,
                    data = data,
                })
            end

            event('MinuetRequestStartedPre', {
                cycle_id = 1,
                n_requests = 2,
                name = 'Old',
                model = 'old-model',
            })
            event('MinuetRequestStarted', { cycle_id = 1, request_id = 1 })
            helpers.expect_truthy(instance.processing)

            event('MinuetRequestStartedPre', {
                cycle_id = 2,
                n_requests = 1,
                provider_id = 'openai',
            })
            event('MinuetRequestStarted', { cycle_id = 2, request_id = 2 })
            event('MinuetRequestFinished', { cycle_id = 1, request_id = 1 })
            helpers.expect_truthy(instance.processing, 'an old cycle stopped the current spinner')
            helpers.expect_equal(instance.n_finished_requests, 0)

            event('MinuetRequestFinished', { cycle_id = 2, request_id = 2 })
            event('MinuetRequestFinished', { cycle_id = 2, request_id = 2 })
            helpers.expect_falsy(instance.processing)
            helpers.expect_equal(instance.n_finished_requests, 1)

            event('MinuetRequestStartedPre', { n_requests = 1 })
            event('MinuetRequestStarted', {})
            helpers.expect_truthy(instance.processing)
            helpers.expect_match(instance:update_status(), 'Minuet')
            event('MinuetRequestFinished', {})
            helpers.expect_falsy(instance.processing)

            pcall(vim.api.nvim_del_augroup_by_name, 'MinuetLualine')
            package.loaded['lualine.component'] = nil
        end,
    },
}
