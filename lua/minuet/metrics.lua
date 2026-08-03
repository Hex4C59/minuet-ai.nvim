local M = {}

local uv = vim.uv or vim.loop
local aggregate_ops = require 'minuet.metrics.aggregate'
local lifecycle_ops = require 'minuet.metrics.lifecycle'
local jsonl_ops = require 'minuet.metrics.jsonl'
local session_format = require 'minuet.metrics.session_format'

local DEFAULT_CONFIG = {
    enabled = true,
    max_tracked_cycles = 4096,
    max_latency_samples = 2048,
    jsonl = {
        enabled = false,
        path = nil,
        flush_interval = 1000,
        max_queue = 256,
        max_file_size = 10 * 1024 * 1024,
    },
}

local CHANNELS = {
    completion = true,
    duet = true,
}

local FRONTENDS = {
    virtualtext = true,
    duet = true,
    cmp = true,
    blink = true,
    lsp_completion = true,
    lsp_inline_completion = true,
}

local STATUSES = {
    success = true,
    partial = true,
    timeout = true,
    cancelled = true,
    transport_error = true,
    invalid_response = true,
    empty_response = true,
    spawn_error = true,
}

local REASONS = {
    superseded = true,
    buffer_changed = true,
    context_changed = true,
    buffer_unloaded = true,
    apply_validation = true,
    timeout = true,
    cancelled = true,
    transport_error = true,
    invalid_response = true,
    empty_response = true,
    spawn_error = true,
    invalid_json = true,
    decode_error = true,
    extractor_error = true,
    invalid_markers = true,
    editable_region = true,
    unknown = true,
    no_op = true,
    whitespace_only = true,
    too_many_lines = true,
    too_many_bytes = true,
    ['repeat'] = true,
}

local REQUEST_EVENTS = {
    completion = {
        started_pre = 'MinuetRequestStartedPre',
        started = 'MinuetRequestStarted',
        finished = 'MinuetRequestFinished',
    },
    duet = {
        started_pre = 'MinuetDuetRequestStartedPre',
        started = 'MinuetDuetRequestStarted',
        finished = 'MinuetDuetRequestFinished',
    },
}

---@param value any
---@return boolean
local function is_integer(value)
    return type(value) == 'number'
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
        and value == math.floor(value)
end

---@param value any
---@param default integer
---@param minimum integer
---@return integer
local function config_integer(value, default, minimum)
    if not is_integer(value) or value < minimum then
        return default
    end
    return value
end

---@param value any
---@return string?
local function optional_string(value)
    if type(value) == 'string' and value ~= '' then
        return value
    end
end

---@param value any
---@return string
local function sanitize_channel(value)
    return CHANNELS[value] and value or 'completion'
end

---@param value any
---@return string?
local function sanitize_frontend(value)
    return FRONTENDS[value] and value or nil
end

---@param value any
---@return string?
local function sanitize_reason(value)
    return REASONS[value] and value or nil
end

---@param value any
---@return string
local function sanitize_provider_id(value)
    return optional_string(value) or 'custom'
end

---@param value any
---@return any
local function deep_copy(value)
    if type(value) ~= 'table' then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[deep_copy(key)] = deep_copy(item)
    end
    return result
end

---@param config table?
---@return table
local function normalize_config(config)
    config = type(config) == 'table' and config or {}
    local jsonl = type(config.jsonl) == 'table' and config.jsonl or {}

    return {
        enabled = config.enabled ~= false,
        max_tracked_cycles = config_integer(config.max_tracked_cycles, DEFAULT_CONFIG.max_tracked_cycles, 1),
        max_latency_samples = config_integer(config.max_latency_samples, DEFAULT_CONFIG.max_latency_samples, 1),
        jsonl = {
            enabled = jsonl.enabled == true,
            path = optional_string(jsonl.path),
            flush_interval = config_integer(jsonl.flush_interval, DEFAULT_CONFIG.jsonl.flush_interval, 1),
            max_queue = config_integer(jsonl.max_queue, DEFAULT_CONFIG.jsonl.max_queue, 1),
            max_file_size = config_integer(jsonl.max_file_size, DEFAULT_CONFIG.jsonl.max_file_size, 0),
        },
    }
end

local current_config = normalize_config(DEFAULT_CONFIG)

local session_nonce = 0

---@return table
local function new_aggregate()
    session_nonce = session_nonce + 1
    local started_ns = uv.hrtime()
    local session_id = table.concat({
        tostring(os.time()),
        tostring(math.floor(started_ns % 1000000000)),
        tostring(session_nonce),
    }, '-')

    return aggregate_ops.new_aggregate(session_id, os.time(), started_ns, current_config.max_latency_samples)
end

local aggregate = new_aggregate()
local cycle_sequence = 0
local request_sequence = 0
local evicted_through = 0

