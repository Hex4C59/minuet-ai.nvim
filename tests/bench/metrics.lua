local helpers = require 'tests.helpers'

helpers.ensure_runtime()
helpers.setup_root_config {
    metrics = {
        enabled = true,
        max_tracked_cycles = 128,
        max_latency_samples = 64,
        jsonl = {
            enabled = false,
        },
    },
}

local metrics = helpers.reload 'minuet.metrics'
metrics._reset()

local uv = vim.uv or vim.loop
local original = {
    fs_open = uv.fs_open,
    fs_stat = uv.fs_stat,
    fs_write = uv.fs_write,
    fs_mkdir = uv.fs_mkdir,
    fs_unlink = uv.fs_unlink,
    new_timer = uv.new_timer,
    json_encode = vim.json.encode,
    inspect = vim.inspect,
    nvim_buf_get_lines = vim.api.nvim_buf_get_lines,
}
local calls = {
    filesystem = 0,
    timer = 0,
    json_encode = 0,
    inspect = 0,
    buffer_read = 0,
}

local function filesystem_wrapper(fn)
    return function(...)
        calls.filesystem = calls.filesystem + 1
        return fn(...)
    end
end

uv.fs_open = filesystem_wrapper(original.fs_open)
uv.fs_stat = filesystem_wrapper(original.fs_stat)
uv.fs_write = filesystem_wrapper(original.fs_write)
uv.fs_mkdir = filesystem_wrapper(original.fs_mkdir)
uv.fs_unlink = filesystem_wrapper(original.fs_unlink)
uv.new_timer = function(...)
    calls.timer = calls.timer + 1
    return original.new_timer(...)
end
vim.json.encode = function(...)
    calls.json_encode = calls.json_encode + 1
    return original.json_encode(...)
end
vim.inspect = function(...)
    calls.inspect = calls.inspect + 1
    return original.inspect(...)
end
vim.api.nvim_buf_get_lines = function(...)
    calls.buffer_read = calls.buffer_read + 1
    return original.nvim_buf_get_lines(...)
end

local first_cycle
local first_request
local iterations = 10000
local total_updates = iterations * 7
local elapsed_ms
local heap_growth_kb

local ok, err = xpcall(function()
    metrics.setup {
        enabled = true,
        max_tracked_cycles = 128,
        max_latency_samples = 64,
        jsonl = {
            enabled = false,
        },
    }

    local function record_cycle()
        local cycle_id = metrics.begin_cycle {
            channel = 'completion',
            frontend = 'virtualtext',
            provider_id = 'openai_fim_compatible',
            n_requests = 1,
        }
        metrics.configure_cycle(cycle_id, {
            channel = 'completion',
            frontend = 'virtualtext',
            provider_id = 'openai_fim_compatible',
            n_requests = 1,
        })
        local request_id = metrics.request_attempted(cycle_id, 1)
        metrics.request_started(request_id)
        metrics.request_finished(request_id, { status = 'success' })
        metrics.cycle_has_result(cycle_id)
        metrics.suggestion_event(cycle_id, 'preview_shown')
        return cycle_id, request_id
    end

    for _ = 1, 512 do
        first_cycle, first_request = record_cycle()
    end
    collectgarbage 'collect'
    local heap_before = collectgarbage 'count'

    local started_ns = uv.hrtime()
    for _ = 1, iterations do
        record_cycle()
    end
    elapsed_ms = (uv.hrtime() - started_ns) / 1000000

    collectgarbage 'collect'
    heap_growth_kb = collectgarbage 'count' - heap_before
    assert(
        heap_growth_kb < 512,
        ('metrics retained %.2f KB after its bounded windows were full'):format(heap_growth_kb)
    )

    metrics.request_finished(first_request, { status = 'success' })
    metrics.suggestion_event(first_cycle, 'stale', 'superseded')
end, debug.traceback)

uv.fs_open = original.fs_open
uv.fs_stat = original.fs_stat
uv.fs_write = original.fs_write
uv.fs_mkdir = original.fs_mkdir
uv.fs_unlink = original.fs_unlink
uv.new_timer = original.new_timer
vim.json.encode = original.json_encode
vim.inspect = original.inspect
vim.api.nvim_buf_get_lines = original.nvim_buf_get_lines

if not ok then
    metrics._reset()
    error(err)
end

assert(calls.filesystem == 0, 'JSONL-disabled metrics performed filesystem I/O')
assert(calls.timer == 0, 'JSONL-disabled metrics allocated a timer')
assert(calls.json_encode == 0, 'JSONL-disabled metrics encoded a log record')
assert(calls.inspect == 0, 'metrics stringified an arbitrary value')
assert(calls.buffer_read == 0, 'metrics read Buffer contents')

local snapshot = metrics.get()
local latency = snapshot.channels.completion.latency_ms.request
assert(latency.samples == iterations + 512)
assert(latency.retained == 64)
assert(snapshot.channels.completion.latency_ms.first_preview.retained == 64)
assert(snapshot.dropped_late_events == 2)

local log_directory = vim.fn.tempname()
local log_path = log_directory .. '/metrics.jsonl'
metrics.setup {
    enabled = true,
    max_tracked_cycles = 128,
    max_latency_samples = 64,
    jsonl = {
        enabled = true,
        path = log_path,
        flush_interval = 60000,
        max_queue = 8,
        max_file_size = 1024 * 1024,
    },
}

local queue_started_ns = uv.hrtime()
for _ = 1, 32 do
    metrics.begin_cycle {
        channel = 'completion',
        frontend = 'virtualtext',
        provider_id = 'openai_fim_compatible',
    }
end
local queue_elapsed_ms = (uv.hrtime() - queue_started_ns) / 1000000
local dropped_log_records = metrics.get().dropped_log_records
assert(dropped_log_records >= 24)

local flushed = false
metrics._flush(function()
    flushed = true
end)
assert(
    vim.wait(2000, function()
        return flushed
    end, 10),
    'metrics benchmark JSONL flush timed out'
)
assert(#vim.fn.readfile(log_path) == 8)

print '\nMetrics hot path'
print(
    string.format(
        '%d cycles, %d updates: %.2f ms total, %.2f us/cycle, %.2f us/update',
        iterations,
        total_updates,
        elapsed_ms,
        elapsed_ms * 1000 / iterations,
        elapsed_ms * 1000 / total_updates
    )
)
print(string.format('bounded state: 128 cycles, 64/%d request latency samples retained', latency.samples))
print(string.format('live Lua heap growth after saturation: %.2f KB', heap_growth_kb))
print 'JSONL disabled: 0 filesystem calls, 0 timers, 0 encodes, 0 Buffer reads'
print(
    string.format(
        'JSONL queue: 8 records retained, %d dropped; 32 enqueue attempts in %.2f ms',
        dropped_log_records,
        queue_elapsed_ms
    )
)

metrics._reset()
vim.fn.delete(log_directory, 'rf')
