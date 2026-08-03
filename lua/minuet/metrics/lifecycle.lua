local M = {}

M.kinds = {
    preview_shown = true,
    accepted = true,
    dismissed = true,
    stale = true,
    parse_failed = true,
    filtered = true,
    reverted = true,
}

local lifecycle_frontends = {
    virtualtext = true,
    duet = true,
}

---@param cycle table
---@param kind string
---@param reason string?
---@param options table
---@return boolean recorded
function M.record(cycle, kind, reason, options)
    if not M.kinds[kind] or cycle.lifecycle[kind] then
        return false
    end

    local enabled = type(options.enabled) == 'function' and options.enabled() or options.enabled
    local aggregate = type(options.aggregate) == 'function' and options.aggregate() or options.aggregate
    cycle.lifecycle[kind] = true
    cycle.lifecycle_counted[kind] = enabled
    reason = options.sanitize_reason(reason)
    local elapsed_ms = math.max(0, (options.now_ns() - cycle.started_ns) / 1000000)

    if enabled then
        local channel = aggregate.channels[cycle.channel]
        channel.cycles[kind] = channel.cycles[kind] + 1
        if kind == 'preview_shown' then
            options.add_latency(channel.latency.first_preview, elapsed_ms)
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

        local record = options.cycle_log_record(cycle, kind)
        record.reason = reason
        record.elapsed_ms = elapsed_ms
        options.enqueue_log(record)
    end

    local frontend = lifecycle_frontends[cycle.frontend] and cycle.frontend
        or (cycle.channel == 'duet' and 'duet' or 'virtualtext')
    options.dispatch_event('MinuetSuggestionLifecycle', {
        schema_version = 1,
        kind = kind,
        channel = cycle.channel,
        cycle_id = cycle.id,
        provider_id = cycle.provider_id,
        frontend = frontend,
        timestamp = options.timestamp(),
        elapsed_ms = elapsed_ms,
        reason = reason,
    })
    return true
end

return M
