local helpers = require 'tests.helpers'

return {
    {
        name = 'FIM transport separates one cycle from parallel requests and releases its shared file',
        run = function()
            local key_name = 'MINUET_FIM_TRANSPORT_TEST_KEY'
            local original_api_key = vim.env[key_name]
            local original_tempname = vim.fn.tempname
            local request_path
            local group

            local ok, err = xpcall(function()
                vim.env[key_name] = 'fixture-key'
                local mock = vim.fn.getcwd() .. '/tests/scripts/mock_openai_stream.sh'
                helpers.setup_root_config {
                    curl_cmd = mock,
                    n_completions = 3,
                    provider = 'openai_fim_compatible',
                    provider_options = {
                        openai_fim_compatible = {
                            api_key = key_name,
                            end_point = 'completion',
                            model = 'fixture-model',
                            name = 'Fixture',
                            stream = true,
                            get_text_fn = {
                                stream = function(json)
                                    return json.choices[1].delta.content
                                end,
                            },
                        },
                    },
                }

                local metrics = helpers.reload 'minuet.metrics'
                metrics._reset()
                metrics.setup {}
                local cycle_id = metrics.begin_cycle {
                    channel = 'completion',
                    frontend = 'virtualtext',
                    provider_id = 'openai_fim_compatible',
                }

                vim.fn.tempname = function()
                    request_path = original_tempname()
                    return request_path
                end

                local started = {}
                local finished = {}
                group = vim.api.nvim_create_augroup('MinuetFimTransportSpec', { clear = true })
                vim.api.nvim_create_autocmd('User', {
                    group = group,
                    pattern = 'MinuetRequestStarted',
                    callback = function(args)
                        started[#started + 1] = args.data
                    end,
                })
                vim.api.nvim_create_autocmd('User', {
                    group = group,
                    pattern = 'MinuetRequestFinished',
                    callback = function(args)
                        finished[#finished + 1] = args.data
                    end,
                })

                local callbacks = {}
                local backend = helpers.reload 'minuet.backends.openai_fim_compatible'
                backend.complete({
                    lines_before = '',
                    lines_after = '',
                    opts = {
                        is_incomplete_before = false,
                        is_incomplete_after = false,
                    },
                }, function(items)
                    callbacks[#callbacks + 1] = vim.deepcopy(items or {})
                    if items and next(items) then
                        metrics.cycle_has_result(cycle_id)
                    end
                end, {
                    cycle_id = cycle_id,
                    frontend = 'virtualtext',
                })

                helpers.wait_until(function()
                    return metrics.get().channels.completion.requests.finished == 3
                end, 3000, 'parallel FIM requests did not all finish')

                local stats = metrics.get().channels.completion
                helpers.expect_equal(stats.cycles.started, 1)
                helpers.expect_equal(stats.cycles.with_result, 1)
                helpers.expect_equal(stats.requests.attempted, 3)
                helpers.expect_equal(stats.requests.started, 3)
                helpers.expect_equal(stats.requests.finished, 3)
                helpers.expect_equal(stats.requests.outcomes.success, 3)
                helpers.expect_equal(stats.latency_ms.request.samples, 3)
                helpers.expect_equal(#callbacks, 3)
                helpers.expect_equal(#callbacks[#callbacks], 3)
                helpers.expect_equal(#started, 3)
                helpers.expect_equal(#finished, 3)

                local request_ids = {}
                for _, event in ipairs(finished) do
                    helpers.expect_equal(event.cycle_id, cycle_id)
                    helpers.expect_equal(event.status, 'success')
                    request_ids[event.request_id] = true
                end
                helpers.expect_equal(vim.tbl_count(request_ids), 3)
                helpers.expect_truthy(request_path)
                helpers.expect_falsy(vim.uv.fs_stat(request_path), 'parallel FIM requests leaked their shared file')

                metrics._reset()
            end, debug.traceback)

            vim.env[key_name] = original_api_key
            vim.fn.tempname = original_tempname
            if group then
                pcall(vim.api.nvim_del_augroup_by_id, group)
            end
            if request_path then
                pcall(vim.uv.fs_unlink, request_path)
            end

            if not ok then
                error(err)
            end
        end,
    },
}
