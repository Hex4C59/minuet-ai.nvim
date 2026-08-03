local api = vim.api
local helpers = require 'tests.helpers'
local uv = vim.uv or vim.loop

helpers.ensure_runtime()

local function benchmark_controller()
    helpers.setup_root_config()
    local controller = helpers.reload 'minuet.suggestion'
    local ops = {
        cancel = function() end,
        can_accept = function()
            return true
        end,
        accept = function() end,
        dismiss = function() end,
        is_visible = function()
            return true
        end,
    }

    for _ = 1, 256 do
        local lease = controller.begin {
            source = 'duet',
            intent = 'manual',
            bufnr = 1,
            changedtick = 1,
        }
        controller.attach(lease, ops)
        controller.mark_visible(lease)
        controller.finish(lease, 'accepted')
    end

    collectgarbage 'collect'
    local heap_before = collectgarbage 'count'
    local iterations = 10000
    local started_ns = uv.hrtime()
    for index = 1, iterations do
        local lease = controller.begin {
            source = index % 2 == 0 and 'fim' or 'duet',
            intent = 'manual',
            bufnr = 1,
            changedtick = index,
        }
        controller.attach(lease, ops)
        controller.mark_visible(lease)
        if index % 2 == 0 then
            controller.finish(lease, 'accepted')
        else
            controller.invalidate(lease, 'buffer_changed')
        end
    end
    local elapsed_ms = (uv.hrtime() - started_ns) / 1e6
    collectgarbage 'collect'
    local heap_growth_kb = collectgarbage 'count' - heap_before

    assert(controller.current() == nil, 'controller retained an owner after terminal transitions')
    assert(heap_growth_kb < 256, ('controller retained %.2f KB of historical state'):format(heap_growth_kb))
    print ''
    print 'Suggestion controller'
    print(
        string.format(
            '%d begin/visible/terminal cycles: %.2f ms total, %.2f us/cycle',
            iterations,
            elapsed_ms,
            elapsed_ms * 1000 / iterations
        )
    )
    print(string.format('bounded live state: 0 owners, %.2f KB heap growth after saturation', heap_growth_kb))
end

local function benchmark_scheduler_disabled()
    helpers.setup_root_config {
        duet = {
            auto_trigger = {
                enabled = false,
            },
        },
    }
    local recorder_setups = 0
    package.loaded['minuet.duet.edits'] = {
        ensure_setup = function()
            recorder_setups = recorder_setups + 1
        end,
    }

    local original = {
        fs_open = uv.fs_open,
        fs_stat = uv.fs_stat,
        fs_write = uv.fs_write,
        nvim_buf_get_lines = api.nvim_buf_get_lines,
        system = vim.system,
    }
    local calls = {
        filesystem = 0,
        buffer_read = 0,
        request = 0,
    }
    local function wrap_fs(fn)
        return function(...)
            calls.filesystem = calls.filesystem + 1
            return fn(...)
        end
    end
    uv.fs_open = wrap_fs(original.fs_open)
    uv.fs_stat = wrap_fs(original.fs_stat)
    uv.fs_write = wrap_fs(original.fs_write)
    api.nvim_buf_get_lines = function(...)
        calls.buffer_read = calls.buffer_read + 1
        return original.nvim_buf_get_lines(...)
    end
    vim.system = function(...)
        calls.request = calls.request + 1
        return original.system(...)
    end

    local scheduler = helpers.reload 'minuet.duet.scheduler'
    scheduler.setup(function()
        calls.request = calls.request + 1
        return true
    end)
    api.nvim_exec_autocmds('TextChangedI', { buffer = 0 })

    uv.fs_open = original.fs_open
    uv.fs_stat = original.fs_stat
    uv.fs_write = original.fs_write
    api.nvim_buf_get_lines = original.nvim_buf_get_lines
    vim.system = original.system

    assert(recorder_setups == 0, 'disabled scheduler started the recent-edits recorder')
    assert(scheduler._inspect().timer_count == 0, 'disabled scheduler retained a timer')
    assert(calls.filesystem == 0, 'disabled scheduler performed filesystem I/O')
    assert(calls.buffer_read == 0, 'disabled scheduler read Buffer text')
    assert(calls.request == 0, 'disabled scheduler started a request')
    scheduler.reset()
    print 'auto trigger disabled: 0 timers, 0 filesystem calls, 0 Buffer reads, 0 requests'
end

