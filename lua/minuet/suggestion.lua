local M = {}

---@alias minuet.SuggestionSource 'fim'|'duet'
---@alias minuet.SuggestionIntent 'manual'|'auto'|'after_accept'
---@alias minuet.SuggestionPhase 'pending'|'visible'|'accepting'|'accepted'|'dismissed'|'stale'

---@class minuet.SuggestionOps
---@field cancel fun(reason: string)
---@field can_accept? fun(): boolean, string?
---@field accept fun()
---@field dismiss fun(reason: string, explicit: boolean)
---@field is_visible fun(): boolean

---@class minuet.SuggestionLease
---@field id integer
---@field generation integer
---@field source minuet.SuggestionSource
---@field intent minuet.SuggestionIntent
---@field bufnr integer
---@field changedtick integer
---@field origin_bufnr integer
---@field origin_changedtick integer
---@field target_bufnr integer
---@field target_changedtick integer
---@field state_bufnr integer
---@field cross_buffer boolean
---@field workspace_root? string
---@field target_path? string
---@field phase minuet.SuggestionPhase
---@field target_row? integer
---@field target_col? integer
---@field jump_required? boolean
---@field jumped? boolean
---@field cycle_id? integer
---@field ops? minuet.SuggestionOps

---@class minuet.SuggestionBeginOptions
---@field source minuet.SuggestionSource
---@field intent minuet.SuggestionIntent
---@field bufnr integer
---@field changedtick integer
---@field target_row? integer
---@field target_col? integer
---@field jump_required? boolean

local internal = {
    next_id = 0,
    generation = 0,
    ---@type minuet.SuggestionLease?
    current = nil,
}

---@param callback function?
---@param ... any
local function call_cleanup(callback, ...)
    if not callback then
        return
    end

    local ok = pcall(callback, ...)
    if not ok then
        vim.notify('Minuet suggestion cleanup failed.', vim.log.levels.ERROR)
    end
end

---@param lease minuet.SuggestionLease
---@param phase 'accepted'|'dismissed'|'stale'
---@return boolean
local function enter_terminal(lease, phase)
    if internal.current ~= lease then
        return false
    end

    lease.phase = phase
    internal.current = nil
    internal.generation = internal.generation + 1
    return true
end

---@param lease minuet.SuggestionLease
---@param phase 'dismissed'|'stale'
---@param reason string
---@param explicit boolean
local function retire(lease, phase, reason, explicit)
    local ops = lease.ops
    if not enter_terminal(lease, phase) then
        return
    end

    if phase == 'dismissed' then
        call_cleanup(ops and ops.dismiss, reason, explicit)
    else
        call_cleanup(ops and ops.cancel, reason)
    end
end

---@param options minuet.SuggestionBeginOptions
---@return minuet.SuggestionLease?
function M.begin(options)
    local current = internal.current
    local automatic = options.intent ~= 'manual'

    if current then
        if automatic and (current.phase == 'visible' or current.phase == 'accepting') then
            return nil
        end
        if automatic and current.phase == 'pending' and current.source == 'duet' and options.source == 'fim' then
            return nil
        end

        retire(current, 'stale', 'superseded', false)
    end

    internal.next_id = internal.next_id + 1
    internal.generation = internal.generation + 1

    ---@type minuet.SuggestionLease
    local lease = {
        id = internal.next_id,
        generation = internal.generation,
        source = options.source,
        intent = options.intent,
        bufnr = options.bufnr,
        changedtick = options.changedtick,
        origin_bufnr = options.bufnr,
        origin_changedtick = options.changedtick,
        target_bufnr = options.bufnr,
        target_changedtick = options.changedtick,
        state_bufnr = options.bufnr,
        cross_buffer = false,
        phase = 'pending',
        target_row = options.target_row,
        target_col = options.target_col,
        jump_required = options.jump_required,
        jumped = false,
    }
    internal.current = lease
    return lease
end

---@param lease minuet.SuggestionLease
---@param ops minuet.SuggestionOps
---@return boolean
function M.attach(lease, ops)
    if internal.current ~= lease or lease.phase ~= 'pending' or lease.ops ~= nil then
        return false
    end

    lease.ops = ops
    return true
end