---@type table<integer, table>
local cycles = {}
---@type table<integer, table>
local requests = {}

local event_error_notified = false
local logger

---@param message string
---@param level integer
local function safe_notify(message, level)
    local function send()
        pcall(vim.notify, message, level, { title = 'Minuet metrics' })
    end

    if vim.in_fast_event and vim.in_fast_event() then
        vim.schedule(send)
    else
        send()
    end
end

---@param event string
---@param payload table
local function dispatch_event(event, payload)
    local previous_errmsg = vim.v.errmsg
    vim.v.errmsg = ''
    local ok = pcall(vim.api.nvim_exec_autocmds, 'User', {
        pattern = event,
        data = payload,
    })
    local event_errmsg = vim.v.errmsg
    vim.v.errmsg = previous_errmsg
    if (not ok or event_errmsg ~= '') and not event_error_notified then
        event_error_notified = true
        safe_notify('Minuet metrics could not dispatch a lifecycle event.', vim.log.levels.WARN)
    end
end

logger = jsonl_ops.new {
    get_config = function()
        return current_config
    end,
    get_aggregate = function()
        return aggregate
    end,
    is_integer = is_integer,
    sanitize_reason = sanitize_reason,
    safe_notify = safe_notify,
}

---@param record table
local function enqueue_log(record)
    if current_config.enabled then
        logger.enqueue(record)
    end
end

---@param cycle table
---@param event string
---@return table
local function cycle_log_record(cycle, event)
    return {
        event = event,
        timestamp = os.time(),
        channel = cycle.channel,
        frontend = cycle.frontend,
        provider_id = cycle.provider_id,
        cycle_id = cycle.id,
        n_requests = cycle.n_requests,
    }
end

local lifecycle_options = {
    enabled = function()
        return current_config.enabled
    end,
    aggregate = function()
        return aggregate
    end,
    sanitize_reason = sanitize_reason,
    now_ns = uv.hrtime,
    timestamp = os.time,
    add_latency = function(ring, value)
        aggregate_ops.add_latency(ring, value, current_config.max_latency_samples)
    end,
    cycle_log_record = cycle_log_record,
    enqueue_log = enqueue_log,
    dispatch_event = dispatch_event,
}

---@param cycle table
---@return table
local function request_payload(cycle)
    return {
        schema_version = 1,
        channel = cycle.channel,
        cycle_id = cycle.id,
        provider_id = cycle.provider_id,
        provider = cycle.provider,
        name = cycle.name,
        model = cycle.model,
        frontend = cycle.frontend,
        n_requests = cycle.n_requests,
        timestamp = cycle.timestamp,
    }
end

---@param cycle table
---@param meta table?
local function apply_cycle_meta(cycle, meta)
    if type(meta) ~= 'table' then
        return
    end

    local frontend = sanitize_frontend(meta.frontend)
    if frontend then
        cycle.frontend = frontend
    end

    local provider_id = optional_string(meta.provider_id)
    if provider_id then
        cycle.provider_id = provider_id
    end

    local provider = optional_string(meta.provider)
    if provider then
        cycle.provider = provider
    elseif provider_id and cycle.provider == 'custom' then
        cycle.provider = provider_id
    end

    if type(meta.name) == 'string' then
        cycle.name = meta.name
    end
    if type(meta.model) == 'string' then
        cycle.model = meta.model
    end
    if is_integer(meta.n_requests) and meta.n_requests >= 0 then
        cycle.n_requests = meta.n_requests
    end
end

---@param cutoff integer
local function evict_cycles(cutoff)
    if cutoff <= evicted_through then
        return
    end

    for cycle_id, cycle in pairs(cycles) do
        if cycle_id <= cutoff then
            for request_id, _ in pairs(cycle.requests) do
                requests[request_id] = nil
            end
            cycles[cycle_id] = nil
        end
    end
    evicted_through = cutoff
end

---@param cycle_id any
---@return table?
local function tracked_cycle(cycle_id)
    if not is_integer(cycle_id) then
        return
    end

    local cycle = cycles[cycle_id]
    if cycle then
        return cycle
    end
    if cycle_id > 0 and cycle_id <= evicted_through and current_config.enabled then
        aggregate.dropped_late_events = aggregate.dropped_late_events + 1
    end
end

---@param request_id any
---@return table?
local function tracked_request(request_id)
    if not is_integer(request_id) then
        return
    end

    local request = requests[request_id]
    if request then
        return request
    end
    if request_id > 0 and request_id <= request_sequence and current_config.enabled then
        aggregate.dropped_late_events = aggregate.dropped_late_events + 1
    end
end

---@class minuet.MetricsCycleMeta
---@field channel 'completion'|'duet'
---@field frontend? 'virtualtext'|'duet'|'cmp'|'blink'|'lsp_completion'|'lsp_inline_completion'
---@field provider_id? string
---@field provider? string
---@field name? string
---@field model? string
---@field n_requests? integer

