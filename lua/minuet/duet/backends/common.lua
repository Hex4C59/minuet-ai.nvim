local M = {}

local uv = vim.uv or vim.loop

---@type minuet.DuetJobState[]
M.current_jobs = {}

---@class minuet.DuetJobState
---@field job vim.SystemObj
---@field pid integer?
---@field cancel_requested boolean
---@field exited boolean
---@field cycle_id? integer

---@param state minuet.DuetJobState
local function register_job(state)
    table.insert(M.current_jobs, state)
end

---@param state minuet.DuetJobState
local function remove_job(state)
    for index, current in ipairs(M.current_jobs) do
        if current == state then
            table.remove(M.current_jobs, index)
            break
        end
    end
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
            pcall(state.job.kill, state.job, 'sigterm')
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
            pcall(state.job.kill, state.job, 'sigterm')
        end
    end
end

---@class minuet.DuetJobHandlers
---@field on_exit fun(state: minuet.DuetJobState, result: vim.SystemCompleted, ended_ns: number)
---@field on_spawn_error? fun(ended_ns: number)
---@field cycle_id? integer

---@param command string
---@param args string[]
---@param handlers minuet.DuetJobHandlers
---@return minuet.DuetJobState?
function M.start_job(command, args, handlers)
    local cmd = { command }
    vim.list_extend(cmd, args)

    ---@type minuet.DuetJobState?
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

            remove_job(state)
            handlers.on_exit(state, out, ended_ns)
        end)
    end)

    if not ok or type(result) ~= 'table' then
        if handlers.on_spawn_error then
            handlers.on_spawn_error(uv.hrtime())
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
    register_job(state)

    return state
end

---@class minuet.DuetBackendCycleMeta
---@field provider_id string
---@field provider string
---@field name? string
---@field model? string
---@field n_requests integer

---@class minuet.DuetBackendLifecycle
---@field cycle_id? integer
---@field frontend? string

---@param meta minuet.DuetBackendCycleMeta
---@param lifecycle? minuet.DuetBackendLifecycle
---@return integer cycle_id
function M.configure_cycle(meta, lifecycle)
    local metrics = require 'minuet.metrics'
    lifecycle = type(lifecycle) == 'table' and lifecycle or {}
    local cycle_id = lifecycle.cycle_id

    if type(cycle_id) ~= 'number' or cycle_id ~= math.floor(cycle_id) or cycle_id < 1 then
        cycle_id = metrics.begin_cycle {
            channel = 'duet',
            frontend = lifecycle.frontend,
            provider_id = meta.provider_id,
            provider = meta.provider,
            name = meta.name,
            model = meta.model,
            n_requests = meta.n_requests,
        }
    end

    metrics.configure_cycle(cycle_id, {
        channel = 'duet',
        frontend = lifecycle.frontend,
        provider_id = meta.provider_id,
        provider = meta.provider,
        name = meta.name,
        model = meta.model,
        n_requests = meta.n_requests,
    })
    return cycle_id
end

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
