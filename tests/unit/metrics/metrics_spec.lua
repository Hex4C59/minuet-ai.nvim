local helpers = require 'tests.helpers'

local function fresh_metrics(config)
    local previous = package.loaded['minuet.metrics']
    if previous and previous._reset then
        previous._reset()
    end

    helpers.setup_root_config { metrics = config or {} }
    local metrics = helpers.reload 'minuet.metrics'
    metrics._reset()
    metrics.setup(config or {})
    return metrics
end

local function completion_meta(overrides)
    return vim.tbl_extend('force', {
        channel = 'completion',
        frontend = 'virtualtext',
        provider_id = 'openai_fim_compatible',
        provider = 'openai_fim_compatible',
        name = 'Fixture',
        model = 'fixture-model',
        n_requests = 1,
    }, overrides or {})
end

return {
    {
        name = 'metrics allocates strictly increasing cycle and request IDs',
        run = function()
            local metrics = fresh_metrics()
            local first_cycle = metrics.begin_cycle(completion_meta())
            local second_cycle = metrics.begin_cycle(completion_meta())
            local first_request = metrics.request_attempted(first_cycle, 1)
            local second_request = metrics.request_attempted(second_cycle, 1)

            helpers.expect_equal(second_cycle, first_cycle + 1)
            helpers.expect_equal(second_request, first_request + 1)

            metrics.setup { enabled = true }
            local third_cycle = metrics.begin_cycle(completion_meta())
            helpers.expect_equal(third_cycle, second_cycle + 1, 'setup must not reset ID watermarks')
            helpers.expect_equal(metrics.get().channels.completion.cycles.started, 3)
            metrics._reset()
        end,
    },
    {
        name = 'metrics separates one FIM cycle from three transport requests',
        run = function()
            local metrics = fresh_metrics()
            local cycle_id = metrics.begin_cycle(completion_meta { n_requests = 3 })
            metrics.configure_cycle(cycle_id, completion_meta { n_requests = 3 })

            local statuses = { 'success', 'timeout', 'spawn_error' }
            for index, status in ipairs(statuses) do
                local request_id = metrics.request_attempted(cycle_id, index)
                if status ~= 'spawn_error' then
                    metrics.request_started(request_id)
                end
                metrics.request_finished(request_id, { status = status })
            end
            metrics.cycle_has_result(cycle_id)

            local completion = metrics.get().channels.completion
            helpers.expect_equal(completion.cycles.started, 1)
            helpers.expect_equal(completion.cycles.with_result, 1)
            helpers.expect_equal(completion.requests.attempted, 3)
            helpers.expect_equal(completion.requests.started, 2)
            helpers.expect_equal(completion.requests.finished, 3)
            helpers.expect_equal(completion.requests.outcomes.success, 1)
            helpers.expect_equal(completion.requests.outcomes.timeout, 1)
            helpers.expect_equal(completion.requests.outcomes.spawn_error, 1)
            helpers.expect_equal(completion.latency_ms.request.samples, 2)
            metrics._reset()
        end,
    },
    {
        name = 'metrics aggregates every terminal request status',
        run = function()
            local metrics = fresh_metrics()
            local statuses = {
                'success',
                'partial',
                'timeout',
                'cancelled',
                'transport_error',
                'invalid_response',
                'empty_response',
                'spawn_error',
            }
            local cycle_id = metrics.begin_cycle(completion_meta { n_requests = #statuses })

            for index, status in ipairs(statuses) do
                local request_id = metrics.request_attempted(cycle_id, index)
                if status ~= 'spawn_error' then
                    metrics.request_started(request_id)
                end
                metrics.request_finished(request_id, { status = status })
            end

            local requests = metrics.get().channels.completion.requests
            helpers.expect_equal(requests.finished, #statuses)
            for _, status in ipairs(statuses) do
                helpers.expect_equal(requests.outcomes[status], 1, 'incorrect outcome count for ' .. status)
            end
            metrics._reset()
        end,
    },
    {
        name = 'metrics deduplicates finishes and suggestion lifecycle kinds',
        run = function()
            local metrics = fresh_metrics()
            local cycle_id = metrics.begin_cycle(completion_meta())
            local request_id = metrics.request_attempted(cycle_id, 1)
            metrics.request_started(request_id)

            helpers.expect_truthy(metrics.request_finished(request_id, { status = 'success' }))
            helpers.expect_falsy(metrics.request_finished(request_id, { status = 'timeout' }))
            helpers.expect_truthy(metrics.suggestion_event(cycle_id, 'preview_shown'))
            helpers.expect_falsy(metrics.suggestion_event(cycle_id, 'preview_shown'))
            helpers.expect_truthy(metrics.suggestion_event(cycle_id, 'accepted'))
            helpers.expect_falsy(metrics.suggestion_event(cycle_id, 'accepted'))

            local completion = metrics.get().channels.completion
            helpers.expect_equal(completion.requests.finished, 1)
            helpers.expect_equal(completion.requests.outcomes.success, 1)
            helpers.expect_equal(completion.requests.outcomes.timeout, 0)
            helpers.expect_equal(completion.cycles.preview_shown, 1)
            helpers.expect_equal(completion.cycles.accepted, 1)
            helpers.expect_equal(completion.cycles.accepted_visible, 1)
            helpers.expect_equal(completion.visible_acceptance_rate, 1)
            metrics._reset()
        end,
    },
    {
        name = 'metrics reports whether a cycle still has unfinished transport requests',
        run = function()
            local metrics = fresh_metrics()
            local cycle_id = metrics.begin_cycle(completion_meta())
            helpers.expect_falsy(metrics.cycle_has_pending_requests(cycle_id))

            local request_id = metrics.request_attempted(cycle_id, 1)
            helpers.expect_truthy(metrics.cycle_has_pending_requests(cycle_id))
            metrics.request_started(request_id)
            helpers.expect_truthy(metrics.cycle_has_pending_requests(cycle_id))
            metrics.request_finished(request_id, { status = 'success' })
            helpers.expect_falsy(metrics.cycle_has_pending_requests(cycle_id))
            helpers.expect_falsy(metrics.cycle_has_pending_requests(-1))
            metrics._reset()
        end,
    },
    {
        name = 'metrics accepted_visible is the intersection regardless of event order',
        run = function()
            local metrics = fresh_metrics()
            local hidden_accept = metrics.begin_cycle(completion_meta())
            local accepted_first = metrics.begin_cycle(completion_meta())
            local shown_only = metrics.begin_cycle(completion_meta())

            metrics.suggestion_event(hidden_accept, 'accepted')
            metrics.suggestion_event(accepted_first, 'accepted')
            metrics.suggestion_event(accepted_first, 'preview_shown')
            metrics.suggestion_event(shown_only, 'preview_shown')

            local completion = metrics.get().channels.completion
            helpers.expect_equal(completion.cycles.accepted, 2)
            helpers.expect_equal(completion.cycles.preview_shown, 2)
            helpers.expect_equal(completion.cycles.accepted_visible, 1)
            helpers.expect_equal(completion.visible_acceptance_rate, 0.5)
            metrics._reset()
        end,
    },
    {
        name = 'metrics records allowlisted filtered and reverted lifecycle events once',
        run = function()
            local metrics = fresh_metrics()
            local filtered = metrics.begin_cycle(completion_meta { channel = 'duet', frontend = 'duet' })
            local accepted = metrics.begin_cycle(completion_meta { channel = 'duet', frontend = 'duet' })
            helpers.expect_truthy(metrics.suggestion_event(filtered, 'filtered', 'no_op'))
            helpers.expect_falsy(metrics.suggestion_event(filtered, 'filtered', 'repeat'))
            metrics.suggestion_event(accepted, 'preview_shown')
            metrics.suggestion_event(accepted, 'accepted')
            helpers.expect_truthy(metrics.suggestion_event(accepted, 'reverted'))
            helpers.expect_falsy(metrics.suggestion_event(accepted, 'reverted'))

            local cycles = metrics.get().channels.duet.cycles
            helpers.expect_equal(cycles.filtered, 1)
            helpers.expect_equal(cycles.reverted, 1)
            helpers.expect_equal(cycles.accepted_visible, 1)
            metrics._reset()
        end,
    },
    {
        name = 'metrics get returns a deep aggregate snapshot',
        run = function()
            local metrics = fresh_metrics()
            metrics.begin_cycle(completion_meta())

            local snapshot = metrics.get()
            snapshot.channels.completion.cycles.started = 99
            snapshot.channels.completion.requests.outcomes.success = 99
            snapshot.session.started_at = 0

            local next_snapshot = metrics.get()
            helpers.expect_equal(next_snapshot.channels.completion.cycles.started, 1)
            helpers.expect_equal(next_snapshot.channels.completion.requests.outcomes.success, 0)
            helpers.expect_truthy(next_snapshot.session.started_at > 0)
            metrics._reset()
        end,
    },
    {
        name = 'metrics bounds recent latency samples and evicts old cycle state',
        run = function()
            local metrics = fresh_metrics {
                max_tracked_cycles = 2,
                max_latency_samples = 2,
            }
            local old_cycle = metrics.begin_cycle(completion_meta { n_requests = 3 })
            local old_request = metrics.request_attempted(old_cycle, 1)
            metrics.request_started(old_request)

            for index = 2, 4 do
                local request_id = metrics.request_attempted(old_cycle, index)
                metrics.request_started(request_id)
                metrics.request_finished(request_id, {
                    status = 'success',
                    ended_ns = vim.uv.hrtime() + index * 1000000,
                })
            end

            metrics.begin_cycle(completion_meta())
            metrics.begin_cycle(completion_meta())
            metrics.request_finished(old_request, { status = 'success' })
            metrics.suggestion_event(old_cycle, 'stale', 'superseded')

            local snapshot = metrics.get()
            local latency = snapshot.channels.completion.latency_ms.request
            helpers.expect_equal(latency.samples, 3)
            helpers.expect_equal(latency.retained, 2)
            helpers.expect_truthy(latency.p50 ~= nil)
            helpers.expect_truthy(latency.p95 ~= nil)
            helpers.expect_truthy(latency.max >= latency.p95)
            helpers.expect_equal(snapshot.dropped_late_events, 2)
            metrics._reset()
        end,
    },
    {
        name = 'metrics disabled mode keeps IDs and public events but returns empty aggregates',
        run = function()
            local metrics = fresh_metrics {
                enabled = false,
                jsonl = { enabled = true },
            }
            local group = vim.api.nvim_create_augroup('MinuetMetricsDisabledSpec', { clear = true })
            local events = {}
            local ok, err = xpcall(function()
                vim.api.nvim_create_autocmd('User', {
                    group = group,
                    pattern = 'Minuet*',
                    callback = function(args)
                        events[#events + 1] = { match = args.match, data = args.data }
                    end,
                })

                local cycle_id = metrics.begin_cycle(completion_meta())
                local next_cycle_id = metrics.begin_cycle(completion_meta())
                metrics.configure_cycle(cycle_id, completion_meta())
                metrics.configure_cycle(cycle_id, completion_meta())
                local request_id = metrics.request_attempted(cycle_id, 1)
                metrics.request_started(request_id)
                metrics.request_finished(request_id, { status = 'success', reason = 'raw secret error' })
                metrics.suggestion_event(cycle_id, 'preview_shown')

                helpers.expect_equal(next_cycle_id, cycle_id + 1)
                helpers.expect_equal(#events, 4)
                helpers.expect_equal(events[1].match, 'MinuetRequestStartedPre')
                helpers.expect_equal(events[2].match, 'MinuetRequestStarted')
                helpers.expect_equal(events[3].match, 'MinuetRequestFinished')
                helpers.expect_equal(events[4].match, 'MinuetSuggestionLifecycle')
                helpers.expect_equal(events[3].data.status, 'success')
                helpers.expect_falsy(events[3].data.reason)
                helpers.expect_falsy(events[3].data.prompt)

                local snapshot = metrics.get()
                helpers.expect_falsy(snapshot.enabled)
                helpers.expect_equal(snapshot.channels.completion.cycles.started, 0)
                helpers.expect_equal(snapshot.channels.completion.requests.attempted, 0)
            end, debug.traceback)

            pcall(vim.api.nvim_del_augroup_by_id, group)
            metrics._reset()
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics isolates public autocmd errors and notifies at most once',
        run = function()
            local metrics = fresh_metrics()
            local notifications, restore_notifications = helpers.capture_notifications()
            local group = vim.api.nvim_create_augroup('MinuetMetricsErrorSpec', { clear = true })
            local ok, err = xpcall(function()
                vim.api.nvim_create_autocmd('User', {
                    group = group,
                    pattern = 'Minuet*',
                    callback = function()
                        error 'event fixture failure'
                    end,
                })

                local cycle_id = metrics.begin_cycle(completion_meta())
                helpers.expect_truthy(metrics.configure_cycle(cycle_id, completion_meta()))
                local request_id = metrics.request_attempted(cycle_id, 1)
                helpers.expect_truthy(metrics.request_started(request_id))
                helpers.expect_truthy(metrics.request_finished(request_id, { status = 'success' }))
                helpers.expect_equal(#notifications, 1)
            end, debug.traceback)

            pcall(vim.api.nvim_del_augroup_by_id, group)
            restore_notifications()
            metrics._reset()
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics leaves the filesystem untouched when JSONL is disabled',
        run = function()
            local directory = vim.fn.tempname()
            local path = directory .. '/metrics.jsonl'
            local metrics = fresh_metrics {
                jsonl = {
                    enabled = false,
                    path = path,
                },
            }

            local cycle_id = metrics.begin_cycle(completion_meta())
            metrics.configure_cycle(cycle_id, completion_meta())
            metrics._flush()

            helpers.expect_falsy(vim.uv.fs_stat(directory))
            metrics._reset()
            vim.fn.delete(directory, 'rf')
        end,
    },
    {
        name = 'metrics JSONL uses scalar allowlists and removes sensitive sentinels',
        run = function()
            local sentinel = 'METRICS_PRIVATE_SENTINEL_9f17'
            local directory = vim.fn.tempname()
            local path = directory .. '/metrics.jsonl'
            local metrics
            local flushed = false

            local ok, err = xpcall(function()
                metrics = fresh_metrics {
                    jsonl = {
                        enabled = true,
                        path = path,
                        flush_interval = 60000,
                        max_queue = 64,
                        max_file_size = 1024 * 1024,
                    },
                }

                local cycle_id = metrics.begin_cycle {
                    channel = 'duet',
                    frontend = 'duet',
                    provider_id = sentinel,
                    provider = sentinel,
                    name = sentinel,
                    model = sentinel,
                    n_requests = 1,
                    prompt = sentinel,
                    path = sentinel,
                }
                metrics.configure_cycle(cycle_id, {
                    provider_id = sentinel,
                    name = sentinel,
                    model = sentinel,
                    response = sentinel,
                })
                local request_id = metrics.request_attempted(cycle_id, 1)
                metrics.request_started(request_id)
                metrics.request_finished(request_id, {
                    status = 'success',
                    reason = sentinel,
                    raw_error = sentinel,
                })
                metrics.cycle_has_result(cycle_id)
                metrics.suggestion_event(cycle_id, 'preview_shown', sentinel)

                local filtered_cycle = metrics.begin_cycle {
                    channel = 'duet',
                    frontend = 'duet',
                    provider_id = 'openai_compatible',
                }
                metrics.cycle_has_result(filtered_cycle)
                metrics.suggestion_event(filtered_cycle, 'filtered', 'repeat')

                local reverted_cycle = metrics.begin_cycle {
                    channel = 'duet',
                    frontend = 'duet',
                    provider_id = 'openai_compatible',
                }
                metrics.suggestion_event(reverted_cycle, 'preview_shown')
                metrics.suggestion_event(reverted_cycle, 'accepted')
                metrics.suggestion_event(reverted_cycle, 'reverted')
                metrics._flush(function()
                    flushed = true
                end)
                helpers.wait_until(function()
                    return flushed
                end, 2000, 'metrics JSONL flush did not finish')

                local text = table.concat(vim.fn.readfile(path), '\n')
                helpers.expect_falsy(text:find(sentinel, 1, true), 'JSONL leaked a sensitive sentinel')
                helpers.expect_equal(vim.fn.getfperm(directory), 'rwx------')
                helpers.expect_equal(vim.fn.getfperm(path), 'rw-------')

                local allowed = {
                    schema_version = true,
                    session_id = true,
                    event = true,
                    timestamp = true,
                    channel = true,
                    frontend = true,
                    provider_id = true,
                    cycle_id = true,
                    request_id = true,
                    n_requests = true,
                    request_idx = true,
                    status = true,
                    reason = true,
                    duration_ms = true,
                    elapsed_ms = true,
                }
                local saw_custom_provider = false
                local saw_repeat_filter = false
                local saw_reverted = false
                for _, line in ipairs(vim.fn.readfile(path)) do
                    local record = vim.json.decode(line)
                    for key, value in pairs(record) do
                        helpers.expect_truthy(allowed[key], 'unexpected JSONL key: ' .. key)
                        helpers.expect_truthy(type(value) ~= 'table', 'JSONL values must be scalar')
                    end
                    saw_custom_provider = saw_custom_provider or record.provider_id == 'custom'
                    saw_repeat_filter = saw_repeat_filter or (record.event == 'filtered' and record.reason == 'repeat')
                    saw_reverted = saw_reverted or record.event == 'reverted'
                end
                helpers.expect_truthy(saw_custom_provider)
                helpers.expect_truthy(saw_repeat_filter)
                helpers.expect_truthy(saw_reverted)
            end, debug.traceback)

            if metrics then
                metrics._reset()
            end
            vim.fn.delete(directory, 'rf')
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics disables JSONL after a write failure without disrupting record calls',
        run = function()
            local metrics
            local notifications, restore_notifications = helpers.capture_notifications()
            local flushed = false

            local ok, err = xpcall(function()
                metrics = fresh_metrics {
                    jsonl = {
                        enabled = true,
                        path = '/dev/null/minuet-metrics.jsonl',
                        flush_interval = 60000,
                    },
                }

                local cycle_id = metrics.begin_cycle(completion_meta())
                metrics.configure_cycle(cycle_id, completion_meta())
                metrics._flush(function()
                    flushed = true
                end)
                helpers.wait_until(function()
                    return flushed
                end, 2000, 'failed JSONL flush did not release its callback')

                helpers.expect_equal(#notifications, 1)
                helpers.expect_truthy(pcall(metrics.cycle_has_result, cycle_id))
                helpers.expect_truthy(pcall(metrics.suggestion_event, cycle_id, 'preview_shown'))
                metrics._flush()
                helpers.expect_equal(#notifications, 1)
            end, debug.traceback)

            if metrics then
                metrics._reset()
            end
            restore_notifications()
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics bounds the JSONL queue and reports dropped records once',
        run = function()
            local directory = vim.fn.tempname()
            local path = directory .. '/metrics.jsonl'
            local metrics
            local notifications, restore_notifications = helpers.capture_notifications()

            local ok, err = xpcall(function()
                metrics = fresh_metrics {
                    jsonl = {
                        enabled = true,
                        path = path,
                        flush_interval = 60000,
                        max_queue = 1,
                    },
                }
                local cycle_id = metrics.begin_cycle(completion_meta())
                metrics.configure_cycle(cycle_id, completion_meta())
                metrics.request_attempted(cycle_id, 1)

                helpers.expect_equal(metrics.get().dropped_log_records, 2)
                helpers.expect_equal(#notifications, 1)
            end, debug.traceback)

            if metrics then
                metrics._reset()
            end
            restore_notifications()
            vim.fn.delete(directory, 'rf')
            if not ok then
                error(err)
            end
        end,
    },
}
