local api = vim.api
local uv = vim.uv or vim.loop

local guards = require 'minuet.duet.guards'

local M = {}

---@class minuet.DuetSemanticLocation
---@field row integer
---@field col integer
---@field name string

---@class minuet.DuetRelatedSemanticLocation: minuet.DuetSemanticLocation
---@field bufnr integer
---@field path string

---@class minuet.DuetSemanticContext
---@field bufnr integer
---@field changedtick integer
---@field identifiers string[]
---@field text_matches minuet.DuetSemanticLocation[]
---@field references minuet.DuetSemanticLocation[]
---@field related_references minuet.DuetRelatedSemanticLocation[]
---@field definitions { path: string, row: integer, name: string }[]
---@field symbols { row: integer, col: integer, name: string, kind: integer? }[]
---@field timed_out boolean

local KEYWORDS = {
    ['and'] = true,
    ['as'] = true,
    ['break'] = true,
    ['class'] = true,
    ['const'] = true,
    ['continue'] = true,
    ['def'] = true,
    ['do'] = true,
    ['else'] = true,
    ['elseif'] = true,
    ['end'] = true,
    ['export'] = true,
    ['false'] = true,
    ['for'] = true,
    ['from'] = true,
    ['function'] = true,
    ['if'] = true,
    ['import'] = true,
    ['in'] = true,
    ['let'] = true,
    ['local'] = true,
    ['nil'] = true,
    ['none'] = true,
    ['not'] = true,
    ['null'] = true,
    ['or'] = true,
    ['return'] = true,
    ['then'] = true,
    ['true'] = true,
    ['var'] = true,
    ['while'] = true,
}

local internal = {
    cache = {},
    inflight = {},
}

---@param value any
---@param default integer
---@param minimum integer
---@param maximum integer
---@return integer
local function integer(value, default, minimum, maximum)
    if type(value) ~= 'number' or value ~= math.floor(value) then
        return default
    end
    return math.min(math.max(value, minimum), maximum)
end

---@return minuet.DuetLspConfig
local function config()
    local current = require('minuet').config.duet.lsp or {}
    local defaults = require('minuet.duet.config').lsp
    return {
        timeout = integer(current.timeout, defaults.timeout, 0, 2000),
        cache_ttl = integer(current.cache_ttl, defaults.cache_ttl, 0, 3600000),
        max_cache_buffers = integer(current.max_cache_buffers, defaults.max_cache_buffers, 1, 256),
        max_identifiers = integer(current.max_identifiers, defaults.max_identifiers, 1, 64),
        max_symbol_queries = integer(current.max_symbol_queries, defaults.max_symbol_queries, 0, 32),
        max_symbols = integer(current.max_symbols, defaults.max_symbols, 1, 1024),
        max_locations = integer(current.max_locations, defaults.max_locations, 1, 1024),
        max_text_matches_per_identifier = integer(
            current.max_text_matches_per_identifier,
            defaults.max_text_matches_per_identifier,
            1,
            128
        ),
    }
end

