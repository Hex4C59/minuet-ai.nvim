local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.action.predict works through the openai-compatible streaming transport',
        run = function()
            local original_api_key = vim.env.OPENROUTER_API_KEY
            local bufnr

            local ok, err = xpcall(function()
                local mock = vim.fn.getcwd() .. '/tests/scripts/mock_openai_stream.sh'

                vim.env.OPENROUTER_API_KEY = 'test-key'

                helpers.setup_root_config {
                    curl_cmd = mock,
                    duet = {
                        provider = 'openai_compatible',
                        request_timeout = 2,
                        editable_region = {
                            lines_before = 0,
                            lines_after = 0,
                        },
                        provider_options = {
                            openai_compatible = {
                                end_point = [[<editable_region>
return 42<cursor_position/>
</editable_region>]],
                                model = 'fixture-model',
                                name = 'Fixture',
                            },
                        },
                    },
                }

                local duet = helpers.reload 'minuet.duet'
                duet.setup()

                bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

                duet.action.predict()

                helpers.wait_until(function()
                    return duet.action.is_visible()
                end, 3000, 'duet preview did not become visible through the transport test')

                duet.action.apply()

                helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 42' })
                helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 8 })
                helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after apply')

                local stats = require('minuet.metrics').get().channels.duet
                helpers.expect_equal(stats.requests.attempted, 1)
                helpers.expect_equal(stats.requests.started, 1)
                helpers.expect_equal(stats.requests.finished, 1)
                helpers.expect_equal(stats.requests.outcomes.success, 1)
                helpers.expect_equal(stats.cycles.with_result, 1)
                helpers.expect_equal(stats.cycles.preview_shown, 1)
                helpers.expect_equal(stats.cycles.accepted, 1)
            end, debug.traceback)

            vim.env.OPENROUTER_API_KEY = original_api_key
            helpers.delete_buffer(bufnr)

            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'duet transport records spawn error and removes the private request file',
        run = function()
            local key_name = 'MINUET_DUET_SPAWN_TEST_KEY'
            local key_value = 'PRIVATE_SPAWN_KEY_SENTINEL_2c91'
            local original_api_key = vim.env[key_name]
            local original_tempname = vim.fn.tempname
            local request_path
            local bufnr
            local group

            local ok, err = xpcall(function()
                vim.env[key_name] = key_value
                helpers.setup_root_config {
                    curl_cmd = '/minuet-test/command-does-not-exist',
                    duet = {
                        provider = 'openai_compatible',
                        recent_edits = {
                            enabled = false,
                        },
                        editable_region = {
                            lines_before = 0,
                            lines_after = 0,
                        },
                        provider_options = {
                            openai_compatible = {
                                api_key = key_name,
                                end_point = 'https://example.invalid/chat/completions',
                                model = 'fixture-model',
                                name = 'Fixture',
                            },
                        },
                    },
                }

                vim.fn.tempname = function()
                    request_path = original_tempname()
                    return request_path
                end

                local finished_event
                group = vim.api.nvim_create_augroup('MinuetDuetSpawnTransportSpec', { clear = true })
                vim.api.nvim_create_autocmd('User', {
                    group = group,
                    pattern = 'MinuetDuetRequestFinished',
                    callback = function(args)
                        finished_event = args.data
                    end,
                })

                local duet = helpers.reload 'minuet.duet'
                duet.setup()
                bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
                duet.action.predict()

                helpers.wait_until(function()
                    return require('minuet.metrics').get().channels.duet.requests.finished == 1
                end, 2000, 'spawn failure did not produce a terminal request outcome')

                local stats = require('minuet.metrics').get().channels.duet
                helpers.expect_equal(stats.requests.attempted, 1)
                helpers.expect_equal(stats.requests.started, 0)
                helpers.expect_equal(stats.requests.outcomes.spawn_error, 1)
                helpers.expect_equal(finished_event.status, 'spawn_error')
                helpers.expect_equal(finished_event.reason, 'spawn_error')
                helpers.expect_falsy(vim.inspect(finished_event):find(key_value, 1, true))
                helpers.expect_truthy(request_path)
                helpers.expect_falsy(vim.uv.fs_stat(request_path), 'spawn failure leaked the request file')
            end, debug.traceback)

            vim.env[key_name] = original_api_key
            vim.fn.tempname = original_tempname
            if group then
                pcall(vim.api.nvim_del_augroup_by_id, group)
            end
            helpers.delete_buffer(bufnr)
            if request_path then
                pcall(vim.uv.fs_unlink, request_path)
            end

            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'duet transport marks an active job cancelled before its late exit callback',
        run = function()
            helpers.setup_root_config()
            local common = helpers.reload 'minuet.duet.backends.common'
            local exited_state
            local spawn_error = false

            local state = common.start_job('sh', { '-c', 'sleep 0.2; printf late' }, {
                on_exit = function(job_state)
                    exited_state = job_state
                end,
                on_spawn_error = function()
                    spawn_error = true
                end,
            })

            helpers.expect_truthy(state)
            common.terminate_all_jobs()
            helpers.expect_truthy(state.cancel_requested)
            helpers.wait_until(function()
                return exited_state ~= nil
            end, 2000, 'cancelled transport did not deliver its exit callback')

            helpers.expect_falsy(spawn_error)
            helpers.expect_truthy(exited_state.cancel_requested)
            helpers.expect_truthy(exited_state.exited)
            helpers.expect_equal(#common.current_jobs, 0)
        end,
    },
}
