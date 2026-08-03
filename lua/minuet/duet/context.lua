local M = {}

local EVIDENCE_END = '\n</context_evidence>'

---@param text string context evidence body without its closing tag
---@param limit integer
---@return string
local function truncate_evidence(text, limit)
    limit = math.max(limit, 0)
    if limit < #EVIDENCE_END then
        return ''
    end
    local related_start = text:find('\nRelated loaded files:', 1, true)
    if related_start and vim.fn.strchars(text) + #EVIDENCE_END > limit then
        text = text:sub(1, related_start - 1)
    end
    return vim.fn.strcharpart(text, 0, limit - #EVIDENCE_END) .. EVIDENCE_END
end

---@class minuet.DuetContextRange
---@field start_row integer
---@field end_row integer

---@class minuet.DuetContext
---@field bufnr integer
---@field changedtick integer
---@field non_editable_region_before string
---@field editable_region_before_cursor string
---@field editable_region_after_cursor string
---@field non_editable_region_after string
---@field recent_edits string
---@field context_evidence string
---@field original_lines string[]
---@field range minuet.DuetContextRange

---@param context_before string
---@param context_after string
---@param config minuet.DuetConfig
---@return string, string
local function truncate_non_editable_regions(context_before, context_after, config)
    local non_editable_region = config.non_editable_region or {}
    local context_window = math.max(non_editable_region.context_window or 0, 0)
    local context_ratio = non_editable_region.context_ratio or 0.75
    local n_chars_before = vim.fn.strchars(context_before)
    local n_chars_after = vim.fn.strchars(context_after)
    local is_incomplete_before = false
    local is_incomplete_after = false

    if n_chars_before + n_chars_after > context_window then
        if n_chars_before < context_window * context_ratio then
            -- Before context fits its budget; spend the remaining window after the editable region.
            context_after = vim.fn.strcharpart(context_after, 0, context_window - n_chars_before)
            is_incomplete_after = true
        elseif n_chars_after < context_window * (1 - context_ratio) then
            -- After context fits its budget; spend the remaining window before the editable region.
            context_before = vim.fn.strcharpart(context_before, n_chars_before + n_chars_after - context_window)
            is_incomplete_before = true
        else
            -- Both sides exceed their budgets; split the window by context_ratio.
            context_after = vim.fn.strcharpart(context_after, 0, math.floor(context_window * (1 - context_ratio)))
            context_before =
                vim.fn.strcharpart(context_before, n_chars_before - math.floor(context_window * context_ratio))
            is_incomplete_before = true
            is_incomplete_after = true
        end
    end

    if is_incomplete_before then
        -- Drop the first line because suffix truncation may start in the middle of a line.
        local _, rest = context_before:match '([^\n]*)\n(.*)'
        context_before = rest or context_before
    end

    if is_incomplete_after then
        -- Drop the last line because prefix truncation may end in the middle of a line.
        local content = context_after:match '(.*)[\n][^\n]*$'
        context_after = content or context_after
    end

    return context_before, context_after
end

---@param bufnr integer
---@param candidate? minuet.DuetCandidate|{ bufnr?: integer, row: integer, col: integer }
---@param semantic? minuet.DuetSemanticContext
---@return minuet.DuetContext
function M.build(bufnr, candidate, semantic)
    local config = require('minuet').config.duet
    local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local line_count = math.max(#all_lines, 1)

    if #all_lines == 0 then
        all_lines = { '' }
    end

    local cursor_line
    local cursor_col
    if candidate ~= nil then
        if
            type(candidate) ~= 'table'
            or (candidate.bufnr ~= nil and candidate.bufnr ~= bufnr)
            or type(candidate.row) ~= 'number'
            or candidate.row ~= math.floor(candidate.row)
            or type(candidate.col) ~= 'number'
            or candidate.col ~= math.floor(candidate.col)
        then
            error 'invalid Duet context candidate'
        end
        cursor_line = math.min(math.max(candidate.row, 0), line_count - 1)
        local target_line = all_lines[cursor_line + 1] or ''
        cursor_col = math.min(math.max(candidate.col, 0), #target_line)
    else
        local cursor = vim.api.nvim_win_get_cursor(0)
        cursor_line = cursor[1] - 1
        cursor_col = cursor[2]
    end

    local region_before = math.max(config.editable_region.lines_before or 0, 0)
    local region_after = math.max(config.editable_region.lines_after or 0, 0)

    local start_row = math.max(0, cursor_line - region_before)
    local end_row_inclusive = math.min(line_count - 1, cursor_line + region_after)

    local non_editable_region_before = vim.list_slice(all_lines, 1, start_row)
    local editable_region_lines = vim.list_slice(all_lines, start_row + 1, end_row_inclusive + 1)
    local non_editable_region_after = vim.list_slice(all_lines, end_row_inclusive + 2, #all_lines)

    local cursor_index = cursor_line - start_row + 1
    local current_line = editable_region_lines[cursor_index] or ''

    local editable_region_before_cursor = vim.list_slice(editable_region_lines, 1, cursor_index - 1)
    table.insert(editable_region_before_cursor, current_line:sub(1, cursor_col))

    local editable_region_after_cursor = { current_line:sub(cursor_col + 1) }
    for index = cursor_index + 1, #editable_region_lines do
        table.insert(editable_region_after_cursor, editable_region_lines[index])
    end

    local non_editable_region_before_text = table.concat(non_editable_region_before, '\n')
    local non_editable_region_after_text = table.concat(non_editable_region_after, '\n')
    non_editable_region_before_text, non_editable_region_after_text =
        truncate_non_editable_regions(non_editable_region_before_text, non_editable_region_after_text, config)

    semantic = type(semantic) == 'table' and semantic or {}
    local context_config = config.context or require('minuet.duet.config').context
    local _, path = require('minuet.duet.guards').workspace_path(bufnr)
    local evidence = {
        '<context_evidence>',
        'Current file: ' .. require('minuet.duet.guards').safe_label(path),
        'Filetype: ' .. (vim.bo[bufnr].filetype ~= '' and vim.bo[bufnr].filetype or 'text'),
        'Candidate source: ' .. (candidate and candidate.source or 'cursor'),
    }
    if #(semantic.identifiers or {}) > 0 then
        evidence[#evidence + 1] = 'Changed identifiers: ' .. table.concat(semantic.identifiers, ', ')
    end
    local diagnostic_ok, diagnostics = pcall(vim.diagnostic.get, bufnr)
    diagnostics = diagnostic_ok and diagnostics or {}
    local radius = math.max(context_config.diagnostic_radius or 0, 0)
    local max_diagnostics = math.max(context_config.max_diagnostics or 0, 0)
    local diagnostic_count = 0
    for _, diagnostic in ipairs(diagnostics) do
        if math.abs((diagnostic.lnum or 0) - cursor_line) <= radius and diagnostic_count < max_diagnostics then
            diagnostic_count = diagnostic_count + 1
            local severity = ({ 'ERROR', 'WARN', 'INFO', 'HINT' })[diagnostic.severity] or 'HINT'
            local message = tostring(diagnostic.message or ''):gsub('[\r\n]+', ' ')
            message = vim.fn.strcharpart(message, 0, 200)
            evidence[#evidence + 1] = ('Diagnostic %s line %+d: %s'):format(
                severity,
                (diagnostic.lnum or 0) - cursor_line,
                message
            )
        end
    end
    for _, reference in ipairs(semantic.references or {}) do
        evidence[#evidence + 1] = ('Symbol reference line %+d'):format(reference.row - cursor_line)
    end
    for _, definition in ipairs(semantic.definitions or {}) do
        evidence[#evidence + 1] = ('Symbol definition: %s line %d'):format(
            require('minuet.duet.guards').safe_label(definition.path),
            definition.row + 1
        )
    end
    local related_limit =
        math.min(context_config.related_files.max_chars or 0, math.floor((context_config.max_chars or 0) * 0.25))
    local related = require('minuet.duet.related').render(bufnr, related_limit)
    if related ~= '' then
        evidence[#evidence + 1] = 'Related loaded files:'
        evidence[#evidence + 1] = related
    end
    local evidence_body = table.concat(evidence, '\n')
    local evidence_limit = math.max(context_config.evidence_max_chars or 0, 0)
    local evidence_text = truncate_evidence(evidence_body, evidence_limit)

    local recent_edits = require('minuet.duet.edits').render()
    local editable_chars = vim.fn.strchars(table.concat(editable_region_lines, '\n'))
    local max_chars = math.max(context_config.max_chars or 0, 0)
    if editable_chars > max_chars then
        error 'Duet editable region exceeds context.max_chars'
    end
    local remaining = math.max(max_chars - editable_chars, 0)
    recent_edits = vim.fn.strcharpart(recent_edits, 0, math.floor(remaining * 0.25))
    local final_evidence_limit = math.floor(remaining * 0.35)
    local final_evidence_body = evidence_text:sub(1, math.max(#evidence_text - #EVIDENCE_END, 0))
    evidence_text = truncate_evidence(final_evidence_body, final_evidence_limit)
    remaining = math.max(remaining - vim.fn.strchars(recent_edits) - vim.fn.strchars(evidence_text), 0)
    local combined_before = vim.fn.strchars(non_editable_region_before_text)
    local before_budget = math.min(combined_before, math.floor(remaining * 0.75))
    non_editable_region_before_text =
        vim.fn.strcharpart(non_editable_region_before_text, math.max(combined_before - before_budget, 0))
    local after_budget = math.max(remaining - vim.fn.strchars(non_editable_region_before_text), 0)
    non_editable_region_after_text = vim.fn.strcharpart(non_editable_region_after_text, 0, after_budget)

    return {
        bufnr = bufnr,
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
        non_editable_region_before = non_editable_region_before_text,
        editable_region_before_cursor = table.concat(editable_region_before_cursor, '\n'),
        editable_region_after_cursor = table.concat(editable_region_after_cursor, '\n'),
        non_editable_region_after = non_editable_region_after_text,
        recent_edits = recent_edits,
        context_evidence = evidence_text,
        original_lines = editable_region_lines,
        range = {
            start_row = start_row,
            end_row = end_row_inclusive + 1,
        },
    }
end

return M
