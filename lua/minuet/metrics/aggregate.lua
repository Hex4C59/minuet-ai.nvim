local M = {}

---@param capacity integer
---@return table
function M.new_ring(capacity)
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
function M.new_channel(capacity)
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
            request = M.new_ring(capacity),
            first_preview = M.new_ring(capacity),
        },
    }
end

---@param session_id string
---@param started_at integer
---@param started_ns number
---@param capacity integer
---@return table
function M.new_aggregate(session_id, started_at, started_ns, capacity)
    return {
        session_id = session_id,
        started_at = started_at,
        started_ns = started_ns,
        channels = {
            completion = M.new_channel(capacity),
            duet = M.new_channel(capacity),
        },
        dropped_late_events = 0,
        dropped_log_records = 0,
    }
end

---@param ring table
---@return number[]
function M.values(ring)
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
function M.resize_ring(ring, capacity)
    if ring.capacity == capacity then
        return
    end

    local values = M.values(ring)
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
---@param capacity integer
function M.add_latency(ring, value, capacity)
    M.resize_ring(ring, capacity)
    ring.samples = ring.samples + 1
    ring.values[ring.next] = value
    if ring.count < ring.capacity then
        ring.count = ring.count + 1
    end
    ring.next = (ring.next % ring.capacity) + 1
end

---@param ring table
---@return table
function M.latency_snapshot(ring)
    local values = M.values(ring)
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
---@param capacity integer
---@param deep_copy fun(value: any): any
---@return table
function M.channel_snapshot(source, capacity, deep_copy)
    if not source then
        source = M.new_channel(capacity)
    end

    local preview_shown = source.cycles.preview_shown
    return {
        cycles = deep_copy(source.cycles),
        requests = deep_copy(source.requests),
        latency_ms = {
            request = M.latency_snapshot(source.latency.request),
            first_preview = M.latency_snapshot(source.latency.first_preview),
        },
        visible_acceptance_rate = preview_shown > 0 and source.cycles.accepted_visible / preview_shown or nil,
    }
end

return M
