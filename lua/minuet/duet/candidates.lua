local api = vim.api
local guards = require 'minuet.duet.guards'

local M = {}

---@alias minuet.DuetCandidateSource 'cursor'|'recent_edit'|'diagnostic'|'reference'|'text'|'related_buffer'

---@class minuet.DuetCandidateMetadata
---@field sources minuet.DuetCandidateSource[]
---@field severity? integer
---@field edit_age? integer
---@field identifier_count? integer

---@class minuet.DuetCandidate
---@field bufnr integer
---@field row integer
---@field col integer
---@field source minuet.DuetCandidateSource
---@field score number
---@field distance integer
---@field metadata minuet.DuetCandidateMetadata

---@class minuet.DuetCandidateCollectOptions
---@field cursor? { row: integer, col: integer }
---@field events? minuet.DuetEditEvent[]
---@field diagnostics? table[]
---@field max_candidates? integer
---@field semantic? minuet.DuetSemanticContext
---@field origin_bufnr? integer

local SOURCE_ORDER = {
    cursor = 1,
    recent_edit = 2,
    diagnostic = 3,
    reference = 4,
    text = 5,
    related_buffer = 6,
}

local SOURCE_LIST = { 'cursor', 'recent_edit', 'diagnostic', 'reference', 'text', 'related_buffer' }

---@param severity integer?
---@return integer
local function diagnostic_score(severity)
    local levels = vim.diagnostic.severity
    if severity == levels.ERROR then
        return 80
    elseif severity == levels.WARN then
        return 60
    elseif severity == levels.INFO then
        return 40
    end
    return 30
end

