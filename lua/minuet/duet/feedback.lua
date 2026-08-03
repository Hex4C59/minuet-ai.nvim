local api = vim.api
local uv = vim.uv or vim.loop

local M = {}

local augroup_name = 'MinuetDuetFeedback'
local internal = {
    entries = {},
}

---@return minuet.DuetQualityConfig
local function config()
    return require('minuet').config.duet.quality
end

local function prune()
    local now = uv.hrtime()
    local window_ns = config().undo_window * 1000000
    local live = {}
    for _, entry in ipairs(internal.entries) do
        if now - entry.accepted_ns <= window_ns then
            live[#live + 1] = entry
        end
    end
    internal.entries = live
end

---@param cycle_id integer
---@param bufnr integer
function M.track_accept(cycle_id, bufnr)
    local cfg = config()
    if cfg.undo_window <= 0 or cfg.max_pending_undo <= 0 or bufnr ~= api.nvim_get_current_buf() then
        return
    end
    local undo = vim.fn.undotree()
    if type(undo) ~= 'table' or type(undo.seq_cur) ~= 'number' then
        return
    end

    prune()
    internal.entries[#internal.entries + 1] = {
        cycle_id = cycle_id,
        bufnr = bufnr,
        seq_after = undo.seq_cur,
        accepted_ns = uv.hrtime(),
    }
    while #internal.entries > cfg.max_pending_undo do
        table.remove(internal.entries, 1)
    end
end

local function on_undo()
    prune()
    local bufnr = api.nvim_get_current_buf()
    local undo = vim.fn.undotree()
    if type(undo) ~= 'table' or type(undo.seq_cur) ~= 'number' then
        return
    end
    for index = #internal.entries, 1, -1 do
        local entry = internal.entries[index]
        if entry.bufnr == bufnr and undo.seq_cur < entry.seq_after then
            require('minuet.metrics').suggestion_event(entry.cycle_id, 'reverted')
            table.remove(internal.entries, index)
        end
    end
end

function M.setup()
    internal.entries = {}
    local group = api.nvim_create_augroup(augroup_name, { clear = true })
    if config().undo_window <= 0 or config().max_pending_undo <= 0 then
        return
    end
    api.nvim_create_autocmd('TextChanged', {
        group = group,
        callback = on_undo,
        desc = '[minuet.duet.feedback] observe undo sequence changes after acceptance',
    })
end

function M.reset()
    internal.entries = {}
    api.nvim_create_augroup(augroup_name, { clear = true })
end

---@return { count: integer }
function M._inspect()
    prune()
    return { count = #internal.entries }
end

return M
