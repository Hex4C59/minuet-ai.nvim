local api = vim.api

local M = {}

local uv = vim.uv or vim.loop
local augroup_name = 'MinuetDuetScheduler'

---@class minuet.DuetScheduleState
---@field generation integer
---@field bufnr? integer
---@field dirty_tick? integer
---@field dismissed_tick? integer
---@field due_reason? 'text_changed'|'insert_leave'|'after_accept'
---@field attempted_generation? integer
---@field last_started_ns? number
---@field timer? uv.uv_timer_t

---@type minuet.DuetScheduleState & { trigger?: fun(intent: minuet.SuggestionIntent): boolean }
local internal = {
    generation = 0,
}

local function stop_timer()
    local timer = internal.timer
    internal.timer = nil
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

local function completion_menu_visible()
    if vim.fn.pumvisible() == 1 then
        return true
    end

    local has_cmp, cmp = pcall(require, 'cmp')
    if has_cmp then
        local ok, visible = pcall(function()
            return cmp.core.view:visible()
        end)
        if ok and visible then
            return true
        end
    end

    local has_blink, blink = pcall(require, 'blink-cmp')
    if has_blink then
        local ok, visible = pcall(blink.is_visible)
        if ok and visible then
            return true
        end
    end

    return false
end

---@return minuet.DuetAutoTrigger
local function get_config()
    return require('minuet').config.duet.auto_trigger
end

---@param bufnr integer
---@return minuet.DuetAutoTrigger, integer, integer
local function get_policy(bufnr)
    local config = get_config()
    local policies = type(config.filetype) == 'table' and config.filetype or {}
    local override = policies[vim.bo[bufnr].filetype]
    override = type(override) == 'table' and override or {}
    return config, override.debounce or config.debounce, override.throttle or config.throttle
end

---@param bufnr integer
---@return boolean
local function gate(bufnr)
    local config = get_config()
    if
        not config.enabled
        or bufnr ~= api.nvim_get_current_buf()
        or not api.nvim_buf_is_valid(bufnr)
        or not api.nvim_buf_is_loaded(bufnr)
        or vim.bo[bufnr].buftype ~= ''
        or not vim.bo[bufnr].modifiable
        or vim.bo[bufnr].binary
    then
        return false
    end

    local ok, buffer_size = pcall(api.nvim_buf_get_offset, bufnr, api.nvim_buf_line_count(bufnr))
    if not ok or buffer_size > config.max_buffer_size then
        return false
    end
    if api.nvim_buf_get_changedtick(bufnr) ~= internal.dirty_tick then
        return false
    end

    local mode = vim.fn.mode(1)
    if mode ~= 'n' and mode:sub(1, 1) ~= 'i' then
        return false
    end
    if
        vim.o.paste
        or vim.fn.reg_recording() ~= ''
        or vim.fn.reg_executing() ~= ''
        or vim.fn.getcmdwintype() ~= ''
        or completion_menu_visible()
    then
        return false
    end

    if not require('minuet.utils').run_hooks_until_failure(config.enable_predicates, bufnr) then
        return false
    end
    if internal.dismissed_tick == internal.dirty_tick or require('minuet.suggestion').has_visible() then
        return false
    end
    return true
end

local run_due

---@param delay integer
---@param reason 'text_changed'|'insert_leave'|'after_accept'
---@param generation integer
local function arm_timer(delay, reason, generation)
    stop_timer()
    internal.due_reason = reason

    local timer
    timer = vim.defer_fn(function()
        if internal.timer == timer then
            internal.timer = nil
        end
        run_due(generation)
    end, delay)
    internal.timer = timer
end

---@param generation integer
run_due = function(generation)
    if generation ~= internal.generation or internal.attempted_generation == generation then
        return
    end

    local bufnr = internal.bufnr
    if not bufnr or not gate(bufnr) then
        internal.attempted_generation = generation
        return
    end

    local _, _, throttle = get_policy(bufnr)
    if internal.last_started_ns then
        local elapsed_ms = (uv.hrtime() - internal.last_started_ns) / 1e6
        if elapsed_ms < throttle then
            arm_timer(math.ceil(throttle - elapsed_ms), internal.due_reason or 'text_changed', generation)
            return
        end
    end

    internal.attempted_generation = generation
    local reason = internal.due_reason
    internal.due_reason = nil
    if internal.trigger then
        internal.trigger(reason == 'after_accept' and 'after_accept' or 'auto')
    end