---@param diff string
---@param line_count integer
---@return integer[]
local function recent_hunk_rows(diff, line_count)
    local rows = {}
    local seen = {}
    for line in diff:gmatch '[^\n]+' do
        local new_start, new_count = line:match '^@@ %-%d+,?%d* %+(%d+),?(%d*) @@'
        if new_start then
            local row = math.max(tonumber(new_start) - 1, 0)
            if new_count == '0' then
                row = math.min(row, line_count - 1)
            end
            if row < line_count and not seen[row] then
                seen[row] = true
                rows[#rows + 1] = row
            end
        end
    end
    return rows
end

---@param bufnr integer
---@param options? minuet.DuetCandidateCollectOptions
---@return minuet.DuetCandidate[]
function M.collect(bufnr, options)
    options = type(options) == 'table' and options or {}
    if
        type(bufnr) ~= 'number'
        or bufnr ~= math.floor(bufnr)
        or not api.nvim_buf_is_valid(bufnr)
        or not api.nvim_buf_is_loaded(bufnr)
        or bufnr ~= api.nvim_get_current_buf()
        or not vim.bo[bufnr].modifiable
    then
        return {}
    end

    local config = require('minuet').config.duet
    local defaults = require 'minuet.duet.config'
    local candidate_config = type(config.candidates) == 'table' and config.candidates or defaults.candidates
    local scope = config.scope == 'cursor' and 'cursor' or (config.scope == 'workspace' and 'workspace' or 'buffer')
    local line_count = math.max(api.nvim_buf_line_count(bufnr), 1)
    local cursor = options.cursor
    if type(cursor) ~= 'table' then
        local window_cursor = api.nvim_win_get_cursor(0)
        cursor = { row = window_cursor[1] - 1, col = window_cursor[2] }
    end
    if
        type(cursor.row) ~= 'number'
        or cursor.row ~= math.floor(cursor.row)
        or type(cursor.col) ~= 'number'
        or cursor.col ~= math.floor(cursor.col)
    then
        return {}
    end
    cursor = { row = cursor.row, col = cursor.col }
    cursor.row = math.min(math.max(cursor.row, 0), line_count - 1)
    local cursor_line = api.nvim_buf_get_lines(bufnr, cursor.row, cursor.row + 1, false)[1] or ''
    cursor.col = math.min(math.max(cursor.col, 0), #cursor_line)

    ---@type table<integer, table>
    local merged = {}

    ---@param row integer
    ---@param col integer
    ---@param source minuet.DuetCandidateSource
    ---@param base_score integer
    ---@param metadata? { severity?: integer, edit_age?: integer, identifier_count?: integer }
    local function add(row, col, source, base_score, metadata)
        if
            type(row) ~= 'number'
            or row ~= math.floor(row)
            or row < 0
            or row >= line_count
            or type(col) ~= 'number'
            or col ~= math.floor(col)
            or col < 0
        then
            return
        end

        local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
        col = math.min(col, #line)
        local candidate = merged[row]
        if not candidate then
            candidate = {
                row = row,
                col = col,
                source_scores = {},
                primary_source = source,
                primary_score = base_score,
            }
            merged[row] = candidate
        end

        local previous = candidate.source_scores[source]
        if not previous or base_score > previous then
            candidate.source_scores[source] = base_score
            if
                base_score > candidate.primary_score
                or (
                    base_score == candidate.primary_score
                    and SOURCE_ORDER[source] < SOURCE_ORDER[candidate.primary_source]
                )
            then
                candidate.primary_source = source
                candidate.primary_score = base_score
                candidate.col = col
            elseif source == candidate.primary_source and base_score == candidate.primary_score then
                candidate.col = math.min(candidate.col, col)
            end
        end

        metadata = metadata or {}
        if source == 'diagnostic' then
            if not candidate.severity or diagnostic_score(metadata.severity) > diagnostic_score(candidate.severity) then
                candidate.severity = metadata.severity
            end
        elseif source == 'recent_edit' then
            if candidate.edit_age == nil or metadata.edit_age < candidate.edit_age then
                candidate.edit_age = metadata.edit_age
            end
        elseif source == 'reference' or source == 'text' then
            candidate.identifier_count = math.max(candidate.identifier_count or 0, metadata.identifier_count or 1)
        end
    end

    if candidate_config.cursor ~= false then
        add(cursor.row, cursor.col, 'cursor', 100)
    end

    if scope ~= 'cursor' and candidate_config.recent_edits ~= false then
        local events = options.events
        if type(events) ~= 'table' then
            events = require('minuet.duet.edits').get_events()
        end
        local edit_age = 0
        for index = #events, 1, -1 do
            local event = events[index]
            if type(event) == 'table' and event.bufnr == bufnr and type(event.diff) == 'string' then
                local base_score = math.max(50, 90 - edit_age * 5)
                for _, row in ipairs(recent_hunk_rows(event.diff, line_count)) do
                    add(row, 0, 'recent_edit', base_score, { edit_age = edit_age })
                end
                edit_age = edit_age + 1
            end
        end
    end

    if scope ~= 'cursor' and candidate_config.diagnostics ~= false then
        local diagnostics = options.diagnostics
        if type(diagnostics) ~= 'table' then
            local ok, current = pcall(vim.diagnostic.get, bufnr)
            diagnostics = ok and type(current) == 'table' and current or {}
        end
        for _, diagnostic in ipairs(diagnostics) do
            if type(diagnostic) == 'table' then
                local severity = diagnostic.severity
                add(diagnostic.lnum, diagnostic.col or 0, 'diagnostic', diagnostic_score(severity), {
                    severity = severity,
                })
            end
        end
    end

    local semantic = type(options.semantic) == 'table' and options.semantic or {}
    if scope ~= 'cursor' and candidate_config.references ~= false then
        for _, location in ipairs(semantic.references or {}) do
            add(location.row, location.col or 0, 'reference', 75, { identifier_count = 1 })
        end
    end
    if scope ~= 'cursor' and candidate_config.text ~= false then
        for _, location in ipairs(semantic.text_matches or {}) do
            add(location.row, location.col or 0, 'text', 45, { identifier_count = 1 })
        end
    end

    local candidates = {}
    for row, candidate in pairs(merged) do
        local score = 0
        local sources = {}
        for _, source in ipairs(SOURCE_LIST) do
            if candidate.source_scores[source] then
                score = score + candidate.source_scores[source]
                sources[#sources + 1] = source
            end
        end
        local distance = math.abs(row - cursor.row)
        candidates[#candidates + 1] = {
            bufnr = bufnr,
            row = row,
            col = candidate.col,
            source = candidate.primary_source,
            score = score - math.min(distance * 0.5, 50),
            distance = distance,
            metadata = {
                sources = sources,
                severity = candidate.severity,
                edit_age = candidate.edit_age,
                identifier_count = candidate.identifier_count,
            },
        }
    end

    local related_paths = {}
    if scope == 'workspace' and candidate_config.related_buffers == true then
        local root = guards.workspace_path(bufnr)
        local max_size = config.auto_trigger.max_buffer_size
        local seen = {}
        for _, location in ipairs(semantic.related_references or {}) do
            local target_bufnr = location.bufnr
            if
                type(target_bufnr) == 'number'
                and target_bufnr ~= bufnr
                and guards.is_safe_buffer(target_bufnr, true, max_size)
                and vim.bo[target_bufnr].modifiable
                and type(location.row) == 'number'
                and location.row == math.floor(location.row)
                and location.row >= 0
                and location.row < api.nvim_buf_line_count(target_bufnr)
            then
                local path = root and guards.relative_path(root, api.nvim_buf_get_name(target_bufnr)) or nil
                if path then
                    local key = target_bufnr .. ':' .. location.row
                    if not seen[key] then
                        seen[key] = true
                        local line = api.nvim_buf_get_lines(target_bufnr, location.row, location.row + 1, false)[1]
                            or ''
                        local col = type(location.col) == 'number' and math.floor(location.col) or 0
                        local candidate = {
                            bufnr = target_bufnr,
                            row = location.row,
                            col = math.min(math.max(col, 0), #line),
                            source = 'related_buffer',
                            score = 55,
                            distance = 0,
                            metadata = { sources = { 'related_buffer' }, identifier_count = 1 },
                        }
                        related_paths[candidate] = guards.safe_label(path)
                        candidates[#candidates + 1] = candidate
                    end
                end
            end
        end
    end

    table.sort(candidates, function(left, right)
        if left.score ~= right.score then
            return left.score > right.score
        elseif SOURCE_ORDER[left.source] ~= SOURCE_ORDER[right.source] then
            return SOURCE_ORDER[left.source] < SOURCE_ORDER[right.source]
        elseif left.distance ~= right.distance then
            return left.distance < right.distance
        elseif left.bufnr ~= right.bufnr then
            local left_path = related_paths[left] or ''
            local right_path = related_paths[right] or ''
            if left_path ~= right_path then
                return left_path < right_path
            end
            return left.bufnr < right.bufnr
        elseif left.row ~= right.row then
            return left.row < right.row
        end
        return left.col < right.col
    end)

    local max_candidates = options.max_candidates or candidate_config.max_candidates
    if type(max_candidates) ~= 'number' or max_candidates ~= math.floor(max_candidates) then
        max_candidates = defaults.candidates.max_candidates
    end
    max_candidates = math.min(math.max(max_candidates, 1), 64)
    while #candidates > max_candidates do
        table.remove(candidates)
    end
    return candidates
end

---@param bufnr integer
---@return minuet.DuetCandidate?
function M.select(bufnr, options)
    return M.collect(bufnr, options)[1]
end

---@param candidate minuet.DuetCandidate?
---@return boolean
function M.exists(candidate, options)
    if type(candidate) ~= 'table' or type(candidate.metadata) ~= 'table' then
        return false
    end
    options = type(options) == 'table' and vim.deepcopy(options) or {}
    options.max_candidates = 64
    local origin_bufnr = options.origin_bufnr or api.nvim_get_current_buf()
    local current = M.collect(origin_bufnr, options)
    local expected_sources = {}
    for _, source in ipairs(candidate.metadata.sources or {}) do
        expected_sources[source] = true
    end
    for _, item in ipairs(current) do
        if item.bufnr == candidate.bufnr and item.row == candidate.row then
            for _, source in ipairs(item.metadata.sources) do
                if expected_sources[source] then
                    return true
                end
            end
        end
    end
    return false
end

return M