---@param meta minuet.MetricsCycleMeta?
---@return integer cycle_id
function M.begin_cycle(meta)
    meta = type(meta) == 'table' and meta or {}
    cycle_sequence = cycle_sequence + 1

    local provider_id = sanitize_provider_id(meta.provider_id or meta.provider)
    local cycle = {
        id = cycle_sequence,
        channel = sanitize_channel(meta.channel),
        frontend = sanitize_frontend(meta.frontend),
        provider_id = provider_id,
        provider = optional_string(meta.provider) or provider_id,
        name = type(meta.name) == 'string' and meta.name or nil,
        model = type(meta.model) == 'string' and meta.model or '',
        n_requests = is_integer(meta.n_requests) and meta.n_requests >= 0 and meta.n_requests or 1,
        timestamp = os.time(),
        started_ns = uv.hrtime(),
        configured = false,
        has_result = false,
        lifecycle = {},
        lifecycle_counted = {},
        accepted_visible = false,
        requests = {},
    }
    cycles[cycle.id] = cycle
    evict_cycles(cycle_sequence - current_config.max_tracked_cycles)

    if current_config.enabled then
        aggregate.channels[cycle.channel].cycles.started = aggregate.channels[cycle.channel].cycles.started + 1
        enqueue_log(cycle_log_record(cycle, 'cycle_started'))
    end

    return cycle.id
end

---@param cycle_id integer
---@param meta minuet.MetricsCycleMeta?
---@return boolean recorded
function M.configure_cycle(cycle_id, meta)
    local cycle = tracked_cycle(cycle_id)
    if not cycle or cycle.configured then
        return false
    end

    apply_cycle_meta(cycle, meta)
    cycle.configured = true

    if current_config.enabled then
        enqueue_log(cycle_log_record(cycle, 'request_started_pre'))
    end
    dispatch_event(REQUEST_EVENTS[cycle.channel].started_pre, request_payload(cycle))
    return true
end

---@param cycle_id integer
---@param request_idx integer
---@return integer request_id
function M.request_attempted(cycle_id, request_idx)
    request_sequence = request_sequence + 1
    local request_id = request_sequence
    local cycle = tracked_cycle(cycle_id)
    if not cycle then
        return request_id
    end

    request_idx = is_integer(request_idx) and request_idx >= 1 and request_idx or 1
    local request = {
        id = request_id,
        cycle_id = cycle.id,
        request_idx = request_idx,
        started = false,
        started_counted = false,
        finished = false,
    }
    requests[request.id] = request
    cycle.requests[request.id] = true

    if current_config.enabled then
        aggregate.channels[cycle.channel].requests.attempted = aggregate.channels[cycle.channel].requests.attempted + 1
        local record = cycle_log_record(cycle, 'request_attempted')
        record.request_id = request.id
        record.request_idx = request.request_idx
        enqueue_log(record)
    end

    return request.id
end

---@param request_id integer
---@return boolean recorded
function M.request_started(request_id)
    local request = tracked_request(request_id)
    if not request or request.started or request.finished then
        return false
    end

    local cycle = cycles[request.cycle_id]
    if not cycle then
        if current_config.enabled then
            aggregate.dropped_late_events = aggregate.dropped_late_events + 1
        end
        return false
    end

    request.started = true
    request.started_ns = uv.hrtime()
    if current_config.enabled then
        request.started_counted = true
        aggregate.channels[cycle.channel].requests.started = aggregate.channels[cycle.channel].requests.started + 1
        local record = cycle_log_record(cycle, 'request_started')
        record.request_id = request.id
        record.request_idx = request.request_idx
        enqueue_log(record)
    end

    local payload = request_payload(cycle)
    payload.request_id = request.id
    payload.request_idx = request.request_idx
    dispatch_event(REQUEST_EVENTS[cycle.channel].started, payload)
    return true
end

---@class minuet.MetricsRequestResult
---@field status string
---@field reason? string
---@field ended_ns? number

