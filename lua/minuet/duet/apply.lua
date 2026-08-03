local api = vim.api

local M = {}

---@diagnostic disable-next-line: deprecated
local diff = (vim.text and vim.text.diff) or vim.diff

---@alias minuet.DuetHunk integer[]

---@class minuet.DuetEdit
---@field bufnr integer
---@field changedtick integer
---@field range minuet.DuetContextRange
---@field original_lines string[]
---@field proposed_lines string[]
---@field cursor minuet.DuetParseCursor
---@field hunks minuet.DuetHunk[]
---@field changed_lines integer
---@field proposed_bytes integer

---@class minuet.DuetEditInput
---@field bufnr integer
---@field changedtick integer
---@field range minuet.DuetContextRange
---@field original_lines string[]
---@field proposed_lines string[]
---@field cursor minuet.DuetParseCursor

---@param value any
---@return boolean
local function is_nonnegative_integer(value)
    return type(value) == 'number' and value == math.floor(value) and value >= 0
end

---@param lines any
---@return boolean
local function valid_lines(lines)
    if type(lines) ~= 'table' then
        return false
    end
    for _, line in ipairs(lines) do
        if type(line) ~= 'string' then
            return false
        end
    end
    return true
end

---@param original_lines string[]
---@param proposed_lines string[]
---@return minuet.DuetHunk[]
function M.compute_hunks(original_lines, proposed_lines)
    local original = #original_lines == 0 and '' or table.concat(original_lines, '\n') .. '\n'
    local proposed = #proposed_lines == 0 and '' or table.concat(proposed_lines, '\n') .. '\n'
    local hunks = diff(original, proposed, {
        result_type = 'indices',
        algorithm = 'histogram',
        linematch = true,
        ignore_whitespace = false,
        ignore_whitespace_change = false,
        ignore_whitespace_change_at_eol = false,
        ignore_blank_lines = false,
    })

    if type(hunks) == 'string' or hunks == nil then
        return {}
    end
    return hunks
end

---@return integer max_edit_lines, integer max_edit_chars
local function get_limits()
    local config = require('minuet').config.duet
    local defaults = require 'minuet.duet.config'
    local max_edit_lines = config.max_edit_lines
    local max_edit_chars = config.max_edit_chars
    if not is_nonnegative_integer(max_edit_lines) then
        max_edit_lines = defaults.max_edit_lines
    end
    if not is_nonnegative_integer(max_edit_chars) then
        max_edit_chars = defaults.max_edit_chars
    end
    return max_edit_lines, max_edit_chars
end

---@param input minuet.DuetEditInput
---@param lease minuet.SuggestionLease
---@return minuet.DuetEdit?, 'invalid'|'stale'|'no_op'|'whitespace_only'|'too_many_lines'|'too_many_bytes'
function M.prepare(input, lease)
    local target_bufnr = lease.target_bufnr or lease.bufnr
    if
        not require('minuet.suggestion').is_current(lease)
        or input.bufnr ~= target_bufnr
        or not api.nvim_buf_is_valid(input.bufnr)
        or not api.nvim_buf_is_loaded(input.bufnr)
        or not vim.bo[input.bufnr].modifiable
    then
        return nil, 'stale'
    end

    local range = input.range
    local cursor = input.cursor
    if
        type(range) ~= 'table'
        or not is_nonnegative_integer(range.start_row)
        or not is_nonnegative_integer(range.end_row)
        or range.start_row > range.end_row
        or range.end_row > api.nvim_buf_line_count(input.bufnr)
        or not valid_lines(input.original_lines)
        or not valid_lines(input.proposed_lines)
        or type(cursor) ~= 'table'
        or not is_nonnegative_integer(cursor.row_offset)
        or not is_nonnegative_integer(cursor.col)
    then
        return nil, 'invalid'
    end

    if api.nvim_buf_get_changedtick(input.bufnr) ~= input.changedtick then
        return nil, 'stale'
    end
    local current_lines = api.nvim_buf_get_lines(input.bufnr, range.start_row, range.end_row, false)
    if not vim.deep_equal(current_lines, input.original_lines) then
        return nil, 'stale'
    end
    if vim.deep_equal(input.original_lines, input.proposed_lines) then
        return nil, 'no_op'
    end

    local original_text = table.concat(input.original_lines, '\n')
    local proposed_text = table.concat(input.proposed_lines, '\n')
    if original_text:gsub('%s', '') == proposed_text:gsub('%s', '') then
        return nil, 'whitespace_only'
    end

    local hunks = M.compute_hunks(input.original_lines, input.proposed_lines)
    local changed_lines = 0
    for _, hunk in ipairs(hunks) do
        changed_lines = changed_lines + math.max(hunk[2], hunk[4])
    end

    local max_edit_lines, max_edit_chars = get_limits()
    if changed_lines > max_edit_lines then
        return nil, 'too_many_lines'
    end
    if #proposed_text > max_edit_chars then
        return nil, 'too_many_bytes'
    end

    return {
        bufnr = input.bufnr,
        changedtick = input.changedtick,
        range = vim.deepcopy(range),
        original_lines = vim.deepcopy(input.original_lines),
        proposed_lines = vim.deepcopy(input.proposed_lines),
        cursor = vim.deepcopy(cursor),
        hunks = hunks,
        changed_lines = changed_lines,
        proposed_bytes = #proposed_text,
    }
end

---@param edit minuet.DuetEdit?
---@param lease minuet.SuggestionLease
---@return boolean, string?
function M.preflight(edit, lease)
    if not edit then
        return false, 'apply_validation'
    end

    local checked = M.prepare({
        bufnr = edit.bufnr,
        changedtick = edit.changedtick,
        range = edit.range,
        original_lines = edit.original_lines,
        proposed_lines = edit.proposed_lines,
        cursor = edit.cursor,
    }, lease)

    if
        not checked
        or checked.changed_lines ~= edit.changed_lines
        or checked.proposed_bytes ~= edit.proposed_bytes
        or not vim.deep_equal(checked.hunks, edit.hunks)
    then
        return false, 'apply_validation'
    end
    return true
end

---@param edit minuet.DuetEdit
---@param lease minuet.SuggestionLease
---@return boolean, 'apply_validation'|'buffer_write'?
function M.apply(edit, lease)
    if edit.bufnr ~= api.nvim_get_current_buf() or not M.preflight(edit, lease) then
        return false, 'apply_validation'
    end

    local ok =
        pcall(api.nvim_buf_set_lines, edit.bufnr, edit.range.start_row, edit.range.end_row, false, edit.proposed_lines)
    if not ok then
        return false, 'buffer_write'
    end

    local line_count = math.max(api.nvim_buf_line_count(edit.bufnr), 1)
    local target_row = math.min(math.max(edit.range.start_row + edit.cursor.row_offset, 0), line_count - 1)
    local target_line = api.nvim_buf_get_lines(edit.bufnr, target_row, target_row + 1, false)[1] or ''
    local max_col = vim.fn.mode(1):sub(1, 1) == 'i' and #target_line or math.max(#target_line - 1, 0)
    local target_col = math.min(math.max(edit.cursor.col, 0), max_col)
    pcall(api.nvim_win_set_cursor, 0, { target_row + 1, target_col })
    return true
end

return M