local function benchmark_scheduler_hot_path()
    helpers.setup_root_config {
        duet = {
            auto_trigger = {
                enabled = true,
                debounce = 60000,
                throttle = 0,
                max_buffer_size = 1000000,
                enable_predicates = {},
            },
        },
    }
    package.loaded['minuet.duet.edits'] = { ensure_setup = function() end }
    local scheduler = helpers.reload 'minuet.duet.scheduler'
    local requests = 0
    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(bufnr)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'benchmark' })
    scheduler.setup(function()
        requests = requests + 1
        return true
    end)

    local original_get_lines = api.nvim_buf_get_lines
    local original_system = vim.system
    local buffer_reads = 0
    local system_calls = 0
    api.nvim_buf_get_lines = function(...)
        buffer_reads = buffer_reads + 1
        return original_get_lines(...)
    end
    vim.system = function(...)
        system_calls = system_calls + 1
        return original_system(...)
    end

    local iterations = 10000
    local started_ns = uv.hrtime()
    for _ = 1, iterations do
        api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
    end
    local elapsed_ms = (uv.hrtime() - started_ns) / 1e6
    api.nvim_buf_get_lines = original_get_lines
    vim.system = original_system

    assert(requests == 0, 'scheduler requested during the debounce window')
    assert(scheduler._inspect().timer_count == 1, 'scheduler did not retain exactly one debounce timer')
    assert(buffer_reads == 0, 'TextChangedI synchronous path read Buffer text')
    assert(system_calls == 0, 'TextChangedI synchronous path started a process')
    scheduler.reset()
    api.nvim_buf_delete(bufnr, { force = true })

    print(
        string.format(
            'scheduler %d TextChangedI callbacks: %.2f ms total, %.2f us/event; 1 active timer, 0 requests',
            iterations,
            elapsed_ms,
            elapsed_ms * 1000 / iterations
        )
    )
end

local function benchmark_scheduler_debounce()
    helpers.setup_root_config {
        duet = {
            auto_trigger = {
                enabled = true,
                debounce = 20,
                throttle = 0,
                max_buffer_size = 1000000,
                enable_predicates = {},
            },
        },
    }
    package.loaded['minuet.duet.edits'] = { ensure_setup = function() end }
    local scheduler = helpers.reload 'minuet.duet.scheduler'
    local requests = 0
    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(bufnr)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'benchmark' })
    scheduler.setup(function()
        requests = requests + 1
        scheduler.note_request_started()
        return true
    end)

    for _ = 1, 60 do
        api.nvim_exec_autocmds('TextChangedI', { buffer = bufnr })
    end
    assert(requests == 0, 'simulated continuous input requested before debounce')
    assert(
        vim.wait(500, function()
            return requests == 1
        end, 5),
        'scheduler debounce benchmark did not produce one request'
    )
    vim.wait(40)
    assert(requests == 1, 'one edit generation produced more than one request')
    assert(scheduler._inspect().timer_count == 0, 'scheduler retained an idle timer')

    scheduler.reset()
    api.nvim_buf_delete(bufnr, { force = true })
    print 'simulated continuous input: 0 requests during debounce, 1 request after idle'
end