---@param request_id integer
---@param result minuet.MetricsRequestResult?
---@return boolean recorded
function M.request_finished(request_id, result)
    local request = tracked_request(request_id)
    if not request or request.finished then
        return false
    end

    local cycle = cycles[request.cycle_id]
    if not cycle then
        if current_config.enabled then
            aggregate.dropped_late_events = aggregate.dropped_late_events + 1
        end
        return false
    end

    result = type(result) == 'table' and result or {}
    local status = STATUSES[result.status] and result.status or 'transport_error'
    local reason = sanitize_reason(result.reason)
    local ended_ns = type(result.ended_ns) == 'number' and result.ended_ns or uv.hrtime()
    local duration_ms
    if request.started and status ~= 'spawn_error' then
        duration_ms = math.max(0, (ended_ns - request.started_ns) / 1000000)
    end

    request.finished = true
    request.status = status
    request.reason = reason
    request.ended_ns = ended_ns

    if current_config.enabled then
        local channel = aggregate.channels[cycle.channel]
        channel.requests.finished = channel.requests.finished + 1
        channel.requests.outcomes[status] = channel.requests.outcomes[status] + 1
        if duration_ms and request.started_counted then
            aggregate_ops.add_latency(channel.latency.request, duration_ms, current_config.max_latency_samples)
        end

        local record = cycle_log_record(cycle, 'request_finished')
        record.request_id = request.id
        record.request_idx = request.request_idx
        record.status = status
        record.reason = reason
        record.duration_ms = duration_ms
        enqueue_log(record)
    end

    local payload = request_payload(cycle)
    payload.request_id = request.id
    payload.request_idx = request.request_idx
    payload.status = status
    payload.reason = reason
    payload.duration_ms = duration_ms
    dispatch_event(REQUEST_EVENTS[cycle.channel].finished, payload)
    return true
end

---@param cycle_id integer
---@return boolean
function M.cycle_has_pending_requests(cycle_id)
    local cycle = is_integer(cycle_id) and cycles[cycle_id] or nil
    if not cycle then
        return false
    end

    for request_id in pairs(cycle.requests) do
        local request = requests[request_id]
        if request and not request.finished then
            return true
        end
    end
    return false
end

---@param cycle_id integer
---@return boolean recorded
function M.cycle_has_result(cycle_id)
    local cycle = tracked_cycle(cycle_id)
    if not cycle or cycle.has_result then
        return false
    end

    cycle.has_result = true
    if current_config.enabled then
        aggregate.channels[cycle.channel].cycles.with_result = aggregate.channels[cycle.channel].cycles.with_result + 1
        enqueue_log(cycle_log_record(cycle, 'with_result'))
    end
    return true
end

---@param cycle_id integer
---@param kind 'preview_shown'|'accepted'|'dismissed'|'stale'|'parse_failed'|'filtered'|'reverted'
---@param reason? string
---@return boolean recorded
function M.suggestion_event(cycle_id, kind, reason)
    if not lifecycle_ops.kinds[kind] then
        return false
    end
    local cycle = tracked_cycle(cycle_id)
    if not cycle then
        return false
    end
    return lifecycle_ops.record(cycle, kind, reason, lifecycle_options)
end

---@return table
function M.get()
    local enabled = current_config.enabled
    local elapsed_ms = math.max(0, (uv.hrtime() - aggregate.started_ns) / 1000000)
    local snapshot = {
        schema_version = 1,
        enabled = enabled,
        session = {
            started_at = aggregate.started_at,
            elapsed_ms = elapsed_ms,
        },
        channels = {
            completion = aggregate_ops.channel_snapshot(
                enabled and aggregate.channels.completion or nil,
                current_config.max_latency_samples,
                deep_copy
            ),
            duet = aggregate_ops.channel_snapshot(
                enabled and aggregate.channels.duet or nil,
                current_config.max_latency_samples,
                deep_copy
            ),
        },
        dropped_late_events = enabled and aggregate.dropped_late_events or 0,
        dropped_log_records = enabled and aggregate.dropped_log_records or 0,
    }
    return deep_copy(snapshot)
end

---@return string
function M.format()
    return session_format.format(M.get())
end

---@return string
function M.notify()
    local message = M.format()
    pcall(vim.notify, message, vim.log.levels.INFO, { title = 'Minuet metrics' })
    return message
end

---@param callback? fun()
---@return boolean
function M._flush(callback)
    return logger.flush(callback)
end

---@param config? table
---@return table
function M.setup(config)
    if config == nil then
        local ok, minuet = pcall(require, 'minuet')
        if ok and type(minuet) == 'table' and type(minuet.config) == 'table' then
            config = minuet.config.metrics
        end
    end

    logger.cleanup()
    current_config = normalize_config(config)

    evict_cycles(cycle_sequence - current_config.max_tracked_cycles)
    for _, channel in pairs(aggregate.channels) do
        aggregate_ops.resize_ring(channel.latency.request, current_config.max_latency_samples)
        aggregate_ops.resize_ring(channel.latency.first_preview, current_config.max_latency_samples)
    end

    if current_config.enabled and current_config.jsonl.enabled then
        logger.setup(current_config.jsonl)
    end
    return M
end

function M._reset()
    logger.cleanup()
    current_config = normalize_config(DEFAULT_CONFIG)
    cycle_sequence = 0
    request_sequence = 0
    evicted_through = 0
    cycles = {}
    requests = {}
    event_error_notified = false
    aggregate = new_aggregate()
end

return M
