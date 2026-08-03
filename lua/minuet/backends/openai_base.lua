local M = {}
local common = require 'minuet.backends.common'
local utils = require 'minuet.utils'

function M.openai_get_text_fn_no_stream(json)
    return json.choices[1].message.content
end

function M.openai_get_text_fn_stream(json)
    return json.choices[1].delta.content
end

---@param items string[]
---@param context table
---@return string[]
local function prepare_fim_items(items, context)
    local filtered_items = common.filter_context_sequences_in_items(items, context)
    local non_empty_items = vim.tbl_filter(function(x)
        return type(x) == 'string' and x:find '%S' ~= nil
    end, filtered_items)
    return non_empty_items
end

---@param options table
---@param context table
---@param callback fun(items?: string[])
---@param lifecycle? minuet.BackendLifecycle
function M.complete_openai_base(options, context, callback, lifecycle)
    local config = require('minuet').config
    local metrics = require 'minuet.metrics'
    local provider_id = options.provider_id or 'openai_compatible'
    local provider = options.provider or 'openai_compatible'
    local cycle_id = common.configure_cycle({
        provider_id = provider_id,
        provider = provider,
        name = options.name,
        model = options.model,
        n_requests = 1,
    }, lifecycle)

    common.terminate_all_jobs()

    local built, transformed_data = pcall(function()
        local ctx = utils.make_chat_llm_shot(context, options.chat_input)
        ctx = common.create_chat_messages_from_list(ctx)

        local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))
        local system = utils.make_system_prompt(options.system, config.n_completions)

        table.insert(few_shots, 1, { role = 'system', content = system })
        vim.list_extend(few_shots, ctx)

        local data = {
            model = options.model,
            messages = few_shots,
            stream = options.stream,
        }
        data = vim.tbl_deep_extend('force', data, options.optional or {})

        local headers = {
            ['Content-Type'] = 'application/json',
            ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
        }
        return common.apply_transforms(options.transform, options.end_point, headers, data)
    end)

    if not built or type(transformed_data) ~= 'table' then
        utils.notify('Failed to build completion request.', 'error', vim.log.levels.ERROR)
        callback()
        return
    end

    local data_file, lease = utils.make_tmp_file(transformed_data.body, 1)
    if not data_file or not lease then
        callback()
        return
    end

    local made_args, args = pcall(utils.make_curl_args, transformed_data.end_point, transformed_data.headers, data_file)
    if not made_args then
        lease:discard()
        utils.notify('Failed to build completion request.', 'error', vim.log.levels.ERROR)
        callback()
        return
    end

    local request_id = metrics.request_attempted(cycle_id, 1)
    local state = common.start_job(config.curl_cmd, args, {
        cycle_id = cycle_id,
        on_exit = function(job_state, result, ended_ns)
            local decoded
            if options.stream then
                decoded = utils.stream_decode(
                    result,
                    data_file,
                    options.name,
                    M.openai_get_text_fn_stream,
                    { notify = not job_state.cancel_requested }
                )
            else
                decoded = utils.no_stream_decode(
                    result,
                    data_file,
                    options.name,
                    M.openai_get_text_fn_no_stream,
                    { notify = not job_state.cancel_requested }
                )
            end

            local status = job_state.cancel_requested and 'cancelled' or decoded.status
            local reason = job_state.cancel_requested and 'cancelled' or decoded.reason
            metrics.request_finished(request_id, {
                status = status,
                reason = reason,
                ended_ns = ended_ns,
            })
            lease:release()

            if not decoded.text then
                callback()
                return
            end

            local items = common.parse_completion_items(decoded.text, options.name)
            items = common.filter_context_sequences_in_items(items, context)
            items = utils.trim_completion_items(items)
            callback(items)
        end,
        on_spawn_error = function(ended_ns)
            metrics.request_finished(request_id, {
                status = 'spawn_error',
                reason = 'spawn_error',
                ended_ns = ended_ns,
            })
            lease:release()
            callback()
        end,
    })

    if state then
        metrics.request_started(request_id)
    end
end

---@param options table
---@param get_text_fn fun(json: any): any
---@param context table
---@param callback fun(items?: string[])
---@param lifecycle? minuet.BackendLifecycle
function M.complete_openai_fim_base(options, get_text_fn, context, callback, lifecycle)
    local config = require('minuet').config
    local metrics = require 'minuet.metrics'
    local n_completions = config.n_completions
    local provider_id = options.provider_id or 'openai_fim_compatible'
    local provider = options.provider or 'openai_fim_compatible'
    local cycle_id = common.configure_cycle({
        provider_id = provider_id,
        provider = provider,
        name = options.name,
        model = options.model,
        n_requests = n_completions,
    }, lifecycle)

    common.terminate_all_jobs()

    local built, transformed_data = pcall(function()
        local context_before_cursor = context.lines_before
        local context_after_cursor = context.lines_after
        local opts = context.opts
        local data = {
            model = options.model,
            stream = options.stream,
        }
        data = vim.tbl_deep_extend('force', data, options.optional or {})
        data.prompt = options.template.prompt(context_before_cursor, context_after_cursor, opts)
        data.suffix = options.template.suffix
                and options.template.suffix(context_before_cursor, context_after_cursor, opts)
            or nil

        local headers = {
            ['Content-Type'] = 'application/json',
            ['Accept'] = 'application/json',
            ['Authorization'] = 'Bearer ' .. utils.get_api_key(options.api_key),
        }
        return common.apply_transforms(options.transform, options.end_point, headers, data)
    end)

    if not built or type(transformed_data) ~= 'table' then
        utils.notify('Failed to build completion request.', 'error', vim.log.levels.ERROR)
        callback()
        return
    end

    local data_file, lease = utils.make_tmp_file(transformed_data.body, n_completions)
    if not data_file or not lease then
        callback()
        return
    end

    local made_args, args = pcall(utils.make_curl_args, transformed_data.end_point, transformed_data.headers, data_file)
    if not made_args then
        lease:discard()
        utils.notify('Failed to build completion request.', 'error', vim.log.levels.ERROR)
        callback()
        return
    end

    if n_completions < 1 then
        lease:discard()
        return
    end

    local items = {}
    for idx = 1, n_completions do
        local request_idx = idx
        local request_id = metrics.request_attempted(cycle_id, request_idx)
        local state = common.start_job(config.curl_cmd, args, {
            cycle_id = cycle_id,
            on_exit = function(job_state, result, ended_ns)
                local decoded
                if options.stream then
                    decoded = utils.stream_decode(
                        result,
                        data_file,
                        options.name,
                        get_text_fn,
                        { notify = not job_state.cancel_requested }
                    )
                else
                    decoded = utils.no_stream_decode(
                        result,
                        data_file,
                        options.name,
                        get_text_fn,
                        { notify = not job_state.cancel_requested }
                    )
                end

                local status = job_state.cancel_requested and 'cancelled' or decoded.status
                local reason = job_state.cancel_requested and 'cancelled' or decoded.reason
                metrics.request_finished(request_id, {
                    status = status,
                    reason = reason,
                    ended_ns = ended_ns,
                })
                lease:release()

                if decoded.text then
                    table.insert(items, decoded.text)
                end
                callback(prepare_fim_items(items, context))
            end,
            on_spawn_error = function(ended_ns)
                metrics.request_finished(request_id, {
                    status = 'spawn_error',
                    reason = 'spawn_error',
                    ended_ns = ended_ns,
                })
                lease:release()
                callback(prepare_fim_items(items, context))
            end,
        })

        if state then
            metrics.request_started(request_id)
        end
    end
end

return M
