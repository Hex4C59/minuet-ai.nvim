local helpers = require 'tests.helpers'

helpers.ensure_runtime()

local api = vim.api
local uv = vim.uv or vim.loop
local api_key = vim.env.DEEPSEEK_API_KEY
local sentinel = 'MINUET_DEEPSEEK_SMOKE_PRIVATE_SOURCE_SENTINEL_6f412d'
local fake_key = 'MINUET_DEEPSEEK_SMOKE_FAKE_KEY_84b7ce'
local temp_dir = vim.fn.tempname()
local log_path = vim.fs.joinpath(temp_dir, 'metrics.jsonl')
local buffer_path = vim.fs.joinpath(temp_dir, 'smoke.lua')
local bufnr
local metrics
local event_group
local original_mode = vim.fn.mode
local original_pumvisible = vim.fn.pumvisible
local original_notify = vim.notify

---@param condition any
---@param message string
local function check(condition, message)
    if not condition then
        error(message, 0)
    end
end

---@param predicate fun(): boolean
---@param timeout_ms integer
---@param message string
local function wait_until(predicate, timeout_ms, message)
    check(vim.wait(timeout_ms, predicate, 20), message)
end

---@param text string
---@param value string?
---@param message string
local function check_absent(text, value, message)
    if value and value ~= '' then
        check(not text:find(value, 1, true), message)
    end
end

---@param value any
---@param forbidden table<string, boolean>
local function check_forbidden_fields(value, forbidden)
    if type(value) ~= 'table' then
        return
    end
    for key, item in pairs(value) do
        if type(key) == 'string' then
            check(not forbidden[key:lower()], 'metrics output contained a forbidden field')
        end
        check_forbidden_fields(item, forbidden)
    end
end

---@param text string
---@param secret string?
---@return string
local function redact(text, secret)
    if not secret or secret == '' then
        return text
    end
    local pattern = secret:gsub('([^%w])', '%%%1')
    return text:gsub(pattern, '[REDACTED]')
end

---@param lines string[]
---@param cursor integer[]
local function set_source(lines, cursor)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    api.nvim_win_set_cursor(0, cursor)
    vim.wait(50)
end