end

---@param info { buf: integer }
local function on_text_changed(info)
    local _, debounce = get_policy(info.buf)
    internal.generation = internal.generation + 1
    internal.bufnr = info.buf
    internal.dirty_tick = api.nvim_buf_get_changedtick(info.buf)
    internal.attempted_generation = nil
    require('minuet.suggestion').invalidate_buffer(info.buf, 'buffer_changed', 'duet')
    arm_timer(debounce, 'text_changed', internal.generation)
end

local function on_insert_leave()
    local config = get_config()
    if
        not config.on_insert_leave
        or not internal.dirty_tick
        or internal.attempted_generation == internal.generation
    then
        return
    end

    stop_timer()
    internal.due_reason = 'insert_leave'
    local generation = internal.generation
    vim.schedule(function()
        run_due(generation)
    end)
end

---@param info { buf: integer }
local function on_buffer_leave(info)
    internal.generation = internal.generation + 1
    stop_timer()
    if internal.bufnr == info.buf then
        internal.bufnr = nil
        internal.dirty_tick = nil
        internal.due_reason = nil
        internal.attempted_generation = nil
    end
end

---@param trigger fun(intent: minuet.SuggestionIntent): boolean
function M.setup(trigger)
    stop_timer()
    api.nvim_create_augroup(augroup_name, { clear = true })
    internal.generation = internal.generation + 1
    internal.bufnr = nil
    internal.dirty_tick = nil
    internal.dismissed_tick = nil
    internal.due_reason = nil
    internal.attempted_generation = nil
    internal.last_started_ns = nil
    internal.trigger = trigger

    local config = get_config()
    if not config.enabled then
        return
    end

    require('minuet.duet.edits').ensure_setup()
    local augroup = api.nvim_create_augroup(augroup_name, { clear = true })
    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
        group = augroup,
        callback = on_text_changed,
        desc = '[minuet.duet.scheduler] debounce prediction after edits',
    })
    api.nvim_create_autocmd('InsertLeave', {
        group = augroup,
        callback = on_insert_leave,
        desc = '[minuet.duet.scheduler] predict after insert leave',
    })
    api.nvim_create_autocmd({ 'BufLeave', 'BufWipeout' }, {
        group = augroup,
        callback = on_buffer_leave,
        desc = '[minuet.duet.scheduler] cancel prediction timer',
    })
end

function M.note_request_started()
    if get_config().enabled then
        internal.last_started_ns = uv.hrtime()
    end
end

---@param bufnr integer
function M.after_accept(bufnr)
    local config, debounce = get_policy(bufnr)
    if not config.enabled or not config.after_accept or bufnr ~= api.nvim_get_current_buf() then
        return
    end

    internal.generation = internal.generation + 1
    internal.bufnr = bufnr
    internal.dirty_tick = api.nvim_buf_get_changedtick(bufnr)
    internal.attempted_generation = nil
    arm_timer(debounce, 'after_accept', internal.generation)
end

---@param bufnr integer
---@param changedtick integer
function M.dismissed(bufnr, changedtick)
    if get_config().enabled and internal.bufnr == bufnr then
        internal.dismissed_tick = changedtick
    end
end

function M.reset()
    stop_timer()
    api.nvim_create_augroup(augroup_name, { clear = true })
    internal.generation = internal.generation + 1
    internal.bufnr = nil
    internal.dirty_tick = nil
    internal.dismissed_tick = nil
    internal.due_reason = nil
    internal.attempted_generation = nil
    internal.last_started_ns = nil
    internal.trigger = nil
end

---@return table
function M._inspect()
    return {
        generation = internal.generation,
        bufnr = internal.bufnr,
        dirty_tick = internal.dirty_tick,
        dismissed_tick = internal.dismissed_tick,
        due_reason = internal.due_reason,
        attempted_generation = internal.attempted_generation,
        timer_active = internal.timer ~= nil and not internal.timer:is_closing(),
        timer_count = internal.timer ~= nil and not internal.timer:is_closing() and 1 or 0,
    }
end

return M
