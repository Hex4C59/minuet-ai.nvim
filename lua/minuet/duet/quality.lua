local uv = vim.uv or vim.loop

local M = {}

local internal = {
    entries = {},
}

---@return minuet.DuetRepeatSuppressionConfig
local function config()
    return require('minuet').config.duet.quality.repeat_suppression
end

---@param edit minuet.DuetEdit
---@return string?
local function fingerprint(edit)
    local proposed_hash_ok, proposed_hash = pcall(vim.fn.sha256, table.concat(edit.proposed_lines, '\n'))
    if not proposed_hash_ok or type(proposed_hash) ~= 'string' then
        return nil
    end
    local identity = table.concat({
        edit.bufnr,
        edit.changedtick,
        edit.range.start_row,
        edit.range.end_row,
        proposed_hash,
    }, ':')
    local key_ok, key = pcall(vim.fn.sha256, identity)
    return key_ok and type(key) == 'string' and key or nil
end

---@param edit minuet.DuetEdit
---@return boolean
function M.is_repeat(edit)
    local cfg = config()
    if not cfg.enabled or cfg.ttl <= 0 or cfg.max_entries <= 0 then
        return false
    end
    local key = fingerprint(edit)
    if not key then
        return false
    end

    local now = uv.now()
    local live = {}
    for current_key, entry in pairs(internal.entries) do
        if now - entry.created_at <= cfg.ttl then
            live[current_key] = entry
        end
    end
    internal.entries = live

    local existing = internal.entries[key]
    if existing then
        existing.used_at = now
        return true
    end

    internal.entries[key] = { created_at = now, used_at = now }
    local ordered = {}
    for current_key, entry in pairs(internal.entries) do
        ordered[#ordered + 1] = { key = current_key, used_at = entry.used_at }
    end
    table.sort(ordered, function(left, right)
        if left.used_at ~= right.used_at then
            return left.used_at < right.used_at
        end
        return left.key < right.key
    end)
    while #ordered > cfg.max_entries do
        internal.entries[table.remove(ordered, 1).key] = nil
    end
    return false
end

function M.reset()
    internal.entries = {}
end

---@return { count: integer }
function M._inspect()
    return { count = vim.tbl_count(internal.entries) }
end

return M