---@param channel table
---@return string
local function outcome_summary(channel)
    local outcomes = {}
    for name, count in pairs(channel.requests.outcomes) do
        if count > 0 then
            outcomes[#outcomes + 1] = ('%s=%d'):format(name, count)
        end
    end
    table.sort(outcomes)
    return #outcomes > 0 and table.concat(outcomes, ', ') or 'no finished outcome'
end

---@param action table
---@param disposition 'accept'|'dismiss'
local function run_fim_cycle(action, disposition)
    local before = metrics.get().channels.completion
    action.next()

    wait_until(function()
        return metrics.get().channels.completion.requests.finished == before.requests.finished + 1
    end, 45000, 'FIM request did not finish within 45 seconds')

    local visible = vim.wait(3000, action.is_visible, 20)
    if not visible then
        local channel = metrics.get().channels.completion
        error('FIM request produced no preview (' .. outcome_summary(channel) .. ')', 0)
    end

    if disposition == 'accept' then
        action.accept()
        wait_until(function()
            return metrics.get().channels.completion.cycles.accepted == before.cycles.accepted + 1
        end, 3000, 'FIM accept lifecycle event was not recorded')
    else
        action.dismiss()
        check(
            metrics.get().channels.completion.cycles.dismissed == before.cycles.dismissed + 1,
            'FIM dismiss lifecycle event was not recorded'
        )
        check(not action.is_visible(), 'FIM preview remained visible after dismiss')
    end
end

---@param action table
---@param disposition 'apply'|'dismiss'
local function run_duet_preview_cycle(action, disposition)
    local before = metrics.get().channels.duet
    action.predict()

    wait_until(function()
        return metrics.get().channels.duet.requests.finished == before.requests.finished + 1
    end, 45000, 'Duet request did not finish within 45 seconds')

    local visible = vim.wait(3000, action.is_visible, 20)
    if not visible then
        local channel = metrics.get().channels.duet
        error('Duet request produced no preview (' .. outcome_summary(channel) .. ')', 0)
    end

    if disposition == 'apply' then
        action.apply()
        check(
            metrics.get().channels.duet.cycles.accepted == before.cycles.accepted + 1,
            'Duet apply lifecycle event was not recorded'
        )
    else
        action.dismiss()
        check(
            metrics.get().channels.duet.cycles.dismissed == before.cycles.dismissed + 1,
            'Duet dismiss lifecycle event was not recorded'
        )
    end
    check(not action.is_visible(), 'Duet preview remained visible after disposition')
end

---@param action table
---@return { requests: integer, previews: integer, accepted: integer, followup_visible: boolean }
local function run_auto_duet_continuous_cycle(action)
    local minuet = require 'minuet'
    minuet.config.duet.auto_trigger.enabled = true
    minuet.config.duet.auto_trigger.debounce = 100
    minuet.config.duet.auto_trigger.throttle = 0
    minuet.config.duet.auto_trigger.on_insert_leave = true
    minuet.config.duet.auto_trigger.after_accept = true
    require('minuet.duet').setup()

    local before = metrics.get().channels.duet
    set_source({
        '-- ' .. sentinel,
        '-- ' .. fake_key,
        'local function add(left, right)',
        '    -- Replace the placeholder with the sum.',
        '    return nil',
        'end',
    }, { 5, 14 })
    api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })

    wait_until(function()
        return metrics.get().channels.duet.requests.finished == before.requests.finished + 1
    end, 45000, 'automatic Duet request did not finish within 45 seconds')
    if not vim.wait(3000, action.is_visible, 20) then
        local channel = metrics.get().channels.duet
        error('automatic Duet request produced no preview (' .. outcome_summary(channel) .. ')', 0)
    end

    check(require('minuet.tab').accept(), 'unified Tab API did not handle the automatic Duet preview')
    wait_until(function()
        return metrics.get().channels.duet.cycles.accepted == before.cycles.accepted + 1
    end, 3000, 'automatic Duet accept lifecycle event was not recorded')

    wait_until(function()
        return metrics.get().channels.duet.cycles.started == before.cycles.started + 2
    end, 5000, 'accepting Duet did not schedule the follow-up prediction')
    wait_until(function()
        return metrics.get().channels.duet.requests.finished == before.requests.finished + 2
    end, 45000, 'follow-up automatic Duet request did not finish within 45 seconds')
    wait_until(function()
        local lease = require('minuet.suggestion').current()
        return lease == nil or lease.phase == 'visible'
    end, 3000, 'follow-up automatic Duet result did not reach a stable state')

    local followup_visible = action.is_visible()
    if followup_visible then
        action.dismiss()
    end
    require('minuet.duet.scheduler').reset()
    require('minuet.suggestion').reset()

    local after = metrics.get().channels.duet
    check(after.cycles.started == before.cycles.started + 2, 'automatic flow started an unexpected number of cycles')
    check(
        after.requests.finished == before.requests.finished + 2,
        'automatic flow finished an unexpected request count'
    )
    check(after.cycles.preview_shown >= before.cycles.preview_shown + 1, 'automatic flow showed no actionable preview')
    check(after.cycles.accepted == before.cycles.accepted + 1, 'automatic flow did not accept exactly one prediction')

    return {
        requests = after.requests.finished - before.requests.finished,
        previews = after.cycles.preview_shown - before.cycles.preview_shown,
        accepted = after.cycles.accepted - before.cycles.accepted,
        followup_visible = followup_visible,
    }
end

