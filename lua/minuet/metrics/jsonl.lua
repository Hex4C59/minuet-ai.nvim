local uv = vim.uv or vim.loop

local M = {}

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

local PROVIDERS = {
    openai = true,
    openai_compatible = true,
    openai_fim_compatible = true,
    codestral = true,
    gemini = true,
    claude = true,
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

---@param context table
---@return table
function M.new(context)
    local state = {
        log = nil,
    }

    local flush_logger
    local arm_logger_timer

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

    ---@param log table?
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
            context.safe_notify(message, vim.log.levels.WARN)
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

    ---@param log table
    local function write_logger_batch(log)
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
    flush_logger = write_logger_batch

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

        local aggregate = context.get_aggregate()
        local sanitized = {
            schema_version = 1,
            session_id = aggregate.session_id,
            event = record.event,
            timestamp = context.is_integer(record.timestamp) and record.timestamp or os.time(),
        }

        if CHANNELS[record.channel] then
            sanitized.channel = record.channel
        end
        if FRONTENDS[record.frontend] then
            sanitized.frontend = record.frontend
        end
        if PROVIDERS[record.provider_id] then
            sanitized.provider_id = record.provider_id
        elseif record.provider_id ~= nil then
            sanitized.provider_id = 'custom'
        end

        for _, key in ipairs { 'cycle_id', 'request_id', 'n_requests', 'request_idx' } do
            if context.is_integer(record[key]) and record[key] >= 0 then
                sanitized[key] = record[key]
            end
        end

        if STATUSES[record.status] then
            sanitized.status = record.status
        end
        sanitized.reason = context.sanitize_reason(record.reason)

        for _, key in ipairs { 'duration_ms', 'elapsed_ms' } do
            local value = record[key]
            if type(value) == 'number' and value == value and value >= 0 and value ~= math.huge then
                sanitized[key] = value
            end
        end

        return sanitized
    end

    local controller = {}

    ---@param config table
    function controller.setup(config)
        controller.cleanup()

        local path = config.path
        local default_path = path == nil
        local directory
        if default_path then
            directory = vim.fs.joinpath(vim.fn.stdpath 'state', 'minuet')
            path = vim.fs.joinpath(directory, 'metrics-' .. context.get_aggregate().session_id .. '.jsonl')
        else
            directory = vim.fn.fnamemodify(path, ':h')
            if directory == '' then
                directory = '.'
            end
        end

        local log = {
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
        state.log = log

        local stat_ok, stat = pcall(uv.fs_stat, directory)
        if not stat_ok or not stat then
            local mkdir_ok = pcall(vim.fn.mkdir, directory, 'p', 448)
            local verify_ok, verified = pcall(uv.fs_stat, directory)
            if not mkdir_ok or not verify_ok or not verified then
                fail_logger(log, 'Minuet metrics JSONL logger failed and was disabled.')
                return
            end
            pcall(uv.fs_chmod, directory, 448)
        elseif default_path then
            pcall(uv.fs_chmod, directory, 448)
        end
    end

    function controller.cleanup()
        cleanup_logger(state.log)
        state.log = nil
    end

    ---@param record table
    function controller.enqueue(record)
        local config = context.get_config()
        local log = state.log
        if not config.enabled or not log or not log.active then
            return
        end

        local sanitized = sanitize_log_record(record)
        if not sanitized then
            return
        end

        if #log.queue >= log.max_queue then
            local aggregate = context.get_aggregate()
            aggregate.dropped_log_records = aggregate.dropped_log_records + 1
            if not log.queue_notified then
                log.queue_notified = true
                context.safe_notify(
                    'Minuet metrics JSONL queue is full; records are being dropped.',
                    vim.log.levels.WARN
                )
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

    ---@param callback? fun()
    ---@return boolean
    function controller.flush(callback)
        local log = state.log
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

    return controller
end

return M