---@param bufnr integer
---@param limit integer
---@return string[]
local function extract_identifiers(bufnr, limit)
    local weighted = {}
    local order = 0
    local scanned = 0
    local events = require('minuet.duet.edits').get_events()
    for event_index = #events, 1, -1 do
        local event = events[event_index]
        if type(event) == 'table' and event.bufnr == bufnr and type(event.diff) == 'string' then
            for line in event.diff:gmatch '[^\n]+' do
                if scanned >= 8000 then
                    break
                end
                if
                    (vim.startswith(line, '+') and not vim.startswith(line, '+++'))
                    or (vim.startswith(line, '-') and not vim.startswith(line, '---'))
                then
                    scanned = scanned + #line
                    local added = line:sub(1, 1) == '+'
                    for name in line:sub(2):gmatch '[_%a][_%w]*' do
                        local lowered = name:lower()
                        if #name >= 2 and #name <= 64 and not KEYWORDS[lowered] then
                            order = order + 1
                            local age = #events - event_index
                            local score = (added and 2 or 1) * 1000000 - age * 1000 - order
                            weighted[name] = math.max(weighted[name] or -math.huge, score)
                        end
                    end
                end
            end
        end
        if scanned >= 8000 then
            break
        end
    end

    local names = {}
    for name, score in pairs(weighted) do
        names[#names + 1] = { name = name, score = score }
    end
    table.sort(names, function(left, right)
        if left.score ~= right.score then
            return left.score > right.score
        end
        return left.name < right.name
    end)
    local result = {}
    for index = 1, math.min(#names, limit) do
        result[index] = names[index].name
    end
    return result
end

---@param bufnr integer
---@param identifiers string[]
---@param per_identifier integer
---@param total_limit integer
---@return table[]
local function text_matches(bufnr, identifiers, per_identifier, total_limit)
    if #identifiers == 0 then
        return {}
    end
    local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local matches = {}
    local seen = {}
    for _, name in ipairs(identifiers) do
        local count = 0
        local pattern = '%f[_%w]' .. name .. '%f[^_%w]'
        for row, line in ipairs(lines) do
            local start = 1
            while count < per_identifier and #matches < total_limit do
                local first = line:find(pattern, start)
                if not first then
                    break
                end
                local key = (row - 1) .. ':' .. (first - 1)
                if not seen[key] then
                    seen[key] = true
                    matches[#matches + 1] = { row = row - 1, col = first - 1, name = name }
                    count = count + 1
                end
                start = first + #name
            end
            if count >= per_identifier or #matches >= total_limit then
                break
            end
        end
        if #matches >= total_limit then
            break
        end
    end
    return matches
end

---@param client table
---@param method string
---@param bufnr integer
---@return boolean
local function supports(client, method, bufnr)
    if client.name == 'minuet' or type(client.supports_method) ~= 'function' then
        return false
    end
    local ok, supported = pcall(client.supports_method, client, method, bufnr)
    return ok and supported == true
end

---@param items table
---@param output table[]
---@param limit integer
local function flatten_symbols(items, output, limit)
    for _, item in ipairs(type(items) == 'table' and items or {}) do
        if #output >= limit then
            return
        end
        local location = item.location
        local range = item.selectionRange or item.range or (type(location) == 'table' and location.range)
        if type(item.name) == 'string' and type(range) == 'table' and type(range.start) == 'table' then
            output[#output + 1] = {
                name = item.name,
                kind = item.kind,
                row = range.start.line,
                col = range.start.character,
                position = vim.deepcopy(range.start),
                uri = type(location) == 'table' and location.uri or nil,
            }
        end
        flatten_symbols(item.children, output, limit)
    end
end

---@param bufnr integer
---@param row integer
---@param character integer
---@param encoding string?
---@return integer
local function byte_col(bufnr, row, character, encoding)
    local line = api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ''
    local ok, col = pcall(vim.str_byteindex, line, encoding or 'utf-16', character, false)
    return ok and math.min(math.max(col, 0), #line) or math.min(math.max(character, 0), #line)
end

---@param uri string
---@param origin_bufnr integer
---@param root string?
---@param max_size integer
---@return integer?, string?
local function loaded_related_buffer(uri, origin_bufnr, root, max_size)
    if not root or type(uri) ~= 'string' or not vim.startswith(uri, 'file://') then
        return nil
    end
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
        if
            bufnr ~= origin_bufnr
            and guards.is_safe_buffer(bufnr, true, max_size)
            and vim.bo[bufnr].modifiable
            and vim.uri_from_bufnr(bufnr) == uri
        then
            local path = guards.relative_path(root, api.nvim_buf_get_name(bufnr))
            if path then
                return bufnr, guards.safe_label(path)
            end
        end
    end
    return nil
end

---@param pipeline table
local function cancel_requests(pipeline)
    for _, request in ipairs(pipeline.requests) do
        if not request.done then
            pcall(request.client.cancel_request, request.client, request.id)
        end
    end
    pipeline.requests = {}
end

---@param pipeline table
local function abort(pipeline)
    if pipeline.done then
        return
    end
    pipeline.done = true
    if pipeline.timer then
        pipeline.timer:stop()
        pipeline.timer:close()
        pipeline.timer = nil
    end
    cancel_requests(pipeline)
    internal.inflight[pipeline.key] = nil
end

---@param pipeline table
---@param timed_out boolean
local function finish(pipeline, timed_out)
    if pipeline.done then
        return
    end
    pipeline.done = true
    pipeline.result.timed_out = timed_out
    if pipeline.timer then
        pipeline.timer:stop()
        pipeline.timer:close()
        pipeline.timer = nil
    end
    if timed_out then
        cancel_requests(pipeline)
    end
    internal.inflight[pipeline.key] = nil
    pipeline.result.references = vim.tbl_values(pipeline.reference_seen)
    table.sort(pipeline.result.references, function(left, right)
        return left.row == right.row and left.col < right.col or left.row < right.row
    end)
    pipeline.result.related_references = vim.tbl_values(pipeline.related_reference_seen)
    table.sort(pipeline.result.related_references, function(left, right)
        if left.path ~= right.path then
            return left.path < right.path
        elseif left.row ~= right.row then
            return left.row < right.row
        end
        return left.col < right.col
    end)
    pipeline.result.definitions = vim.tbl_values(pipeline.definition_seen)
    table.sort(pipeline.result.definitions, function(left, right)
        return left.path == right.path and left.row < right.row or left.path < right.path
    end)
    internal.cache[pipeline.bufnr] = {
        key = pipeline.key,
        result = vim.deepcopy(pipeline.result),
        created_at = uv.now(),
        used_at = uv.now(),
    }

    local cfg = config()
    local entries = {}
    for bufnr, entry in pairs(internal.cache) do
        entries[#entries + 1] = { bufnr = bufnr, used_at = entry.used_at }
    end
    table.sort(entries, function(left, right)
        return left.used_at < right.used_at
    end)
    while #entries > cfg.max_cache_buffers do
        internal.cache[table.remove(entries, 1).bufnr] = nil
    end

    for _, waiter in ipairs(pipeline.waiters) do
        if not waiter.cancelled then
            waiter.callback(vim.deepcopy(pipeline.result))
        end
    end
end

---@param pipeline table
local function request_done(pipeline)
    pipeline.pending = pipeline.pending - 1
    if pipeline.pending == 0 and pipeline.kickoff_complete then
        finish(pipeline, false)
    end
end

---@param pipeline table
---@param client table
---@param method string
---@param params table
---@param handler fun(result: any)
local function request(pipeline, client, method, params, handler)
    if pipeline.done then
        return
    end
    pipeline.pending = pipeline.pending + 1
    local record = { client = client, done = false }
    local ok, started, request_id = pcall(client.request, client, method, params, function(err, result)
        record.done = true
        if not pipeline.done and not err then
            handler(result)
        end
        request_done(pipeline)
    end, pipeline.bufnr)
    if not ok or started == false then
        request_done(pipeline)
        return
    end
    request_id = request_id or (type(started) == 'number' and started or nil)
    if request_id then
        record.id = request_id
        pipeline.requests[#pipeline.requests + 1] = record
    end
end

---@param bufnr integer
---@param callback fun(result: minuet.DuetSemanticContext)
---@param options? { references?: boolean, text?: boolean, related_buffers?: boolean }
---@return fun()
function M.collect(bufnr, callback, options)
    options = type(options) == 'table' and options or {}
    local cfg = config()
    local changedtick = api.nvim_buf_get_changedtick(bufnr)
    local identifiers = extract_identifiers(bufnr, cfg.max_identifiers)
    local clients = {}
    local client_ids = {}
    if cfg.timeout > 0 and options.references ~= false then
        local clients_ok, attached = pcall(vim.lsp.get_clients, { bufnr = bufnr })
        for _, client in ipairs(clients_ok and attached or {}) do
            if supports(client, 'textDocument/documentSymbol', bufnr) then
                clients[#clients + 1] = client
                client_ids[#client_ids + 1] = tostring(client.id or client.name or #client_ids + 1)
            end
        end
        table.sort(client_ids)
    end
    local fingerprint = table.concat({
        cfg.timeout,
        cfg.max_identifiers,
        cfg.max_symbol_queries,
        cfg.max_symbols,
        cfg.max_locations,
        cfg.max_text_matches_per_identifier,
        options.references == false and 0 or 1,
        options.text == false and 0 or 1,
        options.related_buffers == true and 1 or 0,
        table.concat(client_ids, ','),
    }, ':')
    local key = table.concat({ bufnr, changedtick, fingerprint }, ':')
    local cached = internal.cache[bufnr]
    if cached and cached.key == key and uv.now() - cached.created_at <= cfg.cache_ttl then
        cached.used_at = uv.now()
        callback(vim.deepcopy(cached.result))
        return function() end
    end

    local waiter = { callback = callback, cancelled = false }
    local existing = internal.inflight[key]
    if existing then
        existing.waiters[#existing.waiters + 1] = waiter
        return function()
            waiter.cancelled = true
            for _, current in ipairs(existing.waiters) do
                if not current.cancelled then
                    return
                end
            end
            if not existing.done then
                abort(existing)
            end
        end
    end

    local root = guards.workspace_path(bufnr)
    local current_uri = vim.uri_from_bufnr(bufnr)
    local pipeline = {
        key = key,
        bufnr = bufnr,
        pending = 0,
        kickoff_complete = false,
        done = false,
        requests = {},
        waiters = { waiter },
        reference_seen = {},
        related_reference_seen = {},
        reference_count = 0,
        definition_seen = {},
        definition_count = 0,
        result = {
            bufnr = bufnr,
            changedtick = changedtick,
            identifiers = identifiers,
            text_matches = options.text == false and {}
                or text_matches(bufnr, identifiers, cfg.max_text_matches_per_identifier, cfg.max_locations),
            references = {},
            related_references = {},
            definitions = {},
            symbols = {},
            timed_out = false,
        },
    }
    internal.inflight[key] = pipeline

    if cfg.timeout > 0 and #identifiers > 0 and options.references ~= false then
        local identifier_set = {}
        for _, name in ipairs(identifiers) do
            identifier_set[name] = true
        end
        for _, client in ipairs(clients) do
            request(pipeline, client, 'textDocument/documentSymbol', {
                textDocument = { uri = current_uri },
            }, function(result)
                local flattened = {}
                flatten_symbols(result, flattened, cfg.max_symbols)
                local queries = 0
                for _, symbol in ipairs(flattened) do
                    if identifier_set[symbol.name] and queries < cfg.max_symbol_queries then
                        queries = queries + 1
                        pipeline.result.symbols[#pipeline.result.symbols + 1] = {
                            row = symbol.row,
                            col = symbol.col,
                            name = symbol.name,
                            kind = symbol.kind,
                        }
                        local position_params = {
                            textDocument = { uri = symbol.uri or current_uri },
                            position = symbol.position,
                        }
                        if supports(client, 'textDocument/references', bufnr) then
                            local params = vim.deepcopy(position_params)
                            params.context = { includeDeclaration = false }
                            request(pipeline, client, 'textDocument/references', params, function(locations)
                                for _, location in ipairs(type(locations) == 'table' and locations or {}) do
                                    local uri = location.uri or location.targetUri
                                    local range = location.range or location.targetSelectionRange
                                    if
                                        uri == current_uri
                                        and type(range) == 'table'
                                        and type(range.start) == 'table'
                                    then
                                        local location_key = range.start.line .. ':' .. range.start.character
                                        if
                                            not pipeline.reference_seen[location_key]
                                            and pipeline.reference_count < cfg.max_locations
                                        then
                                            pipeline.reference_count = pipeline.reference_count + 1
                                            pipeline.reference_seen[location_key] = {
                                                row = range.start.line,
                                                col = byte_col(
                                                    pipeline.bufnr,
                                                    range.start.line,
                                                    range.start.character,
                                                    client.offset_encoding
                                                ),
                                                name = symbol.name,
                                            }
                                        end
                                    elseif
                                        options.related_buffers == true
                                        and type(range) == 'table'
                                        and type(range.start) == 'table'
                                        and pipeline.reference_count < cfg.max_locations
                                    then
                                        local max_size = require('minuet').config.duet.auto_trigger.max_buffer_size
                                        local target_bufnr, path =
                                            loaded_related_buffer(uri, pipeline.bufnr, root, max_size)
                                        if target_bufnr and path then
                                            local location_key = target_bufnr
                                                .. ':'
                                                .. range.start.line
                                                .. ':'
                                                .. range.start.character
                                            if not pipeline.related_reference_seen[location_key] then
                                                pipeline.reference_count = pipeline.reference_count + 1
                                                pipeline.related_reference_seen[location_key] = {
                                                    bufnr = target_bufnr,
                                                    row = range.start.line,
                                                    col = byte_col(
                                                        target_bufnr,
                                                        range.start.line,
                                                        range.start.character,
                                                        client.offset_encoding
                                                    ),
                                                    path = path,
                                                    name = symbol.name,
                                                }
                                            end
                                        end
                                    end
                                end
                            end)
                        end
                        if supports(client, 'textDocument/definition', bufnr) then
                            request(pipeline, client, 'textDocument/definition', position_params, function(locations)
                                if locations and locations.uri then
                                    locations = { locations }
                                end
                                for _, location in ipairs(type(locations) == 'table' and locations or {}) do
                                    local uri = location.uri or location.targetUri
                                    local range = location.range or location.targetSelectionRange
                                    local path = guards.uri_path(uri, root)
                                    if path and type(range) == 'table' and type(range.start) == 'table' then
                                        local definition_key = path .. ':' .. range.start.line
                                        if
                                            not pipeline.definition_seen[definition_key]
                                            and pipeline.definition_count < cfg.max_locations
                                        then
                                            pipeline.definition_count = pipeline.definition_count + 1
                                            pipeline.definition_seen[definition_key] = {
                                                path = path,
                                                row = range.start.line,
                                                name = symbol.name,
                                            }
                                        end
                                    end
                                end
                            end)
                        end
                    end
                end
            end)
        end
    end

    pipeline.kickoff_complete = true
    if pipeline.pending == 0 then
        finish(pipeline, false)
    elseif cfg.timeout > 0 then
        pipeline.timer = uv.new_timer()
        pipeline.timer:start(
            cfg.timeout,
            0,
            vim.schedule_wrap(function()
                finish(pipeline, true)
            end)
        )
    end

    return function()
        waiter.cancelled = true
        for _, current in ipairs(pipeline.waiters) do
            if not current.cancelled then
                return
            end
        end
        if not pipeline.done then
            abort(pipeline)
        end
    end
end

function M.reset()
    local pipelines = {}
    for _, pipeline in pairs(internal.inflight) do
        pipelines[#pipelines + 1] = pipeline
    end
    for _, pipeline in ipairs(pipelines) do
        abort(pipeline)
    end
    internal.cache = {}
    internal.inflight = {}
end

---@param bufnr integer
function M.invalidate(bufnr)
    internal.cache[bufnr] = nil
    for origin_bufnr, entry in pairs(internal.cache) do
        for _, location in ipairs(entry.result.related_references or {}) do
            if location.bufnr == bufnr then
                internal.cache[origin_bufnr] = nil
                break
            end
        end
    end
    local pipelines = {}
    for _, pipeline in pairs(internal.inflight) do
        if pipeline.bufnr == bufnr then
            pipelines[#pipelines + 1] = pipeline
        end
    end
    for _, pipeline in ipairs(pipelines) do
        for _, waiter in ipairs(pipeline.waiters) do
            waiter.cancelled = true
        end
        abort(pipeline)
    end
end

M._extract_identifiers = extract_identifiers
M._text_matches = text_matches

return M