---@return table
local function run()
    check(type(api_key) == 'string' and api_key:find '%S', 'DEEPSEEK_API_KEY is required')
    check(vim.fn.mkdir(temp_dir, 'p') == 1, 'could not create the smoke-test temporary directory')

    local captured_events = {}
    event_group = api.nvim_create_augroup('MinuetDeepSeekSmokeEvents', { clear = true })
    for _, pattern in ipairs {
        'MinuetRequestStartedPre',
        'MinuetRequestStarted',
        'MinuetRequestFinished',
        'MinuetDuetRequestStartedPre',
        'MinuetDuetRequestStarted',
        'MinuetDuetRequestFinished',
        'MinuetSuggestionLifecycle',
    } do
        api.nvim_create_autocmd('User', {
            group = event_group,
            pattern = pattern,
            callback = function(args)
                captured_events[#captured_events + 1] = vim.deepcopy(args.data)
            end,
        })
    end

    vim.notify = function() end
    vim.fn.mode = function()
        return 'i'
    end
    vim.fn.pumvisible = function()
        return 0
    end

    bufnr = api.nvim_create_buf(false, false)
    api.nvim_set_current_buf(bufnr)
    api.nvim_buf_set_name(bufnr, buffer_path)
    vim.bo[bufnr].filetype = 'lua'

    require('minuet').setup {
        provider = 'openai_fim_compatible',
        n_completions = 1,
        request_timeout = 30,
        throttle = 0,
        debounce = 0,
        notify = false,
        virtualtext = {
            show_on_completion_menu = true,
        },
        metrics = {
            enabled = true,
            max_tracked_cycles = 64,
            max_latency_samples = 64,
            jsonl = {
                enabled = true,
                path = log_path,
                flush_interval = 25,
                max_queue = 256,
                max_file_size = 1024 * 1024,
            },
        },
        provider_options = {
            openai_fim_compatible = {
                model = 'deepseek-v4-flash',
                end_point = 'https://api.deepseek.com/beta/completions',
                api_key = 'DEEPSEEK_API_KEY',
                name = 'Deepseek',
                stream = true,
                optional = {
                    max_tokens = 64,
                    temperature = 0,
                },
            },
        },
        duet = {
            provider = 'openai_compatible',
            request_timeout = 30,
            editable_region = {
                lines_before = 2,
                lines_after = 1,
            },
            recent_edits = {
                enabled = false,
            },
            provider_options = {
                openai_compatible = {
                    model = 'deepseek-v4-flash',
                    end_point = 'https://api.deepseek.com/chat/completions',
                    api_key = 'DEEPSEEK_API_KEY',
                    name = 'Deepseek',
                    stream = true,
                    optional = {
                        max_tokens = 512,
                        temperature = 0,
                        thinking = { type = 'disabled' },
                    },
                },
            },
        },
    }

    metrics = require 'minuet.metrics'
    local virtualtext = require 'minuet.virtualtext'
    local duet = require 'minuet.duet'

    set_source({
        '-- ' .. sentinel,
        '-- ' .. fake_key,
        'local function add(left, right)',
        '    ',
        'end',
    }, { 4, 4 })
    run_fim_cycle(virtualtext.action, 'accept')

    set_source({
        '-- ' .. sentinel,
        '-- ' .. fake_key,
        'local function multiply(left, right)',
        '    ',
        'end',
    }, { 4, 4 })
    run_fim_cycle(virtualtext.action, 'dismiss')

    local duet_source = {
        '-- ' .. sentinel,
        '-- ' .. fake_key,
        'local function add(left, right)',
        '    -- Replace the placeholder with the sum.',
        '    return nil',
        'end',
    }

    set_source(duet_source, { 5, 14 })
    run_duet_preview_cycle(duet.action, 'dismiss')

    set_source(duet_source, { 5, 14 })
    run_duet_preview_cycle(duet.action, 'apply')

    set_source(duet_source, { 5, 14 })
    local before_stale = metrics.get().channels.duet
    duet.action.predict()
    api.nvim_buf_set_lines(bufnr, 4, 5, false, { '    return left' })
    api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    wait_until(function()
        local duet_metrics = metrics.get().channels.duet
        return duet_metrics.requests.finished == before_stale.requests.finished + 1
    end, 45000, 'invalidated Duet request did not finish within 45 seconds')
    vim.wait(100, function()
        local duet_metrics = metrics.get().channels.duet
        return duet_metrics.cycles.with_result > before_stale.cycles.with_result
            and duet_metrics.cycles.stale > before_stale.cycles.stale
    end, 20)

    local after_stale = metrics.get().channels.duet
    local result_delta = after_stale.cycles.with_result - before_stale.cycles.with_result
    local stale_delta = after_stale.cycles.stale - before_stale.cycles.stale
    local cancelled_delta = after_stale.requests.outcomes.cancelled - before_stale.requests.outcomes.cancelled
    local success_delta = after_stale.requests.outcomes.success - before_stale.requests.outcomes.success
    check(result_delta == 0 or result_delta == 1, 'invalidated Duet produced duplicate result lifecycle events')
    check(stale_delta == result_delta, 'invalidated Duet result and stale lifecycle counts diverged')
    check(
        success_delta + cancelled_delta == 1,
        'invalidated Duet request had an unexpected outcome (' .. outcome_summary(after_stale) .. ')'
    )
    if result_delta == 0 then
        check(cancelled_delta == 1, 'Duet without a non-empty late result was not classified as cancelled')
    end
    check(not duet.action.is_visible(), 'invalidated Duet response rendered a preview')
    local invalidation_outcome = success_delta == 1 and 'success' or 'cancelled'

    local snapshot = metrics.get()
    local completion = snapshot.channels.completion
    local duet_metrics = snapshot.channels.duet
    check(completion.cycles.started == 2, 'FIM cycle count did not match the two manual triggers')
    check(completion.requests.finished == 2, 'FIM request count did not match the two manual triggers')
    check(completion.requests.outcomes.success == 2, 'FIM requests did not both finish successfully')
    check(completion.cycles.preview_shown == 2, 'FIM did not show two previews')
    check(completion.cycles.accepted == 1, 'FIM accept count was not one')
    check(completion.cycles.dismissed == 1, 'FIM dismiss count was not one')
    check(duet_metrics.cycles.started == 3, 'Duet cycle count did not match the three manual triggers')
    check(duet_metrics.requests.finished == 3, 'Duet request count did not match the three manual triggers')
    check(duet_metrics.requests.outcomes.success >= 2, 'the two preview-producing Duet requests did not succeed')
    check(
        duet_metrics.requests.outcomes.success + duet_metrics.requests.outcomes.cancelled == 3,
        'manual Duet requests had an unexpected terminal outcome'
    )
    check(duet_metrics.cycles.preview_shown == 2, 'Duet did not show two actionable previews')
    check(duet_metrics.cycles.accepted == 1, 'Duet apply count was not one')
    check(duet_metrics.cycles.dismissed == 1, 'Duet dismiss count was not one')
    check(duet_metrics.cycles.stale == stale_delta, 'Duet invalidation lifecycle count was inconsistent')
    check(duet_metrics.cycles.parse_failed == 0, 'Duet marker parsing failed')

    local auto_duet = run_auto_duet_continuous_cycle(duet.action)
    snapshot = metrics.get()
    completion = snapshot.channels.completion
    duet_metrics = snapshot.channels.duet

    local flushed = false
    metrics._flush(function()
        flushed = true
    end)
    wait_until(function()
        return flushed
    end, 5000, 'metrics JSONL flush did not finish')

    local lines = vim.fn.readfile(log_path)
    check(#lines > 0, 'metrics JSONL did not contain any records')
    local raw_log = table.concat(lines, '\n')
    local event_json = vim.json.encode(captured_events)
    for _, output in ipairs { raw_log, event_json } do
        check_absent(output, api_key, 'metrics output contained the API key')
        check_absent(output, sentinel, 'metrics output contained source sentinel text')
        check_absent(output, fake_key, 'metrics output contained fake key text')
        check_absent(output, buffer_path, 'metrics output contained the temporary Buffer path')
    end

    local forbidden_fields = {
        api_key = true,
        body = true,
        buffer = true,
        bufnr = true,
        content = true,
        headers = true,
        path = true,
        prompt = true,
        request_body = true,
        response = true,
        source = true,
        text = true,
    }
    for _, line in ipairs(lines) do
        local decoded_ok, record = pcall(vim.json.decode, line)
        check(decoded_ok and type(record) == 'table', 'metrics JSONL contained an invalid record')
        check_forbidden_fields(record, forbidden_fields)
    end
    check_forbidden_fields(captured_events, forbidden_fields)

    local stat = uv.fs_stat(log_path)
    check(stat and type(stat.size) == 'number', 'metrics JSONL could not be inspected')
    local flushed_size = stat.size
    metrics.setup {
        enabled = true,
        jsonl = { enabled = false },
    }
    metrics.begin_cycle {
        channel = 'completion',
        frontend = 'virtualtext',
        provider_id = 'openai_fim_compatible',
    }
    vim.wait(100)
    local final_stat = uv.fs_stat(log_path)
    check(final_stat and final_stat.size == flushed_size, 'metrics JSONL changed after logging was disabled')

    return {
        completion = completion,
        duet = duet_metrics,
        auto_duet = auto_duet,
        invalidation = {
            outcome = invalidation_outcome,
            with_result = result_delta,
            stale = stale_delta,
        },
        jsonl_records = #lines,
        lifecycle_events = #captured_events,
    }
end

local result
local ok, err = xpcall(function()
    result = run()
end, debug.traceback)

pcall(function()
    require('minuet.backends.common').terminate_all_jobs()
end)
pcall(function()
    require('minuet.duet.backends.common').terminate_all_jobs()
end)
pcall(function()
    require('minuet.duet.scheduler').reset()
end)
pcall(function()
    require('minuet.suggestion').reset()
end)
vim.wait(100)
if metrics then
    pcall(metrics.setup, {
        enabled = false,
        jsonl = { enabled = false },
    })
end
if event_group then
    pcall(api.nvim_del_augroup_by_id, event_group)
end
if bufnr and api.nvim_buf_is_valid(bufnr) then
    pcall(api.nvim_buf_delete, bufnr, { force = true })
end
vim.fn.mode = original_mode
vim.fn.pumvisible = original_pumvisible
vim.notify = original_notify
vim.env.DEEPSEEK_API_KEY = nil
vim.fn.delete(temp_dir, 'rf')

if not ok then
    local message = redact(redact(tostring(err), api_key), sentinel)
    message = redact(message, fake_key)
    io.stderr:write('DeepSeek smoke FAIL\n' .. message .. '\n')
    vim.cmd 'cquit 1'
    return
end

local completion_latency = result.completion.latency_ms.request
local duet_latency = result.duet.latency_ms.request
io.stdout:write 'DeepSeek smoke PASS\n'
io.stdout:write(
    ('FIM: 2 requests, 2 previews, 1 accepted, 1 dismissed; P50 %.2f ms, P95 %.2f ms\n'):format(
        completion_latency.p50,
        completion_latency.p95
    )
)
io.stdout:write(
    ('Duet total: %d requests, %d previews, %d accepted, %d dismissed, %d stale; P50 %.2f ms, P95 %.2f ms\n'):format(
        result.duet.requests.finished,
        result.duet.cycles.preview_shown,
        result.duet.cycles.accepted,
        result.duet.cycles.dismissed,
        result.duet.cycles.stale,
        duet_latency.p50,
        duet_latency.p95
    )
)
io.stdout:write(
    ('Automatic Duet: %d requests, %d previews, %d accepted; follow-up preview visible=%s\n'):format(
        result.auto_duet.requests,
        result.auto_duet.previews,
        result.auto_duet.accepted,
        tostring(result.auto_duet.followup_visible)
    )
)
io.stdout:write(
    ('Duet invalidation: outcome=%s, non-empty result=%d, stale=%d, preview visible=false\n'):format(
        result.invalidation.outcome,
        result.invalidation.with_result,
        result.invalidation.stale
    )
)
io.stdout:write(
    ('Privacy: %d JSONL records and %d lifecycle payloads passed sentinel/key/path scans\n'):format(
        result.jsonl_records,
        result.lifecycle_events
    )
)
vim.cmd 'qa!'
