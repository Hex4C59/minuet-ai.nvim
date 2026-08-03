local api = vim.api
local M = {}

M.ns_id = api.nvim_create_namespace 'minuet.duet'

local default_highlights = {
    MinuetDuetAdd = 'DiffAdd',
    MinuetDuetDelete = 'DiffDelete',
    MinuetDuetComment = 'Comment',
    MinuetDuetCursor = 'IncSearch',
    MinuetDuetJump = 'DiagnosticInfo',
}

for hl_group, default_link in pairs(default_highlights) do
    if vim.tbl_isempty(api.nvim_get_hl(0, { name = hl_group })) then
        api.nvim_set_hl(0, hl_group, { link = default_link })
    end
end

local function add_extmark(bufnr, state, row, opts)
    state.extmarks = state.extmarks or {}
    local extmark_id = api.nvim_buf_set_extmark(bufnr, M.ns_id, row, 0, opts)
    table.insert(state.extmarks, { bufnr = bufnr, id = extmark_id })
end

---@param value string
---@param max_width integer
---@return string
local function truncate_left(value, max_width)
    if vim.fn.strdisplaywidth(value) <= max_width then
        return value
    end
    local marker = '...'
    local char_count = vim.fn.strchars(value)
    for start = 1, char_count do
        local suffix = vim.fn.strcharpart(value, start)
        if vim.fn.strdisplaywidth(marker .. suffix) <= max_width then
            return marker .. suffix
        end
    end
    return marker:sub(1, max_width)
end

--- Build styled chunks for a proposed line, inserting the cursor character
--- when the cursor falls on this line.
---@param text string the proposed line content
---@param hl_group string highlight group for the text
---@param cursor_col integer|nil byte column of cursor on this line, nil if cursor is elsewhere
---@param cursor_char string the cursor character to render
---@return table[] chunks list of {text, hl_group} pairs
local function make_chunks(text, hl_group, cursor_col, cursor_char)
    if not cursor_col then
        return { { text, hl_group } }
    end
    local before = text:sub(1, cursor_col)
    local after = text:sub(cursor_col + 1)
    local chunks = {}
    if #before > 0 then
        table.insert(chunks, { before, hl_group })
    end
    table.insert(chunks, { cursor_char, 'MinuetDuetCursor' })
    if #after > 0 then
        table.insert(chunks, { after, hl_group })
    end
    return chunks
end

--- Return the cursor column if the proposed line at `proposed_idx` (0-based)
--- carries the cursor, otherwise nil.
local function cursor_col_for(edit, proposed_idx)
    local c = edit.cursor
    if not c then
        return nil
    end
    if proposed_idx == c.row_offset then
        return c.col
    end
    return nil
end

local function render_inserted_lines(bufnr, state, edit, row, lines, proposed_indices, cursor_char, above)
    if #lines == 0 then
        return
    end

    local virt_lines = {}
    for i, line in ipairs(lines) do
        local col = cursor_col_for(edit, proposed_indices[i])
        local chunks = make_chunks(line, 'MinuetDuetAdd', col, cursor_char)
        table.insert(virt_lines, chunks)
    end

    add_extmark(bufnr, state, row, {
        virt_lines = virt_lines,
        virt_lines_above = above or false,
    })
end

---@param hunk minuet.DuetHunk
local function render_hunk(bufnr, state, edit, hunk, cursor_char)
    local original_start, original_count, proposed_start, proposed_count = unpack(hunk)
    local pair_count = math.min(original_count, proposed_count)
    local first_buffer_row = edit.range.start_row + original_start - 1

    for offset = 0, pair_count - 1 do
        local buffer_row = first_buffer_row + offset
        local buffer_line = api.nvim_buf_get_lines(bufnr, buffer_row, buffer_row + 1, false)[1] or ''
        local proposed_line = edit.proposed_lines[proposed_start + offset] or ''
        local proposed_idx = proposed_start + offset - 1 -- 0-based index into proposed_lines
        local col = cursor_col_for(edit, proposed_idx)
        local chunks = make_chunks(proposed_line, 'MinuetDuetAdd', col, cursor_char)

        add_extmark(bufnr, state, buffer_row, {
            end_col = #buffer_line,
            hl_group = 'MinuetDuetDelete',
            virt_text = chunks,
            virt_text_pos = 'eol',
        })
    end

    for offset = pair_count, original_count - 1 do
        local buffer_row = first_buffer_row + offset
        local buffer_line = api.nvim_buf_get_lines(bufnr, buffer_row, buffer_row + 1, false)[1] or ''
        add_extmark(bufnr, state, buffer_row, {
            end_col = #buffer_line,
            hl_group = 'MinuetDuetDelete',
        })
    end

    if proposed_count > pair_count then
        local inserted_lines = {}
        local proposed_indices = {}
        for offset = pair_count, proposed_count - 1 do
            table.insert(inserted_lines, edit.proposed_lines[proposed_start + offset] or '')
            table.insert(proposed_indices, proposed_start + offset - 1) -- 0-based
        end

        local insertion_anchor_row = first_buffer_row + math.max(original_count - 1, 0)
        local render_above = original_count == 0 and original_start == 0

        if original_count == 0 then
            insertion_anchor_row = edit.range.start_row
            if original_start > 0 then
                insertion_anchor_row = insertion_anchor_row + original_start - 1
            end
        end

        render_inserted_lines(
            bufnr,
            state,
            edit,
            insertion_anchor_row,
            inserted_lines,
            proposed_indices,
            cursor_char,
            render_above
        )
    end
end

