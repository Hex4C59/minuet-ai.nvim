local common = require 'minuet.duet.backends.common'
local utils = require 'minuet.duet.utils'

local M = {}

M.provider_id = 'claude'

local function get_text_fn_stream(json)
    return json.delta.text
end

---@param context table
---@param callback fun(text?: string)
---@param lifecycle? minuet.DuetBackendLifecycle
function M.complete(context, callback, lifecycle)
    local root_config = require('minuet').config
    local duet_config = root_config.duet
    local metrics = require 'minuet.metrics'
    local options = vim.deepcopy(duet_config.provider_options.claude)
    local cycle_id = common.configure_cycle({
        provider_id = M.provider_id,
        provider = 'claude',
        name = 'Claude',
        model = options.model,
        n_requests = 1,
    }, lifecycle)
    local api_key = utils.get_api_key(options.api_key)

    if not api_key then
        utils.notify('Minuet duet Anthropic API key is not set.', 'error', vim.log.levels.ERROR)
        callback(nil)
        return
    end

    common.terminate_all_jobs()

    local built, transformed_data = pcall(function()
        local prompt = utils.make_duet_llm_shot(context, options.chat_input)
        local messages = vim.deepcopy(utils.get_or_eval_value(options.few_shots) or {})
        table.insert(messages, { role = 'user', content = prompt })

        local data = {
            model = options.model,
            max_tokens = options.max_tokens,
            system = utils.make_system_prompt(options.system),
            messages = messages,
            stream = true,
        }
        data = vim.tbl_deep_extend('force', data, options.optional or {})

        local headers = {
            ['Content-Type'] = 'application/json',
            ['x-api-key'] = api_key,
            ['anthropic-version'] = '2023-06-01',
        }
        return common.apply_transforms(options.transform, options.end_point, headers, data)
    end)

    if not built or type(transformed_data) ~= 'table' then
        utils.notify('Failed to build duet request.', 'error', vim.log.levels.ERROR)
        callback(nil)
        return
    end

    local data_file, lease = utils.make_tmp_file(transformed_data.body, 1)
    if not data_file or not lease then
        callback(nil)
        return
    end

    local made_args, args = pcall(
        utils.make_curl_args,
        transformed_data.end_point,
        transformed_data.headers,
        data_file,
        duet_config.request_timeout
    )
    if not made_args then
        lease:discard()
        utils.notify('Failed to build duet request.', 'error', vim.log.levels.ERROR)
        callback(nil)
        return
    end

    local request_id = metrics.request_attempted(cycle_id, 1)
    local state = common.start_job(root_config.curl_cmd, args, {
        cycle_id = cycle_id,
        on_exit = function(job_state, result, ended_ns)
            local decoded = utils.stream_decode(
                result,
                data_file,
                'Claude',
                get_text_fn_stream,
                { notify = not job_state.cancel_requested }
            )
            metrics.request_finished(request_id, {
                status = job_state.cancel_requested and 'cancelled' or decoded.status,
                reason = job_state.cancel_requested and 'cancelled' or decoded.reason,
                ended_ns = ended_ns,
            })
            lease:release()
            callback(decoded.text)
        end,
        on_spawn_error = function(ended_ns)
            metrics.request_finished(request_id, {
                status = 'spawn_error',
                reason = 'spawn_error',
                ended_ns = ended_ns,
            })
            lease:release()
            callback(nil)
        end,
    })

    if state then
        metrics.request_started(request_id)
    end
end

return M
