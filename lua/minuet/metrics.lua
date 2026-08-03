local M = {}

local uv = vim.uv or vim.loop

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

local LIFECYCLE_FRONTENDS = {
    virtualtext = true,
    duet = true,
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

local LIFECYCLE_KINDS = {
    preview_shown = true,
    accepted = true,
    dismissed = true,
    stale = true,
    parse_failed = true,
    filtered = true,
    reverted = true,
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

local BUILTIN_PROVIDERS = {
    openai = true,
    openai_compatible = true,
    openai_fim_compatible = true,
    codestral = true,
    gemini = true,
    claude = true,
}

local LOG_EVENTS = {
    cycle_started = true,
    request_started_pre = true,
    request_attempted = true,
    request_started = true,
    request_finished = true,
    with_result = true,
    preview_shown = true,
    accepted = true,
    dismissed = true,
    stale = true,
    parse_failed = true,
    filtered = true,
    reverted = true,
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

---@param capacity integer
---@return table
local function new_ring(capacity)
    return {
        capacity = capacity,
        count = 0,
        next = 1,
        samples = 0,
        values = {},
    }
end

---@param capacity integer
---@return table
local function new_channel(capacity)
    return {
        cycles = {
            started = 0,
            with_result = 0,
            preview_shown = 0,
            accepted = 0,
            accepted_visible = 0,
            dismissed = 0,
            stale = 0,
            parse_failed = 0,
            filtered = 0,
            reverted = 0,
        },
        requests = {
            attempted = 0,
            started = 0,
            finished = 0,
            outcomes = {
                success = 0,
                partial = 0,
                timeout = 0,
                cancelled = 0,
                transport_error = 0,
                invalid_response = 0,
                empty_response = 0,
                spawn_error = 0,
            },
        },
        latency = {
            request = new_ring(capacity),
            first_preview = new_ring(capacity),
        },
    }
end

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

    return {
        session_id = session_id,
        started_at = os.time(),
        started_ns = started_ns,
        channels = {
            completion = new_channel(current_config.max_latency_samples),
            duet = new_channel(current_config.max_latency_samples),
        },
        dropped_late_events = 0,
        dropped_log_records = 0,
    }
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
---@type table?
local logger
local flush_logger
local arm_logger_timer

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

---@param ring table
---@return number[]
local function ring_values(ring)
    local values = {}
    if ring.count == 0 then
        return values
    end

    local first = ring.count == ring.capacity and ring.next or 1
    for offset = 0, ring.count - 1 do
        local index = ((first + offset - 1) % ring.capacity) + 1
        values[#values + 1] = ring.values[index]
    end
    return values
end

---@param ring table
---@param capacity integer
local function resize_ring(ring, capacity)
    if ring.capacity == capacity then
        return
    end

    local values = ring_values(ring)
    local first = math.max(1, #values - capacity + 1)
    ring.values = {}
    ring.count = 0
    ring.capacity = capacity

    for index = first, #values do
        ring.count = ring.count + 1
        ring.values[ring.count] = values[index]
    end
    ring.next = ring.count == capacity and 1 or ring.count + 1
end

---@param ring table
---@param value number
local function add_latency(ring, value)
    resize_ring(ring, current_config.max_latency_samples)
    ring.samples = ring.samples + 1
    ring.values[ring.next] = value
    if ring.count < ring.capacity then
        ring.count = ring.count + 1
    end
    ring.next = (ring.next % ring.capacity) + 1
end

---@param timer any
local function close_timer(timer)
    if not timer then
        return
    end
    pcall(timer.stop, timer)
    local ok, closing = pcall(timer.is_closing, timer)
    if not ok or not closing then
        pcall(timer.close, timer)
    end
end

---@param log table
local function run_flush_callbacks(log)
    local callbacks = log.flush_callbacks
    log.flush_callbacks = {}
    for _, callback in ipairs(callbacks) do
        local function invoke()
            pcall(callback)
        end
        if vim.in_fast_event and vim.in_fast_event() then
            vim.schedule(invoke)
        else
            invoke()
        end
    end
end

---@param log table
local function cleanup_logger(log)
    if not log then
        return
    end
    log.active = false
    if log.timer then
        close_timer(log.timer)
        log.timer = nil
    end
    log.queue = {}
    run_flush_callbacks(log)
end

---@param log table
---@param message string
local function fail_logger(log, message)
    if not log.active then
        return
    end
    log.active = false
    if log.timer then
        close_timer(log.timer)
        log.timer = nil
    end
    log.queue = {}
    log.writing = false
    if not log.failure_notified then
        log.failure_notified = true
        safe_notify(message, vim.log.levels.WARN)
    end
    run_flush_callbacks(log)
end

---@param fd integer
---@param callback fun(error: any)
local function close_file(fd, callback)
    local ok = pcall(uv.fs_close, fd, function(err)
        callback(err)
    end)
    if not ok then
        callback(true)
    end
end

---@param log table
local function finish_logger_batch(log)
    log.writing = false
    if not log.active then
        run_flush_callbacks(log)
        return
    end

    if #log.queue > 0 then
        if log.flush_requested then
            flush_logger(log)
        else
            arm_logger_timer(log)
        end
        return
    end

    log.flush_requested = false
    run_flush_callbacks(log)
end

flush_logger = function(log)
    if not log or not log.active or log.writing then
        return
    end
    if #log.queue == 0 then
        log.flush_requested = false
        run_flush_callbacks(log)
        return
    end

    if log.timer then
        close_timer(log.timer)
        log.timer = nil
    end

    local batch = log.queue
    log.queue = {}
    local data = table.concat(batch, '\n') .. '\n'
    log.writing = true

    local open_ok = pcall(uv.fs_open, log.path, 'a', 384, function(open_err, fd)
        if open_err or not fd then
            fail_logger(log, 'Minuet metrics JSONL logger failed and was disabled.')
            return
        end

        local function abort_write(message)
            close_file(fd, function()
                fail_logger(log, message)
            end)
        end

        local function stat_and_write()
            if not log.active then
                close_file(fd, function() end)
                return
            end

            local stat_ok = pcall(uv.fs_fstat, fd, function(stat_err, stat)
                if stat_err or type(stat) ~= 'table' or type(stat.size) ~= 'number' then
                    abort_write 'Minuet metrics JSONL logger failed and was disabled.'
                    return
                end
                if stat.size >= log.max_file_size or stat.size + #data > log.max_file_size then
                    abort_write 'Minuet metrics JSONL logger reached its size limit and was disabled.'
                    return
                end

                local function write_from(written)
                    if not log.active then
                        close_file(fd, function() end)
                        return
                    end
                    if written >= #data then
                        close_file(fd, function(close_err)
                            if close_err then
                                fail_logger(log, 'Minuet metrics JSONL logger failed and was disabled.')
                            else
                                finish_logger_batch(log)
                            end
                        end)
                        return
                    end

                    local write_ok = pcall(
                        uv.fs_write,
                        fd,
                        data:sub(written + 1),
                        stat.size + written,
                        function(write_err, bytes_written)
                            if write_err or type(bytes_written) ~= 'number' or bytes_written <= 0 then
                                abort_write 'Minuet metrics JSONL logger failed and was disabled.'
                                return
                            end
                            write_from(written + bytes_written)
                        end
                    )
                    if not write_ok then
                        abort_write 'Minuet metrics JSONL logger failed and was disabled.'
                    end
                end

                write_from(0)
            end)
            if not stat_ok then
                abort_write 'Minuet metrics JSONL logger failed and was disabled.'
            end
        end

        if uv.fs_fchmod then
            local chmod_ok = pcall(uv.fs_fchmod, fd, 384, function()
                stat_and_write()
            end)
            if not chmod_ok then
                stat_and_write()
            end
        else
            stat_and_write()
        end
    end)

    if not open_ok then
        fail_logger(log, 'Minuet metrics JSONL logger failed and was disabled.')
    end
end

arm_logger_timer = function(log)
    if not log or not log.active or log.writing or log.timer or #log.queue == 0 then
        return
    end

    local ok, timer = pcall(uv.new_timer)
    if not ok or not timer then
        fail_logger(log, 'Minuet metrics JSONL logger failed and was disabled.')
        return
    end

    log.timer = timer
    local started = pcall(timer.start, timer, log.flush_interval, 0, function()
        if log.timer == timer then
            log.timer = nil
        end
        close_timer(timer)
        flush_logger(log)
    end)
    if not started then
        log.timer = nil
        close_timer(timer)
        fail_logger(log, 'Minuet metrics JSONL logger failed and was disabled.')
    end
end

---@param record table
---@return table?
local function sanitize_log_record(record)
    if not LOG_EVENTS[record.event] then
        return
    end

    local sanitized = {
        schema_version = 1,
        session_id = aggregate.session_id,
        event = record.event,
        timestamp = is_integer(record.timestamp) and record.timestamp or os.time(),
    }

    if CHANNELS[record.channel] then
        sanitized.channel = record.channel
    end
    if FRONTENDS[record.frontend] then
        sanitized.frontend = record.frontend
    end
    if BUILTIN_PROVIDERS[record.provider_id] then
        sanitized.provider_id = record.provider_id
    elseif record.provider_id ~= nil then
        sanitized.provider_id = 'custom'
    end

    for _, key in ipairs { 'cycle_id', 'request_id', 'n_requests', 'request_idx' } do
        if is_integer(record[key]) and record[key] >= 0 then
            sanitized[key] = record[key]
        end
    end

    if STATUSES[record.status] then
        sanitized.status = record.status
    end
    sanitized.reason = sanitize_reason(record.reason)

    for _, key in ipairs { 'duration_ms', 'elapsed_ms' } do
        local value = record[key]
        if type(value) == 'number' and value == value and value >= 0 and value ~= math.huge then
            sanitized[key] = value
        end
    end

    return sanitized
end

---@param record table
local function enqueue_log(record)
    local log = logger
    if not current_config.enabled or not log or not log.active then
        return
    end

    local sanitized = sanitize_log_record(record)
    if not sanitized then
        return
    end

    if #log.queue >= log.max_queue then
        aggregate.dropped_log_records = aggregate.dropped_log_records + 1
        if not log.queue_notified then
            log.queue_notified = true
            safe_notify('Minuet metrics JSONL queue is full; records are being dropped.', vim.log.levels.WARN)
        end
        return
    end

    local ok, encoded = pcall(vim.json.encode, sanitized)
    if not ok or type(encoded) ~= 'string' then
        fail_logger(log, 'Minuet metrics JSONL logger failed and was disabled.')
        return
    end

    log.queue[#log.queue + 1] = encoded
    arm_logger_timer(log)
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
            add_latency(channel.latency.request, duration_ms)
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
    if not LIFECYCLE_KINDS[kind] then
        return false
    end

    local cycle = tracked_cycle(cycle_id)
    if not cycle or cycle.lifecycle[kind] then
        return false
    end

    cycle.lifecycle[kind] = true
    cycle.lifecycle_counted[kind] = current_config.enabled
    reason = sanitize_reason(reason)
    local elapsed_ms = math.max(0, (uv.hrtime() - cycle.started_ns) / 1000000)

    if current_config.enabled then
        local channel = aggregate.channels[cycle.channel]
        channel.cycles[kind] = channel.cycles[kind] + 1
        if kind == 'preview_shown' then
            add_latency(channel.latency.first_preview, elapsed_ms)
        end

        if
            cycle.lifecycle.accepted
            and cycle.lifecycle.preview_shown
            and cycle.lifecycle_counted.accepted
            and cycle.lifecycle_counted.preview_shown
            and not cycle.accepted_visible
        then
            cycle.accepted_visible = true
            channel.cycles.accepted_visible = channel.cycles.accepted_visible + 1
        end

        local record = cycle_log_record(cycle, kind)
        record.reason = reason
        record.elapsed_ms = elapsed_ms
        enqueue_log(record)
    end

    local frontend = LIFECYCLE_FRONTENDS[cycle.frontend] and cycle.frontend
        or (cycle.channel == 'duet' and 'duet' or 'virtualtext')
    dispatch_event('MinuetSuggestionLifecycle', {
        schema_version = 1,
        kind = kind,
        channel = cycle.channel,
        cycle_id = cycle.id,
        provider_id = cycle.provider_id,
        frontend = frontend,
        timestamp = os.time(),
        elapsed_ms = elapsed_ms,
        reason = reason,
    })
    return true
end

---@param ring table
---@return table
local function latency_snapshot(ring)
    local values = ring_values(ring)
    table.sort(values)
    local retained = #values
    if retained == 0 then
        return {
            samples = ring.samples,
            retained = 0,
            p50 = nil,
            p95 = nil,
            max = nil,
        }
    end

    return {
        samples = ring.samples,
        retained = retained,
        p50 = values[math.ceil(retained * 0.50)],
        p95 = values[math.ceil(retained * 0.95)],
        max = values[retained],
    }
end

---@param source table?
---@return table
local function channel_snapshot(source)
    if not source then
        source = new_channel(current_config.max_latency_samples)
    end

    local preview_shown = source.cycles.preview_shown
    return {
        cycles = deep_copy(source.cycles),
        requests = deep_copy(source.requests),
        latency_ms = {
            request = latency_snapshot(source.latency.request),
            first_preview = latency_snapshot(source.latency.first_preview),
        },
        visible_acceptance_rate = preview_shown > 0 and source.cycles.accepted_visible / preview_shown or nil,
    }
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
            completion = channel_snapshot(enabled and aggregate.channels.completion or nil),
            duet = channel_snapshot(enabled and aggregate.channels.duet or nil),
        },
        dropped_late_events = enabled and aggregate.dropped_late_events or 0,
        dropped_log_records = enabled and aggregate.dropped_log_records or 0,
    }
    return deep_copy(snapshot)
end

---@param latency table
---@return string
local function format_latency(latency)
    if latency.p50 == nil then
        return 'n/a'
    end
    return ('P50 %.2f ms, P95 %.2f ms, max %.2f ms'):format(latency.p50, latency.p95, latency.max)
end

---@return string
function M.format()
    local snapshot = M.get()
    if not snapshot.enabled then
        return 'Minuet metrics are disabled.'
    end

    local lines = { ('Minuet session metrics (%.1f s)'):format(snapshot.session.elapsed_ms / 1000) }
    for _, name in ipairs { 'completion', 'duet' } do
        local channel = snapshot.channels[name]
        local cycles_snapshot = channel.cycles
        local requests_snapshot = channel.requests
        local rate = channel.visible_acceptance_rate and ('%.1f%%'):format(channel.visible_acceptance_rate * 100)
            or 'n/a'
        lines[#lines + 1] = ('%s: cycles %d, results %d; requests %d attempted, %d started, %d finished'):format(
            name,
            cycles_snapshot.started,
            cycles_snapshot.with_result,
            requests_snapshot.attempted,
            requests_snapshot.started,
            requests_snapshot.finished
        )
        lines[#lines + 1] = ('  request latency: %s'):format(format_latency(channel.latency_ms.request))
        lines[#lines + 1] = ('  preview %d, accepted %d, reverted %d, dismissed %d, stale %d, filtered %d, parse failed %d; visible acceptance %s'):format(
            cycles_snapshot.preview_shown,
            cycles_snapshot.accepted,
            cycles_snapshot.reverted,
            cycles_snapshot.dismissed,
            cycles_snapshot.stale,
            cycles_snapshot.filtered,
            cycles_snapshot.parse_failed,
            rate
        )
    end
    lines[#lines + 1] = 'UI lifecycle coverage: virtual text and Duet only.'
    if snapshot.dropped_late_events > 0 or snapshot.dropped_log_records > 0 then
        lines[#lines + 1] = ('Dropped events: %d late, %d log records'):format(
            snapshot.dropped_late_events,
            snapshot.dropped_log_records
        )
    end
    return table.concat(lines, '\n')
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
    local log = logger
    if not log or not log.active then
        if callback then
            pcall(callback)
        end
        return false
    end

    if callback then
        log.flush_callbacks[#log.flush_callbacks + 1] = callback
    end
    log.flush_requested = true
    if log.timer then
        close_timer(log.timer)
        log.timer = nil
    end
    if log.writing then
        return true
    end
    flush_logger(log)
    return true
end

---@param config table
local function setup_logger(config)
    local path = config.path
    local default_path = path == nil
    local directory
    if default_path then
        directory = vim.fs.joinpath(vim.fn.stdpath 'state', 'minuet')
        path = vim.fs.joinpath(directory, 'metrics-' .. aggregate.session_id .. '.jsonl')
    else
        directory = vim.fn.fnamemodify(path, ':h')
        if directory == '' then
            directory = '.'
        end
    end

    logger = {
        active = true,
        path = path,
        queue = {},
        timer = nil,
        writing = false,
        flush_requested = false,
        flush_callbacks = {},
        flush_interval = config.flush_interval,
        max_queue = config.max_queue,
        max_file_size = config.max_file_size,
        queue_notified = false,
        failure_notified = false,
    }

    local stat_ok, stat = pcall(uv.fs_stat, directory)
    if not stat_ok or not stat then
        local mkdir_ok = pcall(vim.fn.mkdir, directory, 'p', 448)
        local verify_ok, verified = pcall(uv.fs_stat, directory)
        if not mkdir_ok or not verify_ok or not verified then
            fail_logger(logger, 'Minuet metrics JSONL logger failed and was disabled.')
            return
        end
        pcall(uv.fs_chmod, directory, 448)
    elseif default_path then
        pcall(uv.fs_chmod, directory, 448)
    end
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

    cleanup_logger(logger)
    logger = nil
    current_config = normalize_config(config)

    evict_cycles(cycle_sequence - current_config.max_tracked_cycles)
    for _, channel in pairs(aggregate.channels) do
        resize_ring(channel.latency.request, current_config.max_latency_samples)
        resize_ring(channel.latency.first_preview, current_config.max_latency_samples)
    end

    if current_config.enabled and current_config.jsonl.enabled then
        setup_logger(current_config.jsonl)
    end
    return M
end

function M._reset()
    cleanup_logger(logger)
    logger = nil
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
