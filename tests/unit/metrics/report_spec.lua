local helpers = require 'tests.helpers'

---@param session_id string
---@param cycle_id integer
---@param event string
---@param extra? table
---@return table
local function record(session_id, cycle_id, event, extra)
    return vim.tbl_extend('force', {
        schema_version = 1,
        session_id = session_id,
        event = event,
        timestamp = 1,
        channel = 'duet',
        frontend = 'duet',
        provider_id = 'openai_compatible',
        cycle_id = cycle_id,
    }, extra or {})
end

---@param path string
---@param records table[]
---@param raw_lines? string[]
local function write_records(path, records, raw_lines)
    local lines = {}
    for _, item in ipairs(records) do
        lines[#lines + 1] = vim.json.encode(item)
    end
    vim.list_extend(lines, raw_lines or {})
    vim.fn.writefile(lines, path)
end

return {
    {
        name = 'metrics report aggregates unique Duet lifecycles across sessions',
        run = function()
            helpers.ensure_runtime()
            package.loaded['minuet.metrics_report'] = nil
            local report_module = require 'minuet.metrics_report'
            local directory = vim.fn.tempname()
            vim.fn.mkdir(directory, 'p')
            local first_path = directory .. '/first.jsonl'
            local second_path = directory .. '/second.jsonl'

            local ok, err = xpcall(function()
                local first = {
                    record('session-one', 1, 'cycle_started'),
                    record('session-one', 1, 'with_result'),
                    record('session-one', 1, 'request_finished', {
                        request_id = 1,
                        status = 'success',
                        duration_ms = 10,
                    }),
                    record('session-one', 1, 'preview_shown', { elapsed_ms = 100 }),
                    record('session-one', 1, 'accepted', { elapsed_ms = 150 }),
                    record('session-one', 1, 'preview_shown', { elapsed_ms = 100 }),
                    record('session-one', 2, 'cycle_started'),
                    record('session-one', 2, 'preview_shown', { elapsed_ms = 300 }),
                    record('session-one', 2, 'dismissed', { elapsed_ms = 350 }),
                    record('session-one', 3, 'cycle_started'),
                    record('session-one', 3, 'stale', { elapsed_ms = 20 }),
                    record('session-one', 4, 'cycle_started'),
                    record('session-one', 4, 'parse_failed', { elapsed_ms = 30 }),
                    vim.tbl_extend('force', record('ignored-session', 1, 'cycle_started'), {
                        channel = 'completion',
                        frontend = 'virtualtext',
                    }),
                }
                write_records(first_path, first)

                local second = {
                    record('session-two', 1, 'cycle_started'),
                    record('session-two', 1, 'request_finished', {
                        request_id = 1,
                        status = 'timeout',
                        duration_ms = 30,
                    }),
                    record('session-two', 1, 'preview_shown', { elapsed_ms = 200 }),
                    record('session-two', 1, 'stale', { elapsed_ms = 220 }),
                    record('session-two', 2, 'cycle_started'),
                    record('session-two', 2, 'accepted', { elapsed_ms = 10 }),
                    vim.tbl_extend('force', record('unsupported', 1, 'cycle_started'), { schema_version = 2 }),
                }
                write_records(second_path, second, { '{not-json' })

                local report = report_module.analyze { first_path, second_path }
                helpers.expect_equal(report.files.matched, 2)
                helpers.expect_equal(report.sessions, 2)
                helpers.expect_equal(report.records.duplicates, 1)
                helpers.expect_equal(report.records.ignored, 1)
                helpers.expect_equal(report.records.invalid_json, 1)
                helpers.expect_equal(report.records.unsupported_schema, 1)
                helpers.expect_equal(report.cycles.observed, 6)
                helpers.expect_equal(report.cycles.started, 6)
                helpers.expect_equal(report.cycles.with_result, 1)
                helpers.expect_equal(report.cycles.preview_shown, 3)
                helpers.expect_equal(report.cycles.accepted, 2)
                helpers.expect_equal(report.cycles.dismissed, 1)
                helpers.expect_equal(report.cycles.stale, 2)
                helpers.expect_equal(report.cycles.parse_failed, 1)
                helpers.expect_equal(report.visible.accepted, 1)
                helpers.expect_equal(report.visible.dismissed, 1)
                helpers.expect_equal(report.visible.stale, 1)
                helpers.expect_equal(report.visible.unresolved, 0)
                helpers.expect_equal(report.visible.acceptance_rate, 1 / 3)
                helpers.expect_equal(report.requests.finished, 2)
                helpers.expect_equal(report.requests.outcomes.success, 1)
                helpers.expect_equal(report.requests.outcomes.timeout, 1)
                helpers.expect_equal(report.latency_ms.request.p50, 10)
                helpers.expect_equal(report.latency_ms.request.p95, 30)
                helpers.expect_equal(report.latency_ms.first_preview.p50, 200)
                helpers.expect_equal(report.latency_ms.first_preview.p95, 300)
                helpers.expect_falsy(report.gate.integrity_clean)
                helpers.expect_falsy(report.gate.ready_for_review)
                helpers.expect_equal(report.gate.remaining_visible, 97)
            end, debug.traceback)

            package.loaded['minuet.metrics_report'] = nil
            vim.fn.delete(directory, 'rf')
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics report reaches the visible gate without exposing ignored fields or paths',
        run = function()
            helpers.ensure_runtime()
            package.loaded['minuet.metrics_report'] = nil
            local report_module = require 'minuet.metrics_report'
            local directory = vim.fn.tempname()
            vim.fn.mkdir(directory, 'p')
            local path = directory .. '/quality.jsonl'
            local sentinel = 'QUALITY_REPORT_PRIVATE_SENTINEL_1f72'

            local ok, err = xpcall(function()
                local records = {}
                for cycle_id = 1, 100 do
                    records[#records + 1] = record('real-session', cycle_id, 'cycle_started')
                    records[#records + 1] = record('real-session', cycle_id, 'preview_shown', {
                        elapsed_ms = cycle_id,
                        prompt = sentinel,
                        path = path,
                    })
                    records[#records + 1] = record('real-session', cycle_id, 'accepted', {
                        elapsed_ms = cycle_id + 1,
                        response = sentinel,
                    })
                end
                write_records(path, records)

                local report = report_module.analyze { path, path }
                local message = report_module.format(report)
                helpers.expect_equal(report.files.matched, 1)
                helpers.expect_equal(report.sessions, 1)
                helpers.expect_equal(report.visible.shown, 100)
                helpers.expect_equal(report.visible.accepted, 100)
                helpers.expect_equal(report.visible.acceptance_rate, 1)
                helpers.expect_truthy(report.gate.threshold_met)
                helpers.expect_truthy(report.gate.integrity_clean)
                helpers.expect_truthy(report.gate.ready_for_review)
                helpers.expect_truthy(message:find('provenance review is still required', 1, true))
                helpers.expect_falsy(message:find(sentinel, 1, true))
                helpers.expect_falsy(message:find(path, 1, true))
            end, debug.traceback)

            package.loaded['minuet.metrics_report'] = nil
            vim.fn.delete(directory, 'rf')
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics report handles an empty input cohort without claiming success',
        run = function()
            helpers.ensure_runtime()
            package.loaded['minuet.metrics_report'] = nil
            local report_module = require 'minuet.metrics_report'
            local missing = vim.fn.tempname() .. '/*.jsonl'
            local report = report_module.analyze { missing }
            local message = report_module.format(report)

            helpers.expect_equal(report.files.matched, 0)
            helpers.expect_equal(report.visible.shown, 0)
            helpers.expect_equal(report.gate.remaining_visible, 100)
            helpers.expect_falsy(report.gate.threshold_met)
            helpers.expect_truthy(message:find('100 more visible suggestions required', 1, true))
            helpers.expect_falsy(message:find(missing, 1, true))
            package.loaded['minuet.metrics_report'] = nil
        end,
    },
    {
        name = 'metrics report fails integrity checks for malformed provenance and lifecycles',
        run = function()
            helpers.ensure_runtime()
            package.loaded['minuet.metrics_report'] = nil
            local report_module = require 'minuet.metrics_report'
            local path = vim.fn.tempname() .. '.jsonl'

            local ok, err = xpcall(function()
                write_records(path, {
                    record('missing-start', 1, 'preview_shown', { elapsed_ms = 10 }),
                    record('complete-cycle', 1, 'cycle_started'),
                    record('complete-cycle', 1, 'preview_shown', { elapsed_ms = 20 }),
                    record('complete-cycle', 1, 'accepted', { elapsed_ms = 25 }),
                    record('complete-cycle', 1, 'accepted', { elapsed_ms = 26 }),
                    vim.tbl_extend('force', record('forged-frontend', 1, 'cycle_started'), {
                        channel = 'completion',
                        frontend = 'forged',
                    }),
                    vim.tbl_extend('force', record('bad-timestamp', 1, 'cycle_started'), {
                        timestamp = -1,
                    }),
                    record('bad-reason', 1, 'stale', { elapsed_ms = 1, reason = 'raw provider error' }),
                    vim.tbl_extend('force', record('bad-provider', 1, 'cycle_started'), {
                        provider_id = 'private-provider-name',
                    }),
                })

                local report = report_module.analyze(path)
                local message = report_module.format(report)
                helpers.expect_equal(report.records.invalid, 4)
                helpers.expect_equal(report.records.duplicates, 1)
                helpers.expect_equal(report.records.conflicts, 1)
                helpers.expect_equal(report.cycles.observed, 2)
                helpers.expect_equal(report.cycles.missing_start, 1)
                helpers.expect_equal(report.visible.shown, 2)
                helpers.expect_equal(report.visible.accepted, 1)
                helpers.expect_falsy(report.gate.integrity_clean)
                helpers.expect_falsy(report.gate.ready_for_review)
                helpers.expect_truthy(message:find('missing-start=1', 1, true))
                helpers.expect_truthy(message:find('conflicts=1', 1, true))
                helpers.expect_falsy(message:find('raw provider error', 1, true))
                helpers.expect_falsy(message:find('private-provider-name', 1, true))
            end, debug.traceback)

            package.loaded['minuet.metrics_report'] = nil
            vim.fn.delete(path)
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics report aggregates allowlisted filters and accepted reverts',
        run = function()
            helpers.ensure_runtime()
            package.loaded['minuet.metrics_report'] = nil
            local report_module = require 'minuet.metrics_report'
            local path = vim.fn.tempname() .. '.jsonl'

            local ok, err = xpcall(function()
                write_records(path, {
                    record('quality-events', 1, 'cycle_started'),
                    record('quality-events', 1, 'with_result'),
                    record('quality-events', 1, 'filtered', { elapsed_ms = 10, reason = 'no_op' }),
                    record('quality-events', 2, 'cycle_started'),
                    record('quality-events', 2, 'with_result'),
                    record('quality-events', 2, 'filtered', { elapsed_ms = 11, reason = 'whitespace_only' }),
                    record('quality-events', 3, 'cycle_started'),
                    record('quality-events', 3, 'with_result'),
                    record('quality-events', 3, 'preview_shown', { elapsed_ms = 100 }),
                    record('quality-events', 3, 'accepted', { elapsed_ms = 120 }),
                    record('quality-events', 3, 'reverted', { elapsed_ms = 140 }),
                    record('quality-events', 4, 'cycle_started'),
                    record('quality-events', 4, 'with_result'),
                    record('quality-events', 4, 'preview_shown', { elapsed_ms = 200 }),
                    record('quality-events', 4, 'dismissed', { elapsed_ms = 220 }),
                })

                local report = report_module.analyze(path)
                helpers.expect_equal(report.cycles.filtered, 2)
                helpers.expect_equal(report.cycles.reverted, 1)
                helpers.expect_equal(report.filters.total, 2)
                helpers.expect_equal(report.filters.no_op, 1)
                helpers.expect_equal(report.filters.whitespace_only, 1)
                helpers.expect_equal(report.filters.no_op_rate, 0.5)
                helpers.expect_equal(report.visible.accepted, 1)
                helpers.expect_equal(report.visible.reverted, 1)
                helpers.expect_equal(report.visible.undo_rate, 1)
                helpers.expect_equal(report.visible.dismiss_rate, 0.5)
            end, debug.traceback)

            package.loaded['minuet.metrics_report'] = nil
            vim.fn.delete(path)
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics report calculates the synthetic 500-visible release review boundary',
        run = function()
            helpers.ensure_runtime()
            package.loaded['minuet.metrics_report'] = nil
            local report_module = require 'minuet.metrics_report'
            local path = vim.fn.tempname() .. '.jsonl'

            local ok, err = xpcall(function()
                local records = {}
                for cycle_id = 1, 500 do
                    records[#records + 1] = record('synthetic-release-math', cycle_id, 'cycle_started')
                    records[#records + 1] = record('synthetic-release-math', cycle_id, 'with_result')
                    records[#records + 1] = record('synthetic-release-math', cycle_id, 'preview_shown', {
                        elapsed_ms = 1000,
                    })
                    if cycle_id <= 125 then
                        records[#records + 1] = record('synthetic-release-math', cycle_id, 'accepted', {
                            elapsed_ms = 1100,
                        })
                        if cycle_id <= 12 then
                            records[#records + 1] = record('synthetic-release-math', cycle_id, 'reverted', {
                                elapsed_ms = 1200,
                            })
                        end
                    else
                        records[#records + 1] = record('synthetic-release-math', cycle_id, 'dismissed', {
                            elapsed_ms = 1100,
                        })
                    end
                end
                write_records(path, records)

                local report = report_module.analyze(path)
                local message = report_module.format(report)
                helpers.expect_equal(report.visible.shown, 500)
                helpers.expect_equal(report.visible.accepted, 125)
                helpers.expect_equal(report.visible.reverted, 12)
                helpers.expect_equal(report.visible.acceptance_rate, 0.25)
                helpers.expect_equal(report.visible.undo_rate, 12 / 125)
                helpers.expect_equal(report.release_gate.remaining_visible, 0)
                helpers.expect_truthy(report.release_gate.cohort_met)
                helpers.expect_truthy(report.release_gate.latency_met)
                helpers.expect_truthy(report.release_gate.acceptance_met)
                helpers.expect_truthy(report.release_gate.undo_met)
                helpers.expect_truthy(report.release_gate.parse_met)
                helpers.expect_truthy(report.release_gate.ready_for_release_review)
                helpers.expect_truthy(message:find('provenance, FIM latency, and safety review', 1, true))
            end, debug.traceback)

            package.loaded['minuet.metrics_report'] = nil
            vim.fn.delete(path)
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'metrics report compares separate baseline and variant cohorts',
        run = function()
            helpers.ensure_runtime()
            package.loaded['minuet.metrics_report'] = nil
            local report_module = require 'minuet.metrics_report'
            local directory = vim.fn.tempname()
            vim.fn.mkdir(directory, 'p')
            local baseline_path = directory .. '/baseline.jsonl'
            local variant_path = directory .. '/variant.jsonl'

            local ok, err = xpcall(function()
                local function cohort(session_id, preview_ms, accepted)
                    local records = {}
                    for cycle_id = 1, 4 do
                        records[#records + 1] = record(session_id, cycle_id, 'cycle_started')
                        records[#records + 1] = record(session_id, cycle_id, 'with_result')
                        records[#records + 1] = record(session_id, cycle_id, 'preview_shown', {
                            elapsed_ms = preview_ms,
                        })
                        local terminal = cycle_id <= accepted and 'accepted' or 'dismissed'
                        records[#records + 1] = record(session_id, cycle_id, terminal, {
                            elapsed_ms = preview_ms + 10,
                        })
                    end
                    return records
                end

                write_records(baseline_path, cohort('baseline-session', 1000, 1))
                write_records(variant_path, cohort('variant-session', 500, 2))

                local comparison = report_module.compare(baseline_path, variant_path)
                helpers.expect_equal(comparison.baseline.files.matched, 1)
                helpers.expect_equal(comparison.variant.files.matched, 1)
                helpers.expect_equal(comparison.delta.visible, 0)
                helpers.expect_equal(comparison.delta.acceptance_rate, 0.25)
                helpers.expect_equal(comparison.delta.dismiss_rate, -0.25)
                helpers.expect_equal(comparison.delta.undo_rate, 0)
                helpers.expect_equal(comparison.delta.preview_p50_ms, -500)
                helpers.expect_equal(comparison.delta.preview_p95_ms, -500)
            end, debug.traceback)

            package.loaded['minuet.metrics_report'] = nil
            vim.fn.delete(directory, 'rf')
            if not ok then
                error(err)
            end
        end,
    },
}