---@param lease minuet.SuggestionLease?
---@return boolean
function M.is_current(lease)
    return lease ~= nil
        and internal.current == lease
        and lease.generation == internal.generation
        and (lease.phase == 'pending' or lease.phase == 'visible' or lease.phase == 'accepting')
end

---@param lease minuet.SuggestionLease
---@return boolean
function M.mark_visible(lease)
    if not M.is_current(lease) or lease.phase ~= 'pending' then
        return false
    end

    lease.phase = 'visible'
    return true
end

---@param lease minuet.SuggestionLease
---@return boolean
function M.mark_accepting(lease)
    if not M.is_current(lease) or lease.phase ~= 'visible' then
        return false
    end

    lease.phase = 'accepting'
    return true
end

---Return a current lease to visible after an accepting action only focused a
---remote edit. This does not advance generation or emit a terminal lifecycle.
---@param lease minuet.SuggestionLease
---@return boolean
function M.resume_visible(lease)
    if not M.is_current(lease) or lease.phase ~= 'accepting' then
        return false
    end

    lease.phase = 'visible'
    return true
end

---@param lease minuet.SuggestionLease
---@param phase 'accepted'|'dismissed'|'stale'
---@param reason? string
---@return boolean
function M.finish(lease, phase, _reason)
    return enter_terminal(lease, phase)
end

---Release a pending lease for an empty, parse-failed, or filtered result.
---This intentionally produces no suggestion lifecycle event.
---@param lease minuet.SuggestionLease
---@return boolean
function M.release(lease)
    if internal.current ~= lease then
        return false
    end

    internal.current = nil
    internal.generation = internal.generation + 1
    return true
end

---@return boolean handled
function M.accept_visible()
    local lease = internal.current
    if not lease then
        return false
    end
    if lease.phase == 'accepting' then
        return true
    end
    if lease.phase ~= 'visible' or not lease.ops then
        return false
    end

    local can_accept = true
    local reason
    if lease.ops.can_accept then
        local ok
        ok, can_accept, reason = pcall(lease.ops.can_accept)
        if not ok then
            enter_terminal(lease, 'stale')
            call_cleanup(lease.ops.cancel, 'apply_validation')
            error(can_accept, 0)
        end
    else
        local ok
        ok, can_accept = pcall(lease.ops.is_visible)
        if not ok then
            enter_terminal(lease, 'stale')
            call_cleanup(lease.ops.cancel, 'apply_validation')
            error(can_accept, 0)
        end
    end

    if not can_accept then
        retire(lease, 'stale', reason or 'apply_validation', false)
        return false
    end

    M.mark_accepting(lease)
    local ok, err = pcall(lease.ops.accept)
    if not ok then
        enter_terminal(lease, 'stale')
        call_cleanup(lease.ops.cancel, 'apply_validation')
        error(err, 0)
    end
    return true
end

---@param lease? minuet.SuggestionLease
---@return boolean
function M.dismiss(lease)
    lease = lease or internal.current
    if not lease or internal.current ~= lease then
        return false
    end

    retire(lease, 'dismissed', 'dismissed', true)
    return true
end

---@return boolean
function M.dismiss_visible()
    return M.dismiss(internal.current)
end

---@param lease minuet.SuggestionLease
---@param reason string
---@return boolean
function M.invalidate(lease, reason)
    if internal.current ~= lease then
        return false
    end

    retire(lease, 'stale', reason, false)
    return true
end

---@param bufnr integer
---@param reason string
---@param source? minuet.SuggestionSource
---@return boolean
function M.invalidate_buffer(bufnr, reason, source)
    local lease = internal.current
    if
        not lease
        or (lease.bufnr ~= bufnr and lease.origin_bufnr ~= bufnr and lease.target_bufnr ~= bufnr)
        or (source and lease.source ~= source)
    then
        return false
    end

    retire(lease, 'stale', reason, false)
    return true
end

---@param source? minuet.SuggestionSource
---@return boolean
function M.has_visible(source)
    local lease = internal.current
    return lease ~= nil
        and (lease.phase == 'visible' or lease.phase == 'accepting')
        and (source == nil or lease.source == source)
end

---@return minuet.SuggestionLease?
function M.current()
    return internal.current
end

function M.reset()
    local lease = internal.current
    if lease then
        retire(lease, 'stale', 'superseded', false)
    else
        internal.generation = internal.generation + 1
    end
end

return M
