local M = {}

---@param latency table
---@return string
local function format_latency(latency)
    if latency.p50 == nil then
        return 'n/a'
    end
    return ('P50 %.2f ms, P95 %.2f ms, max %.2f ms'):format(latency.p50, latency.p95, latency.max)
end

---@param snapshot table
---@return string
function M.format(snapshot)
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

return M