--- Render the cursor on an unchanged line (not covered by any hunk).
---@param hunks minuet.DuetHunk[]
local function render_cursor_on_unchanged_line(bufnr, state, edit, hunks, cursor_char)
    local c = edit.cursor
    if not c then
        return
    end

    local proposed_row_1based = c.row_offset + 1

    -- If the cursor falls inside a hunk it was already rendered there.
    for _, hunk in ipairs(hunks) do
        local _, _, ps, pc = unpack(hunk)
        if proposed_row_1based >= ps and proposed_row_1based < ps + pc then
            return
        end
    end

    -- Map proposed row → original row by undoing the cumulative insert/delete shift.
    local shift = 0
    for _, hunk in ipairs(hunks) do
        local _, oc, ps, pc = unpack(hunk)
        if ps + pc <= proposed_row_1based then
            shift = shift + (pc - oc)
        end
    end

    local original_row_1based = proposed_row_1based - shift
    local buffer_row = edit.range.start_row + original_row_1based - 1

    local line_text = edit.proposed_lines[proposed_row_1based] or ''
    local chunks = make_chunks(line_text, 'MinuetDuetComment', c.col, cursor_char)

    add_extmark(bufnr, state, buffer_row, {
        virt_text = chunks,
        virt_text_pos = 'eol',
    })
end

function M.clear(_bufnr, state)
    if not state then
        return
    end

    for _, extmark in ipairs(state.extmarks or {}) do
        if api.nvim_buf_is_valid(extmark.bufnr) then
            pcall(api.nvim_buf_del_extmark, extmark.bufnr, M.ns_id, extmark.id)
        end
    end

    state.extmarks = nil
    state.preview_kind = nil
end

---@param origin_bufnr integer
---@param target_bufnr integer
---@param state minuet.DuetState
---@param origin_row integer
---@param target_row integer
---@param path string
function M.render_cross_jump(origin_bufnr, target_bufnr, state, origin_row, target_row, path)
    local config = require('minuet').config.duet
    M.clear(origin_bufnr, state)

    local origin_lines = math.max(api.nvim_buf_line_count(origin_bufnr), 1)
    local target_lines = math.max(api.nvim_buf_line_count(target_bufnr), 1)
    origin_row = math.min(math.max(origin_row, 0), origin_lines - 1)
    target_row = math.min(math.max(target_row, 0), target_lines - 1)

    local template = config.preview.cross_jump_text
    local formatted, message = pcall(string.format, template, path, target_row + 1)
    if not formatted then
        message = ('Next edit: %s:%d'):format(path, target_row + 1)
    end
    message = truncate_left(message, math.max(api.nvim_win_get_width(0) - 4, 12))
    add_extmark(origin_bufnr, state, origin_row, {
        virt_text = { { message, 'MinuetDuetJump' } },
        virt_text_pos = 'eol',
        priority = 200,
    })

    local jump_sign = config.preview.jump_sign
    if type(jump_sign) ~= 'string' or jump_sign == '' or vim.fn.strdisplaywidth(jump_sign) > 2 then
        jump_sign = '>>'
    end
    add_extmark(target_bufnr, state, target_row, {
        sign_text = jump_sign,
        sign_hl_group = 'MinuetDuetJump',
        priority = 200,
    })
    state.preview_kind = 'cross_jump'
end

---@param bufnr integer
---@param state minuet.DuetState
---@param origin_row integer
---@param target_row integer
function M.render_jump(bufnr, state, origin_row, target_row)
    local config = require('minuet').config.duet
    M.clear(bufnr, state)

    local line_count = math.max(api.nvim_buf_line_count(bufnr), 1)
    origin_row = math.min(math.max(origin_row, 0), line_count - 1)
    target_row = math.min(math.max(target_row, 0), line_count - 1)
    local jump_text = config.preview.jump_text
    local formatted, message = pcall(string.format, jump_text, target_row + 1)
    if not formatted then
        message = ('Next edit: line %d'):format(target_row + 1)
    end

    add_extmark(bufnr, state, origin_row, {
        virt_text = { { message, 'MinuetDuetJump' } },
        virt_text_pos = 'eol',
        priority = 200,
    })

    local jump_sign = config.preview.jump_sign
    if type(jump_sign) ~= 'string' or jump_sign == '' or vim.fn.strdisplaywidth(jump_sign) > 2 then
        jump_sign = '>>'
    end
    add_extmark(bufnr, state, target_row, {
        sign_text = jump_sign,
        sign_hl_group = 'MinuetDuetJump',
        priority = 200,
    })
    state.preview_kind = 'jump'
end

---@param bufnr integer
---@param state minuet.DuetState
---@param edit minuet.DuetEdit
function M.render(bufnr, state, edit)
    local config = require('minuet').config.duet
    M.clear(bufnr, state)

    local hunks = edit.hunks
    local cursor_char = config.preview.cursor

    if #hunks == 0 then
        return
    end

    for _, hunk in ipairs(hunks) do
        render_hunk(bufnr, state, edit, hunk, cursor_char)
    end

    render_cursor_on_unchanged_line(bufnr, state, edit, hunks, cursor_char)
    state.preview_kind = 'edit'
end

function M.is_visible(bufnr, state)
    if not state then
        return false
    end

    for _, record in ipairs(state.extmarks or {}) do
        if api.nvim_buf_is_valid(record.bufnr) then
            local extmark = api.nvim_buf_get_extmark_by_id(record.bufnr, M.ns_id, record.id, {})
            if extmark[1] ~= nil then
                return true
            end
        end
    end
    return false
end

return M
