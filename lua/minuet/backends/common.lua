local M = {}
local utils = require 'minuet.utils'

local uv = vim.uv or vim.loop

-- Currently running completion jobs, basically forked curl processes.
---@type minuet.JobState[]
M.current_jobs = {}

---@class minuet.JobState
---@field job vim.SystemObj
---@field pid integer?
---@field cancel_requested boolean
---@field exited boolean
---@field cycle_id? integer

---@param state minuet.JobState
function M.register_job(state)
    table.insert(M.current_jobs, state)
    utils.notify('Registered completion job', 'debug')
end

---@param state minuet.JobState
function M.remove_job(state)
    for i, current in ipairs(M.current_jobs) do
        if current == state then
            table.remove(M.current_jobs, i)
            utils.notify('Completion job finished and removed from current_jobs', 'debug')
            break
        end
    end
end

---@param state minuet.JobState
local function terminate_job(state)
    local ok = pcall(state.job.kill, state.job, 'sigterm')
    if not ok then
        utils.notify('Failed to terminate completion job', 'warn', vim.log.levels.WARN)
        return false
    end

    utils.notify('Terminate completion job', 'debug')

    return true
end

function M.terminate_all_jobs()
    local jobs = vim.list_slice(M.current_jobs)
    for _, state in ipairs(jobs) do
        if not state.exited then
            state.cancel_requested = true
        end
    end

    for _, state in ipairs(jobs) do
        if not state.exited then
            terminate_job(state)
        end
    end
end

---@param cycle_id integer
function M.terminate_cycle(cycle_id)
    local jobs = vim.list_slice(M.current_jobs)
    for _, state in ipairs(jobs) do
        if state.cycle_id == cycle_id and not state.exited then
            state.cancel_requested = true
        end
    end

    for _, state in ipairs(jobs) do
        if state.cycle_id == cycle_id and not state.exited then
            terminate_job(state)
        end
    end
end

---@class minuet.JobHandlers
---@field on_exit fun(state: minuet.JobState, result: vim.SystemCompleted, ended_ns: number)
---@field on_spawn_error? fun(ended_ns: number)
---@field cycle_id? integer

---@param command string
---@param args string[]
---@param handlers minuet.JobHandlers
---@return minuet.JobState?
function M.start_job(command, args, handlers)
    local cmd = { command }
    vim.list_extend(cmd, args)

    ---@type minuet.JobState?
    local state
    local exited = false
    local ok, result = pcall(vim.system, cmd, { text = true }, function(out)
        local ended_ns = uv.hrtime()
        exited = true
        if state then
            state.exited = true
        end
        vim.schedule(function()
            if not state then
                return
            end

            M.remove_job(state)
            handlers.on_exit(state, out, ended_ns)
        end)
    end)

    if not ok or type(result) ~= 'table' then
        local ended_ns = uv.hrtime()
        utils.notify('Failed to start completion job.', 'error', vim.log.levels.ERROR)
        if handlers.on_spawn_error then
            handlers.on_spawn_error(ended_ns)
        end
        return nil
    end

    ---@cast result vim.SystemObj
    state = {
        job = result,
        pid = result.pid,
        cancel_requested = false,
        exited = exited,
        cycle_id = handlers.cycle_id,
    }
    M.register_job(state)

    return state
end

---@class minuet.BackendCycleMeta
---@field provider_id string
---@field provider string
---@field name? string
---@field model? string
---@field n_requests integer

---@class minuet.BackendLifecycle
---@field cycle_id? integer
---@field frontend? string

---@param meta minuet.BackendCycleMeta
---@param lifecycle? minuet.BackendLifecycle
---@return integer cycle_id
function M.configure_cycle(meta, lifecycle)
    local metrics = require 'minuet.metrics'
    lifecycle = type(lifecycle) == 'table' and lifecycle or {}
    local cycle_id = lifecycle.cycle_id

    if type(cycle_id) ~= 'number' or cycle_id ~= math.floor(cycle_id) or cycle_id < 1 then
        cycle_id = metrics.begin_cycle {
            channel = 'completion',
            frontend = lifecycle.frontend,
            provider_id = meta.provider_id,
            provider = meta.provider,
            name = meta.name,
            model = meta.model,
            n_requests = meta.n_requests,
        }
    end

    metrics.configure_cycle(cycle_id, {
        channel = 'completion',
        frontend = lifecycle.frontend,
        provider_id = meta.provider_id,
        provider = meta.provider,
        name = meta.name,
        model = meta.model,
        n_requests = meta.n_requests,
    })
    return cycle_id
end

---@param items_raw string?
---@param provider string
---@return table<string>
function M.parse_completion_items(items_raw, provider)
    local success, items_table = pcall(vim.split, items_raw, '<endCompletion>')
    if not success then
        utils.notify('Failed to parse ' .. provider .. "'s content text", 'error', vim.log.levels.INFO)
        return {}
    end

    return items_table
end

function M.filter_context_sequences_in_items(items, context)
    items = vim.tbl_map(function(x)
        return utils.filter_text(x, context)
    end, items)

    return items
end

---@param str_list string[]
---@return table
function M.create_chat_messages_from_list(str_list)
    local result = {}
    local roles = { 'user', 'assistant' }
    for i, content in ipairs(str_list) do
        table.insert(result, { role = roles[(i - 1) % 2 + 1], content = content })
    end
    return result
end

---@param transform fun(data: { end_point: string, headers: table, body: table })[]?
---@param end_point string
---@param headers table
---@param body table
---@return { end_point: string, headers: table, body: table }
function M.apply_transforms(transform, end_point, headers, body)
    local transformed_data = {
        end_point = end_point,
        headers = headers,
        body = body,
    }

    for _, fun in ipairs(transform or {}) do
        transformed_data = fun(transformed_data)
    end

    return transformed_data
end

return M