---@param changed_lines integer
---@return number
local function benchmark_filter_preview(changed_lines)
    helpers.setup_root_config {
        duet = {
            max_edit_lines = 40,
            max_edit_chars = 12000,
        },
    }
    local controller = helpers.reload 'minuet.suggestion'
    local apply = helpers.reload 'minuet.duet.apply'
    local preview = helpers.reload 'minuet.duet.preview'
    local original_lines = {}
    local proposed_lines = {}
    for index = 1, changed_lines do
        original_lines[index] = ('local value_%d = %d'):format(index, index)
        proposed_lines[index] = ('local changed_%d = %d'):format(index, index + 1)
    end

    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(bufnr)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, original_lines)
    local lease = controller.begin {
        source = 'duet',
        intent = 'manual',
        bufnr = bufnr,
        changedtick = api.nvim_buf_get_changedtick(bufnr),
    }
    local state = {}
    local iterations = 200
    local started_ns = uv.hrtime()
    for _ = 1, iterations do
        local edit = apply.prepare({
            bufnr = bufnr,
            changedtick = api.nvim_buf_get_changedtick(bufnr),
            range = { start_row = 0, end_row = changed_lines },
            original_lines = original_lines,
            proposed_lines = proposed_lines,
            cursor = { row_offset = changed_lines - 1, col = #proposed_lines[changed_lines] },
        }, lease)
        assert(edit and edit.changed_lines == changed_lines)
        preview.render(bufnr, state, edit)
        assert(preview.is_visible(bufnr, state))
        preview.clear(bufnr, state)
    end
    local elapsed_ms = (uv.hrtime() - started_ns) / 1e6

    controller.release(lease)
    api.nvim_buf_delete(bufnr, { force = true })
    return elapsed_ms / iterations
end

local function benchmark_candidates()
    helpers.setup_root_config {
        duet = {
            scope = 'buffer',
            candidates = {
                cursor = true,
                recent_edits = true,
                diagnostics = true,
                max_candidates = 8,
            },
            recent_edits = {
                enabled = false,
            },
        },
    }
    local candidates = helpers.reload 'minuet.duet.candidates'
    local lines = {}
    for index = 1, 10000 do
        lines[index] = ('local value_%d = %d'):format(index, index)
    end
    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(bufnr)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    api.nvim_win_set_cursor(0, { 5000, 0 })

    local events = {}
    for index = 1, 100 do
        local row = (index * 97) % 10000 + 1
        events[index] = {
            bufnr = bufnr,
            diff = ('@@ -%d,1 +%d,1 @@\n-old\n+new'):format(row, row),
        }
    end
    local diagnostics = {}
    for index = 1, 1000 do
        diagnostics[index] = {
            lnum = (index * 37) % 10000,
            col = 0,
            severity = (index % 4) + 1,
        }
    end
    local options = {
        cursor = { row = 4999, col = 0 },
        events = events,
        diagnostics = diagnostics,
        max_candidates = 8,
    }

    for _ = 1, 20 do
        candidates.collect(bufnr, options)
    end
    local samples = {}
    for index = 1, 1000 do
        local started_ns = uv.hrtime()
        local result = candidates.collect(bufnr, options)
        samples[index] = (uv.hrtime() - started_ns) / 1e6
        assert(#result == 8, 'candidate discovery did not respect the result limit')
    end
    table.sort(samples)

    local same_row_diagnostics = {}
    for index = 1, 10000 do
        same_row_diagnostics[index] = {
            lnum = 4999,
            col = index % 20,
            severity = (index % 4) + 1,
        }
    end
    collectgarbage 'collect'
    local heap_before = collectgarbage 'count'
    local deduplicated = candidates.collect(bufnr, {
        cursor = { row = 4999, col = 0 },
        events = {},
        diagnostics = same_row_diagnostics,
        max_candidates = 64,
    })
    collectgarbage 'collect'
    local heap_growth_kb = collectgarbage 'count' - heap_before
    assert(#deduplicated == 1, 'same-row diagnostics were not deduplicated')

    print ''
    print 'Candidate discovery'
    print(
        string.format(
            '10k lines + 100 recent hunks + 1k diagnostics, 1000 collects: P50 %.3f ms, P95 %.3f ms, max %.3f ms',
            samples[500],
            samples[950],
            samples[1000]
        )
    )
    print(
        string.format(
            '10k same-row diagnostics: %d candidate, %.2f KB heap growth after collection',
            #deduplicated,
            heap_growth_kb
        )
    )
    api.nvim_buf_delete(bufnr, { force = true })
end

local function benchmark_remote_preview()
    helpers.setup_root_config {
        duet = {
            preview = {
                cursor = '|',
                jump_text = 'Next edit: line %d',
                jump_sign = '>>',
            },
        },
    }
    local controller = helpers.reload 'minuet.suggestion'
    local apply = helpers.reload 'minuet.duet.apply'
    local preview = helpers.reload 'minuet.duet.preview'
    local lines = {}
    for index = 1, 1000 do
        lines[index] = ('local value_%d = %d'):format(index, index)
    end
    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(bufnr)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    local lease = controller.begin {
        source = 'duet',
        intent = 'manual',
        bufnr = bufnr,
        changedtick = api.nvim_buf_get_changedtick(bufnr),
    }
    local edit = apply.prepare({
        bufnr = bufnr,
        changedtick = api.nvim_buf_get_changedtick(bufnr),
        range = { start_row = 499, end_row = 500 },
        original_lines = { lines[500] },
        proposed_lines = { 'local value_500 = 501' },
        cursor = { row_offset = 0, col = 21 },
    }, lease)
    assert(edit, 'remote preview benchmark edit was filtered')

    local state = {}
    local iterations = 1000
    local jump_started_ns = uv.hrtime()
    for _ = 1, iterations do
        preview.render_jump(bufnr, state, 0, 499)
        preview.clear(bufnr, state)
    end
    local jump_ms = (uv.hrtime() - jump_started_ns) / 1e6

    local focus_started_ns = uv.hrtime()
    for _ = 1, iterations do
        api.nvim_win_set_cursor(0, { 500, 0 })
        preview.render(bufnr, state, edit)
        preview.clear(bufnr, state)
    end
    local focus_ms = (uv.hrtime() - focus_started_ns) / 1e6

    controller.release(lease)
    api.nvim_buf_delete(bufnr, { force = true })
    print(
        string.format(
            'remote preview: %.3f ms jump hint, %.3f ms focus+diff render average',
            jump_ms / iterations,
            focus_ms / iterations
        )
    )
end

local function benchmark_symbols_and_context()
    helpers.setup_root_config {
        duet = {
            recent_edits = { enabled = false },
            context = {
                max_chars = 48000,
                evidence_max_chars = 4800,
                related_files = { enabled = false },
            },
        },
    }
    local lines = {}
    local identifiers = {}
    for identifier = 1, 8 do
        identifiers[identifier] = 'changedSymbol' .. identifier
    end
    for row = 1, 10000 do
        lines[row] = ('local row_%d = %s'):format(row, identifiers[(row % #identifiers) + 1])
    end
    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(bufnr)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_buf_set_name(bufnr, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'semantic-benchmark.lua'))
    package.loaded['minuet.duet.edits'] = {
        get_events = function()
            return {}
        end,
        render = function()
            return ''
        end,
    }
    local symbols = helpers.reload 'minuet.duet.symbols'

    local samples = {}
    for iteration = 1, 200 do
        local started_ns = uv.hrtime()
        local matches = symbols._text_matches(bufnr, identifiers, 8, 64)
        samples[iteration] = (uv.hrtime() - started_ns) / 1e6
        assert(#matches == 64, 'semantic benchmark text match bound changed')
    end
    table.sort(samples)

    local semantic = {
        identifiers = identifiers,
        references = {},
        definitions = {},
    }
    for index = 1, 64 do
        semantic.references[index] = { row = index * 100, col = 0, name = identifiers[(index % 8) + 1] }
    end
    local context = helpers.reload 'minuet.duet.context'
    local context_iterations = 200
    local context_started_ns = uv.hrtime()
    for _ = 1, context_iterations do
        local built = context.build(bufnr, { bufnr = bufnr, row = 4999, col = 0, source = 'reference' }, semantic)
        assert(vim.fn.strchars(built.context_evidence) <= 4800)
    end
    local context_ms = (uv.hrtime() - context_started_ns) / 1e6 / context_iterations

    print ''
    print 'Semantic context'
    print(
        string.format(
            '10k lines x 8 identifiers, 200 bounded scans: P50 %.3f ms, P95 %.3f ms, max %.3f ms',
            samples[100],
            samples[190],
            samples[200]
        )
    )
    print(string.format('48k context budget + 64 references: %.3f ms/build average', context_ms))
    symbols.reset()
    api.nvim_buf_delete(bufnr, { force = true })
end

local function benchmark_cross_buffers()
    helpers.setup_root_config {
        duet = {
            scope = 'workspace',
            candidates = {
                cursor = false,
                recent_edits = false,
                diagnostics = false,
                references = false,
                text = false,
                related_buffers = true,
                max_candidates = 64,
            },
            recent_edits = { enabled = false },
        },
    }
    local candidates = helpers.reload 'minuet.duet.candidates'
    local preview = helpers.reload 'minuet.duet.preview'
    local origin = api.nvim_create_buf(true, false)
    api.nvim_buf_set_name(origin, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-benchmark-origin.lua'))
    api.nvim_buf_set_lines(origin, 0, -1, false, { 'origin' })
    local targets = {}
    local related_references = {}
    for index = 1, 32 do
        local bufnr = api.nvim_create_buf(true, false)
        targets[index] = bufnr
        api.nvim_buf_set_name(
            bufnr,
            vim.fs.joinpath(vim.fn.getcwd(), 'tests', ('cross-benchmark-%02d.lua'):format(index))
        )
        api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'first', 'second' })
        related_references[#related_references + 1] = {
            bufnr = bufnr,
            row = 0,
            col = 0,
            path = 'ignored',
            name = 'ignored',
        }
        related_references[#related_references + 1] = {
            bufnr = bufnr,
            row = 1,
            col = 0,
            path = 'ignored',
            name = 'ignored',
        }
    end
    api.nvim_set_current_buf(origin)
    local options = { semantic = { related_references = related_references }, max_candidates = 64 }
    local samples = {}
    for iteration = 1, 200 do
        local started_ns = uv.hrtime()
        local result = candidates.collect(origin, options)
        samples[iteration] = (uv.hrtime() - started_ns) / 1e6
        assert(#result == 64, 'cross-buffer candidate bound changed')
    end
    table.sort(samples)

    local state = {}
    local render_started_ns = uv.hrtime()
    for _ = 1, 1000 do
        preview.render_cross_jump(origin, targets[1], state, 0, 1, 'tests/cross-benchmark-01.lua')
        preview.clear(origin, state)
    end
    local render_ms = (uv.hrtime() - render_started_ns) / 1e6

    require('minuet').config.duet.scope = 'buffer'
    local original_list_bufs = api.nvim_list_bufs
    local list_calls = 0
    api.nvim_list_bufs = function(...)
        list_calls = list_calls + 1
        return original_list_bufs(...)
    end
    candidates.collect(origin, options)
    api.nvim_list_bufs = original_list_bufs
    assert(list_calls == 0, 'disabled cross-buffer candidate path enumerated buffers')

    print ''
    print 'Cross-buffer candidates'
    print(
        string.format(
            '32 loaded buffers + 64 references, 200 collects: P50 %.3f ms, P95 %.3f ms, max %.3f ms',
            samples[100],
            samples[190],
            samples[200]
        )
    )
    print(string.format('1000 multi-buffer hint render/clear cycles: %.3f ms average', render_ms / 1000))
    print 'disabled cross-buffer path: 0 Buffer enumerations'

    for _, bufnr in ipairs(targets) do
        api.nvim_buf_delete(bufnr, { force = true })
    end
    api.nvim_buf_delete(origin, { force = true })
end

local function benchmark_quality_feedback()
    helpers.setup_root_config {
        duet = {
            quality = {
                undo_window = 10000,
                max_pending_undo = 64,
                repeat_suppression = {
                    enabled = true,
                    ttl = 30000,
                    max_entries = 128,
                },
            },
        },
    }
    local quality = helpers.reload 'minuet.duet.quality'
    local iterations = 10000
    local started_ns = uv.hrtime()
    for index = 1, iterations do
        assert(not quality.is_repeat {
            bufnr = 1,
            changedtick = index,
            range = { start_row = index % 100, end_row = index % 100 + 1 },
            proposed_lines = { ('local quality_%d = true'):format(index) },
        })
    end
    local fingerprint_ms = (uv.hrtime() - started_ns) / 1e6
    assert(quality._inspect().count == 128, 'repeat fingerprint cache exceeded its configured bound')

    local metrics = helpers.reload 'minuet.metrics'
    metrics._reset()
    metrics.setup { enabled = true }
    local feedback = helpers.reload 'minuet.duet.feedback'
    feedback.setup()
    local bufnr = api.nvim_create_buf(true, false)
    api.nvim_set_current_buf(bufnr)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'feedback benchmark' })
    local original_get_lines = api.nvim_buf_get_lines
    local buffer_reads = 0
    api.nvim_buf_get_lines = function(...)
        buffer_reads = buffer_reads + 1
        return original_get_lines(...)
    end
    started_ns = uv.hrtime()
    for _ = 1, iterations do
        api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
    end
    local feedback_ms = (uv.hrtime() - started_ns) / 1e6
    api.nvim_buf_get_lines = original_get_lines

    assert(feedback._inspect().count == 0, 'idle feedback observer retained state')
    assert(buffer_reads == 0, 'idle feedback observer read Buffer text')
    feedback.reset()
    quality.reset()
    metrics._reset()
    api.nvim_buf_delete(bufnr, { force = true })

    print ''
    print 'Quality controls'
    print(
        string.format(
            '%d unique repeat fingerprints: %.2f ms total, %.2f us/check; 128 entries retained',
            iterations,
            fingerprint_ms,
            fingerprint_ms * 1000 / iterations
        )
    )
    print(
        string.format(
            '%d idle feedback callbacks: %.2f ms total, %.2f us/event; 0 Buffer reads',
            iterations,
            feedback_ms,
            feedback_ms * 1000 / iterations
        )
    )
end

benchmark_controller()
print ''
print 'Scheduler'
benchmark_scheduler_disabled()
benchmark_scheduler_hot_path()
benchmark_scheduler_debounce()

print ''
print 'Filter and preview'
for _, changed_lines in ipairs { 1, 10, 40 } do
    local average_ms = benchmark_filter_preview(changed_lines)
    print(string.format('%2d changed lines: %.3f ms/filter+preview', changed_lines, average_ms))
end

benchmark_candidates()
benchmark_remote_preview()
benchmark_symbols_and_context()
benchmark_cross_buffers()
benchmark_quality_feedback()
