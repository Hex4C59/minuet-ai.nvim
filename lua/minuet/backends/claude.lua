local utils = require 'minuet.utils'
local common = require 'minuet.backends.common'

local M = {}

M.provider_id = 'claude'

M.is_available = function()
    local config = require('minuet').config
    return utils.get_api_key(config.provider_options.claude.api_key) and true or false
end

if not M.is_available() then
    utils.notify('Anthropic API key is not set', 'error', vim.log.levels.ERROR)
end

function M.get_text_fn_no_steam(json)
    return json.content[1].text
end

function M.get_text_fn_stream(json)
    return json.delta.text
end

---@param options table
---@return table
local function make_request_data(options)
    local config = require('minuet').config
    local system = utils.make_system_prompt(options.system, config.n_completions)
    local request_data = {
        system = system,
        max_tokens = options.max_tokens,
        model = options.model,
        stream = options.stream,
    }
    return vim.tbl_deep_extend('force', request_data, options.optional or {})
end

---@param context table
---@param callback fun(items?: string[])
---@param lifecycle? minuet.BackendLifecycle
function M.complete(context, callback, lifecycle)
    local config = require('minuet').config
    local metrics = require 'minuet.metrics'
    local options = vim.deepcopy(config.provider_options.claude)
    local provider_name = 'Claude'
    local cycle_id = common.configure_cycle({
        provider_id = M.provider_id,
        provider = provider_name,
        name = provider_name,
        model = options.model,
        n_requests = 1,
    }, lifecycle)

    common.terminate_all_jobs()

    local built, transformed_data = pcall(function()
        local data = make_request_data(options)
        local ctx = utils.make_chat_llm_shot(context, options.chat_input)
        ctx = common.create_chat_messages_from_list(ctx)
        local few_shots = vim.deepcopy(utils.get_or_eval_value(options.few_shots))
        vim.list_extend(few_shots, ctx)
        data.messages = few_shots

        local headers = {
            ['Content-Type'] = 'application/json',
            ['x-api-key'] = utils.get_api_key(options.api_key),
            ['anthropic-version'] = '2023-06-01',
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
                    provider_name,
                    M.get_text_fn_stream,
                    { notify = not job_state.cancel_requested }
                )
            else
                decoded = utils.no_stream_decode(
                    result,
                    data_file,
                    provider_name,
                    M.get_text_fn_no_steam,
                    { notify = not job_state.cancel_requested }
                )
            end

            metrics.request_finished(request_id, {
                status = job_state.cancel_requested and 'cancelled' or decoded.status,
                reason = job_state.cancel_requested and 'cancelled' or decoded.reason,
                ended_ns = ended_ns,
            })
            lease:release()

            if not decoded.text then
                callback()
                return
            end

            local items = common.parse_completion_items(decoded.text, provider_name)
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

return M
