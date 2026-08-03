local common = require 'minuet.duet.backends.common'
local utils = require 'minuet.duet.utils'

local M = {}

function M.openai_get_text_fn_stream(json)
    return json.choices[1].delta.content
end

---@param options table
---@param context table
---@param callback fun(text?: string)
---@param lifecycle? minuet.DuetBackendLifecycle
function M.complete_openai_base(options, context, callback, lifecycle)
    local root_config = require('minuet').config
    local duet_config = root_config.duet
    local metrics = require 'minuet.metrics'
    local cycle_id = common.configure_cycle({
        provider_id = options.provider_id,
        provider = options.provider,
        name = options.name,
        model = options.model,
        n_requests = 1,
    }, lifecycle)

    local api_key = utils.get_api_key(options.api_key)
    if not api_key then
        utils.notify(options.api_key_error or 'Minuet duet API key is not set.', 'error', vim.log.levels.ERROR)
        callback(nil)
        return
    end

    common.terminate_all_jobs()

    local built, transformed_data = pcall(function()
        local system = utils.make_system_prompt(options.system)
        local prompt = utils.make_duet_llm_shot(context, options.chat_input)
        local messages = vim.deepcopy(utils.get_or_eval_value(options.few_shots) or {})

        table.insert(messages, 1, { role = 'system', content = system })
        table.insert(messages, { role = 'user', content = prompt })

        local data = {
            model = options.model,
            messages = messages,
            stream = true,
        }
        data = vim.tbl_deep_extend('force', data, options.optional or {})

        local headers = {
            ['Content-Type'] = 'application/json',
            ['Authorization'] = 'Bearer ' .. api_key,
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
                options.name,
                M.openai_get_text_fn_stream,
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
