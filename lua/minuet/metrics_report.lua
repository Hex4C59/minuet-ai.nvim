local M = {}

local uv = vim.uv or vim.loop

local EVENTS = {
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
    request_attempted = true,
    request_started = true,
    request_finished = true,
}

local LIFECYCLE_EVENTS = {
    preview_shown = true,
    accepted = true,
    dismissed = true,
    stale = true,
    parse_failed = true,
    filtered = true,
    reverted = true,
}

local COMPLETION_FRONTENDS = {
    virtualtext = true,
    cmp = true,
    blink = true,
    lsp_completion = true,
    lsp_inline_completion = true,
}

local PROVIDERS = {
    openai = true,
    openai_compatible = true,
    openai_fim_compatible = true,
    codestral = true,
    gemini = true,
    claude = true,
    custom = true,
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

local STATUS_ORDER = {
    'success',
    'partial',
    'timeout',
    'cancelled',
    'transport_error',
    'invalid_response',
    'empty_response',
    'spawn_error',
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
---@return boolean
local function is_nonnegative_number(value)
    return type(value) == 'number' and value == value and value >= 0 and value ~= math.huge
end

---@param values number[]
---@return { samples: integer, p50: number?, p95: number?, max: number? }
local function latency_summary(values)
    table.sort(values)
    if #values == 0 then
        return { samples = 0, p50 = nil, p95 = nil, max = nil }
    end
    return {
        samples = #values,
        p50 = values[math.ceil(#values * 0.50)],
        p95 = values[math.ceil(#values * 0.95)],
        max = values[#values],
    }
end

---@return string[]
local function default_patterns()
    local ok, minuet = pcall(require, 'minuet')
    local path = ok
        and type(minuet) == 'table'
        and type(minuet.config) == 'table'
        and type(minuet.config.metrics) == 'table'
        and type(minuet.config.metrics.jsonl) == 'table'
        and minuet.config.metrics.jsonl.path
    if type(path) == 'string' and path ~= '' then
        return { path }
    end

    return { vim.fs.joinpath(vim.fn.stdpath 'state', 'minuet', 'metrics-*.jsonl') }
end

---@param patterns? string|string[]
---@return string[]
local function expand_paths(patterns)
    if type(patterns) == 'string' then
        patterns = { patterns }
    elseif type(patterns) ~= 'table' or #patterns == 0 then
        patterns = default_patterns()
    end

    local paths = {}
    local seen = {}
    for _, pattern in ipairs(patterns) do
        if type(pattern) == 'string' and pattern ~= '' then
            local matches = {}
            local stat_ok, stat = pcall(uv.fs_stat, pattern)
            if stat_ok and stat and stat.type == 'file' then
                matches = { pattern }
            else
                local glob_ok, globbed = pcall(vim.fn.glob, pattern, false, true)
                if glob_ok and type(globbed) == 'table' then
                    matches = globbed
                end
            end

            for _, path in ipairs(matches) do
                local file_ok, file_stat = pcall(uv.fs_stat, path)
                if file_ok and file_stat and file_stat.type == 'file' then
                    local normalized = vim.fs.normalize(path)
                    if not seen[normalized] then
                        seen[normalized] = true
                        paths[#paths + 1] = normalized
                    end
                end
            end
        end
    end
    table.sort(paths)
    return paths
end

---@class minuet.CursorTabQualityReport
---@field files { matched: integer, unreadable: integer, read_errors: integer }
---@field records { total: integer, decoded: integer, duet: integer, ignored: integer, invalid_json: integer, unsupported_schema: integer, invalid: integer, duplicates: integer, conflicts: integer }
---@field sessions integer
---@field cycles { observed: integer, started: integer, missing_start: integer, with_result: integer, preview_shown: integer, accepted: integer, dismissed: integer, stale: integer, parse_failed: integer, filtered: integer, reverted: integer }
---@field visible { shown: integer, accepted: integer, reverted: integer, dismissed: integer, stale: integer, unresolved: integer, terminal_conflicts: integer, acceptance_rate: number?, undo_rate: number?, dismiss_rate: number? }
---@field filters { total: integer, no_op: integer, whitespace_only: integer, too_many_lines: integer, too_many_bytes: integer, repeat: integer, no_op_rate: number? }
---@field requests { finished: integer, outcomes: table<string, integer> }
---@field latency_ms { request: table, first_preview: table }
---@field gate { required_visible: integer, remaining_visible: integer, threshold_met: boolean, integrity_clean: boolean, ready_for_review: boolean }
---@field release_gate table

---@return table
local function new_state()
    local outcomes = {}
    for _, status in ipairs(STATUS_ORDER) do
        outcomes[status] = 0
    end

    return {
        report = {
            files = { matched = 0, unreadable = 0, read_errors = 0 },
            records = {
                total = 0,
                decoded = 0,
                duet = 0,
                ignored = 0,
                invalid_json = 0,
                unsupported_schema = 0,
                invalid = 0,
                duplicates = 0,
                conflicts = 0,
            },
            sessions = 0,
            cycles = {
                observed = 0,
                started = 0,
                missing_start = 0,
                with_result = 0,
                preview_shown = 0,
                accepted = 0,
                dismissed = 0,
                stale = 0,
                parse_failed = 0,
                filtered = 0,
                reverted = 0,
            },
            visible = {
                shown = 0,
                accepted = 0,
                reverted = 0,
                dismissed = 0,
                stale = 0,
                unresolved = 0,
                terminal_conflicts = 0,
                acceptance_rate = nil,
                undo_rate = nil,
                dismiss_rate = nil,
            },
            filters = {
                total = 0,
                no_op = 0,
                whitespace_only = 0,
                too_many_lines = 0,
                too_many_bytes = 0,
                ['repeat'] = 0,
                no_op_rate = nil,
            },
            requests = { finished = 0, outcomes = outcomes },
            latency_ms = {},
            gate = {},
            release_gate = {},
        },
        sessions = {},
        cycles = {},
        seen_records = {},
        request_latencies = {},
        preview_latencies = {},
    }
end

---@param record table
---@return string
local function record_signature(record)
    return table.concat({
        record.event or '',
        tostring(record.request_id or ''),
        tostring(record.request_idx or ''),
        record.status or '',
        record.reason or '',
        tostring(record.duration_ms or ''),
        tostring(record.elapsed_ms or ''),
        tostring(record.n_requests or ''),
    }, '\31')
end

---@param state table
---@param record table
local function ingest_record(state, record)
    local report = state.report
    if record.schema_version ~= 1 then
        report.records.unsupported_schema = report.records.unsupported_schema + 1
        return
    end
    if not EVENTS[record.event] then
        report.records.invalid = report.records.invalid + 1
        return
    end
    if record.channel == 'completion' and (record.frontend == nil or COMPLETION_FRONTENDS[record.frontend]) then
        report.records.ignored = report.records.ignored + 1
        return
    end
    if record.channel ~= 'duet' or record.frontend ~= 'duet' then
        report.records.invalid = report.records.invalid + 1
        return
    end
    if
        type(record.session_id) ~= 'string'
        or record.session_id == ''
        or #record.session_id > 128
        or record.session_id:find '%c'
        or not is_integer(record.timestamp)
        or record.timestamp < 0
        or not PROVIDERS[record.provider_id]
        or not is_integer(record.cycle_id)
        or record.cycle_id < 0
        or (record.reason ~= nil and not REASONS[record.reason])
    then
        report.records.invalid = report.records.invalid + 1
        return
    end
    if REQUEST_EVENTS[record.event] and (not is_integer(record.request_id) or record.request_id < 0) then
        report.records.invalid = report.records.invalid + 1
        return
    end
    if record.event == 'request_finished' and not STATUSES[record.status] then
        report.records.invalid = report.records.invalid + 1
        return
    end
    if record.duration_ms ~= nil and not is_nonnegative_number(record.duration_ms) then
        report.records.invalid = report.records.invalid + 1
        return
    end
    if LIFECYCLE_EVENTS[record.event] and not is_nonnegative_number(record.elapsed_ms) then
        report.records.invalid = report.records.invalid + 1
        return
    end

    report.records.duet = report.records.duet + 1
    state.sessions[record.session_id] = true
    local cycle_key = record.session_id .. '\0' .. record.cycle_id
    local record_key = cycle_key .. '\0' .. record.event
    if REQUEST_EVENTS[record.event] then
        record_key = record_key .. '\0' .. record.request_id
    end

    local signature = record_signature(record)
    if state.seen_records[record_key] then
        report.records.duplicates = report.records.duplicates + 1
        if state.seen_records[record_key] ~= signature then
            report.records.conflicts = report.records.conflicts + 1
        end
        return
    end
    state.seen_records[record_key] = signature

    local cycle = state.cycles[cycle_key]
    if not cycle then
        cycle = { events = {}, reasons = {} }
        state.cycles[cycle_key] = cycle
    end
    cycle.events[record.event] = true
    if record.reason then
        cycle.reasons[record.event] = record.reason
    end

    if record.event == 'request_finished' then
        report.requests.finished = report.requests.finished + 1
        report.requests.outcomes[record.status] = report.requests.outcomes[record.status] + 1
        if record.duration_ms ~= nil then
            state.request_latencies[#state.request_latencies + 1] = record.duration_ms
        end
    elseif record.event == 'preview_shown' then
        state.preview_latencies[#state.preview_latencies + 1] = record.elapsed_ms
    end
end

---@param state table
---@return minuet.CursorTabQualityReport
local function finalize(state)
    local report = state.report
    for _ in pairs(state.sessions) do
        report.sessions = report.sessions + 1
    end

    for _, cycle in pairs(state.cycles) do
        local events = cycle.events
        report.cycles.observed = report.cycles.observed + 1
        if not events.cycle_started then
            report.cycles.missing_start = report.cycles.missing_start + 1
        end
        for _, event in ipairs {
            'cycle_started',
            'with_result',
            'preview_shown',
            'accepted',
            'dismissed',
            'stale',
            'parse_failed',
            'filtered',
            'reverted',
        } do
            local field = event == 'cycle_started' and 'started' or event
            if events[event] then
                report.cycles[field] = report.cycles[field] + 1
            end
        end

        if events.filtered then
            local reason = cycle.reasons.filtered
            report.filters.total = report.filters.total + 1
            if report.filters[reason] ~= nil then
                report.filters[reason] = report.filters[reason] + 1
            end
        end

        if events.preview_shown then
            report.visible.shown = report.visible.shown + 1
            local terminals = 0
            for _, event in ipairs { 'accepted', 'dismissed', 'stale' } do
                if events[event] then
                    report.visible[event] = report.visible[event] + 1
                    terminals = terminals + 1
                end
            end
            if events.reverted and events.accepted then
                report.visible.reverted = report.visible.reverted + 1
            end
            if terminals == 0 then
                report.visible.unresolved = report.visible.unresolved + 1
            elseif terminals > 1 then
                report.visible.terminal_conflicts = report.visible.terminal_conflicts + 1
            end
        end
    end

    if report.visible.shown > 0 then
        report.visible.acceptance_rate = report.visible.accepted / report.visible.shown
        report.visible.dismiss_rate = report.visible.dismissed / report.visible.shown
    end
    if report.visible.accepted > 0 then
        report.visible.undo_rate = report.visible.reverted / report.visible.accepted
    end
    if report.cycles.with_result > 0 then
        report.filters.no_op_rate = (report.filters.no_op + report.filters.whitespace_only) / report.cycles.with_result
    end
    report.latency_ms.request = latency_summary(state.request_latencies)
    report.latency_ms.first_preview = latency_summary(state.preview_latencies)

    local integrity_clean = report.files.unreadable == 0
        and report.files.read_errors == 0
        and report.records.invalid_json == 0
        and report.records.unsupported_schema == 0
        and report.records.invalid == 0
        and report.records.conflicts == 0
        and report.cycles.missing_start == 0
        and report.visible.terminal_conflicts == 0
    report.gate = {
        required_visible = 100,
        remaining_visible = math.max(0, 100 - report.visible.shown),
        threshold_met = report.visible.shown >= 100,
        integrity_clean = integrity_clean,
        ready_for_review = report.visible.shown >= 100 and integrity_clean,
    }
    local parse_failure_rate = report.cycles.with_result > 0 and report.cycles.parse_failed / report.cycles.with_result
        or nil
    local latency_met = report.latency_ms.first_preview.p50 ~= nil
        and report.latency_ms.first_preview.p50 < 1500
        and report.latency_ms.first_preview.p95 < 4000
    local acceptance_met = report.visible.acceptance_rate ~= nil and report.visible.acceptance_rate >= 0.25
    local undo_met = report.visible.undo_rate ~= nil and report.visible.undo_rate < 0.10
    local parse_met = parse_failure_rate ~= nil and parse_failure_rate < 0.02
    local measurable_thresholds_met = latency_met and acceptance_met and undo_met and parse_met
    report.release_gate = {
        required_visible = 500,
        remaining_visible = math.max(0, 500 - report.visible.shown),
        cohort_met = report.visible.shown >= 500,
        latency_met = latency_met,
        acceptance_met = acceptance_met,
        undo_met = undo_met,
        parse_met = parse_met,
        parse_failure_rate = parse_failure_rate,
        measurable_thresholds_met = measurable_thresholds_met,
        integrity_clean = integrity_clean,
        ready_for_release_review = report.visible.shown >= 500 and integrity_clean and measurable_thresholds_met,
    }
    return report
end

---@param patterns? string|string[] Exact JSONL paths or glob patterns. Defaults to the configured metrics path, then the standard session-file glob.
---@return minuet.CursorTabQualityReport
function M.analyze(patterns)
    local state = new_state()
    local paths = expand_paths(patterns)
    state.report.files.matched = #paths

    for _, path in ipairs(paths) do
        local file = io.open(path, 'r')
        if not file then
            state.report.files.unreadable = state.report.files.unreadable + 1
        else
            local read_ok = pcall(function()
                for line in file:lines() do
                    state.report.records.total = state.report.records.total + 1
                    if #line > 65536 then
                        state.report.records.invalid = state.report.records.invalid + 1
                    else
                        local decoded_ok, record = pcall(vim.json.decode, line)
                        if not decoded_ok or type(record) ~= 'table' then
                            state.report.records.invalid_json = state.report.records.invalid_json + 1
                        else
                            state.report.records.decoded = state.report.records.decoded + 1
                            ingest_record(state, record)
                        end
                    end
                end
            end)
            file:close()
            if not read_ok then
                state.report.files.read_errors = state.report.files.read_errors + 1
            end
        end
    end

    return finalize(state)
end

---@param latency table
---@return string
local function format_latency(latency)
    if not latency.p50 then
        return 'n/a'
    end
    return ('P50 %.2f ms, P95 %.2f ms, max %.2f ms (n=%d)'):format(
        latency.p50,
        latency.p95,
        latency.max,
        latency.samples
    )
end

---@param report minuet.CursorTabQualityReport
---@return string
function M.format(report)
    local rate = report.visible.acceptance_rate and ('%.1f%%'):format(report.visible.acceptance_rate * 100) or 'n/a'
    local undo_rate = report.visible.undo_rate and ('%.1f%%'):format(report.visible.undo_rate * 100) or 'n/a'
    local dismiss_rate = report.visible.dismiss_rate and ('%.1f%%'):format(report.visible.dismiss_rate * 100) or 'n/a'
    local no_op_rate = report.filters.no_op_rate and ('%.1f%%'):format(report.filters.no_op_rate * 100) or 'n/a'
    local outcomes = {}
    for _, status in ipairs(STATUS_ORDER) do
        local count = report.requests.outcomes[status]
        if count > 0 then
            outcomes[#outcomes + 1] = status .. '=' .. count
        end
    end

    local gate
    if report.gate.ready_for_review then
        gate = '100-visible threshold reached; provenance review is still required'
    elseif report.gate.threshold_met then
        gate = '100-visible threshold reached, but dataset integrity checks failed'
    else
        gate = ('incomplete; %d more visible suggestions required'):format(report.gate.remaining_visible)
    end
    local release_gate
    if report.release_gate.ready_for_release_review then
        release_gate = 'measurable thresholds reached; provenance, FIM latency, and safety review are still required'
    elseif not report.release_gate.cohort_met then
        release_gate = ('incomplete; %d more visible suggestions required'):format(
            report.release_gate.remaining_visible
        )
    elseif not report.release_gate.integrity_clean then
        release_gate = '500-visible threshold reached, but dataset integrity checks failed'
    else
        release_gate = '500-visible threshold reached, but one or more measurable quality thresholds failed'
    end

    return table.concat({
        'Cursor Tab quality report',
        ('Input: %d file(s), %d session(s), %d JSONL record(s)'):format(
            report.files.matched,
            report.sessions,
            report.records.total
        ),
        ('Records: duet=%d, ignored=%d, duplicate=%d, invalid-json=%d, unsupported-schema=%d, invalid=%d, conflicts=%d'):format(
            report.records.duet,
            report.records.ignored,
            report.records.duplicates,
            report.records.invalid_json,
            report.records.unsupported_schema,
            report.records.invalid,
            report.records.conflicts
        ),
        ('Duet cycles: started=%d, missing-start=%d, result=%d, preview=%d, accepted=%d, reverted=%d, dismissed=%d, stale=%d, filtered=%d, parse-failed=%d'):format(
            report.cycles.started,
            report.cycles.missing_start,
            report.cycles.with_result,
            report.cycles.preview_shown,
            report.cycles.accepted,
            report.cycles.reverted,
            report.cycles.dismissed,
            report.cycles.stale,
            report.cycles.filtered,
            report.cycles.parse_failed
        ),
        ('Visible: accepted=%d, reverted=%d, dismissed=%d, stale=%d, unresolved=%d, terminal-conflicts=%d; acceptance=%s, undo=%s, dismiss=%s'):format(
            report.visible.accepted,
            report.visible.reverted,
            report.visible.dismissed,
            report.visible.stale,
            report.visible.unresolved,
            report.visible.terminal_conflicts,
            rate,
            undo_rate,
            dismiss_rate
        ),
        ('Filtered: total=%d, no-op=%d, whitespace=%d, too-many-lines=%d, too-many-bytes=%d, repeat=%d; no-op rate=%s'):format(
            report.filters.total,
            report.filters.no_op,
            report.filters.whitespace_only,
            report.filters.too_many_lines,
            report.filters.too_many_bytes,
            report.filters['repeat'],
            no_op_rate
        ),
        ('Requests: finished=%d; %s'):format(
            report.requests.finished,
            #outcomes > 0 and table.concat(outcomes, ', ') or 'no outcomes'
        ),
        'Request latency: ' .. format_latency(report.latency_ms.request),
        'First-preview latency: ' .. format_latency(report.latency_ms.first_preview),
        '100-visible data gate: ' .. gate,
        '500-visible release review gate: ' .. release_gate,
        'Provenance cannot be inferred from JSONL; count only records produced by real editing sessions.',
    }, '\n')
end

---@param baseline_patterns? string|string[]
---@param variant_patterns? string|string[]
---@return table
function M.compare(baseline_patterns, variant_patterns)
    local baseline = M.analyze(baseline_patterns)
    local variant = M.analyze(variant_patterns)
    local function delta(left, right)
        if type(left) ~= 'number' or type(right) ~= 'number' then
            return nil
        end
        return right - left
    end
    return {
        baseline = baseline,
        variant = variant,
        delta = {
            visible = variant.visible.shown - baseline.visible.shown,
            acceptance_rate = delta(baseline.visible.acceptance_rate, variant.visible.acceptance_rate),
            undo_rate = delta(baseline.visible.undo_rate, variant.visible.undo_rate),
            dismiss_rate = delta(baseline.visible.dismiss_rate, variant.visible.dismiss_rate),
            no_op_rate = delta(baseline.filters.no_op_rate, variant.filters.no_op_rate),
            preview_p50_ms = delta(baseline.latency_ms.first_preview.p50, variant.latency_ms.first_preview.p50),
            preview_p95_ms = delta(baseline.latency_ms.first_preview.p95, variant.latency_ms.first_preview.p95),
        },
    }
end

---@param patterns? string|string[]
---@return string, minuet.CursorTabQualityReport
function M.notify(patterns)
    local report = M.analyze(patterns)
    local message = M.format(report)
    local level = report.gate.integrity_clean and vim.log.levels.INFO or vim.log.levels.WARN
    pcall(vim.notify, message, level, { title = 'Minuet Cursor Tab report' })
    return message, report
end

return M
