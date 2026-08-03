-- referenced from copilot.lua https://github.com/zbirenbaum/copilot.lua
local M = {}
local utils = require 'minuet.utils'
local metrics = require 'minuet.metrics'
local controller = require 'minuet.suggestion'
local api = vim.api

M.ns_id = api.nvim_create_namespace 'minuet.virtualtext'
M.augroup = api.nvim_create_augroup('MinuetVirtualText', { clear = true })

if vim.tbl_isempty(api.nvim_get_hl(0, { name = 'MinuetVirtualText' })) then
    api.nvim_set_hl(0, 'MinuetVirtualText', { link = 'Comment' })
end

local internal = {
    augroup = M.augroup,
    ns_id = M.ns_id,
    extmark_id = 1,

    timer = nil,
    throttle_timer = nil,
    context = {},
    is_on_throttle = false,
    current_request = nil,
}

local function should_auto_trigger()
    return vim.b.minuet_virtual_text_auto_trigger
end

local function completion_menu_visible()
    local has_cmp = pcall(require, 'cmp')
    local cmp_visible = false

    local has_blink = pcall(require, 'blink-cmp')
    local blink_visible = false

    if has_cmp then
        local ok, _cmp_visible = pcall(function()
            return require('cmp').core.view:visible()
        end)

        if ok then
            cmp_visible = _cmp_visible
        end
    end

    if has_blink then
        local ok, _blink_visible = pcall(function()
            return require('blink-cmp').is_visible()
        end)

        if ok then
            blink_visible = _blink_visible
        end
    end

    return vim.fn.pumvisible() == 1 or cmp_visible or blink_visible
end

---@param bufnr? integer
---@return minuet.VirtualtextSuggestionContext
local function get_ctx(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    if bufnr == 0 then
        bufnr = api.nvim_get_current_buf()
    end
    local ctx = internal.context[bufnr]
    if not ctx then
        ctx = {}
        internal.context[bufnr] = ctx
    end
    return ctx
end

---@param ctx? minuet.VirtualtextSuggestionContext
---@param bufnr? integer
---@return string[]?
local function get_last_typed_text(ctx, bufnr)
    ctx = ctx or get_ctx()
    bufnr = bufnr or api.nvim_get_current_buf()
    local last_typed = nil
    local last_pos = ctx.last_pos
    if not last_pos then
        return { '' }
    end

    local current_pos = api.nvim_win_get_cursor(0)

    -- Convert 1-based line to 0-based for nvim_buf_get_text
    local start_row = last_pos[1] - 1
    local start_col = last_pos[2]
    local end_row = current_pos[1] - 1
    local end_col = current_pos[2]

    if start_row < end_row or (start_row == end_row and start_col <= end_col) then
        last_typed = api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {})
    end

    return last_typed
end

---@class minuet.VirtualtextSuggestionContext
---@field suggestions? string[]
---@field choice? integer
---@field shown_choices? table<string, true>
---@field last_pos? integer[]
---@field cycle_id? integer
---@field pending_cycle_id? integer
---@field dismissed_cycle_id? integer
---@field request? minuet.VirtualtextRequest
---@field lease? minuet.SuggestionLease

---@class minuet.VirtualtextRequest
---@field bufnr integer
---@field cycle_id integer
---@field has_result boolean
---@field dismissed boolean
---@field callback_seen boolean
---@field consumed boolean
---@field changedtick integer
---@field cursor integer[]
---@field original_line string
---@field lease minuet.SuggestionLease
---@field invalid_reason? 'superseded'|'context_changed'|'buffer_unloaded'

---@param ctx minuet.VirtualtextSuggestionContext
local function reset_ctx(ctx)
    ctx.suggestions = nil
    ctx.choice = nil
    ctx.shown_choices = nil
    ctx.last_pos = nil
    ctx.cycle_id = nil
    ctx.lease = nil
end

local function stop_timer()
    local timer = internal.timer
    internal.timer = nil
    if timer and not timer:is_closing() then
        timer:stop()
        timer:close()
    end
end

local function stop_throttle_timer()
    if internal.throttle_timer and not internal.throttle_timer:is_closing() then
        internal.throttle_timer:stop()
        internal.throttle_timer:close()
    end
    internal.throttle_timer = nil
    internal.is_on_throttle = false
end

---@param bufnr? integer
local function clear_preview(bufnr)
    bufnr = bufnr or api.nvim_get_current_buf()
    pcall(api.nvim_buf_del_extmark, bufnr, internal.ns_id, internal.extmark_id)
end

---@param ctx? minuet.VirtualtextSuggestionContext
local function get_current_suggestion(ctx)
    ctx = ctx or get_ctx()

    local ok, choice = pcall(function()
        if not vim.fn.mode():match '^[iR]' or not ctx.suggestions or #ctx.suggestions == 0 then
            return nil
        end

        local choice = ctx.suggestions[ctx.choice]

        return choice
    end)

    if ok then
        return choice
    end

    return nil
end

---@param ctx? minuet.VirtualtextSuggestionContext
---@param bufnr? integer
local function update_preview(ctx, bufnr)
    ctx = ctx or get_ctx()
    bufnr = bufnr or api.nvim_get_current_buf()

    local suggestion = get_current_suggestion(ctx)
    local display_lines = suggestion and vim.split(suggestion, '\n', { plain = true }) or {}

    clear_preview(bufnr)

    local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

    if
        bufnr ~= api.nvim_get_current_buf()
        or not api.nvim_buf_is_loaded(bufnr)
        or not suggestion
        or #display_lines == 0
        or not controller.is_current(ctx.lease)
        or (not show_on_completion_menu and completion_menu_visible())
    then
        return
    end

    local annot = ''

    if ctx.suggestions and #ctx.suggestions > 1 then
        annot = '(' .. ctx.choice .. '/' .. #ctx.suggestions .. ')'
    end

    local cursor_col = vim.fn.col '.'
    local cursor_line = vim.fn.line '.'

    local extmark = {
        id = internal.extmark_id,
        virt_text = { { display_lines[1], 'MinuetVirtualText' } },
        virt_text_pos = 'inline',
    }

    if #display_lines > 1 then
        extmark.virt_lines = {}
        for i = 2, #display_lines do
            extmark.virt_lines[i - 1] = { { display_lines[i], 'MinuetVirtualText' } }
        end

        local last_line = #display_lines - 1
        extmark.virt_lines[last_line][1][1] = extmark.virt_lines[last_line][1][1] .. ' ' .. annot
    elseif #annot > 0 then
        extmark.virt_text[1][1] = extmark.virt_text[1][1] .. ' ' .. annot
    end

    extmark.hl_mode = 'replace'

    api.nvim_buf_set_extmark(bufnr, internal.ns_id, cursor_line - 1, cursor_col - 1, extmark)

    if ctx.lease and ctx.lease.phase == 'pending' then
        if not controller.mark_visible(ctx.lease) then
            clear_preview(bufnr)
            return
        end
    elseif not ctx.lease or (ctx.lease.phase ~= 'visible' and ctx.lease.phase ~= 'accepting') then
        clear_preview(bufnr)
        return
    end

    if ctx.cycle_id then
        metrics.suggestion_event(ctx.cycle_id, 'preview_shown')
    end

    if ctx.shown_choices and not ctx.shown_choices[suggestion] then
        ctx.shown_choices[suggestion] = true
    end

    ctx.last_pos = api.nvim_win_get_cursor(0)
end

---@param ctx? minuet.VirtualtextSuggestionContext
---@param bufnr? integer
---@param invalid_reason? 'superseded'|'context_changed'|'buffer_unloaded'
local function cleanup(ctx, bufnr, invalid_reason)
    ctx = ctx or get_ctx()
    bufnr = bufnr or api.nvim_get_current_buf()
    stop_timer()
    local request = ctx.request
    local lease = ctx.lease
    if request and not request.dismissed and not request.consumed and invalid_reason then
        request.invalid_reason = invalid_reason
        if request.has_result then
            metrics.suggestion_event(request.cycle_id, 'stale', invalid_reason)
        end
    end
    if request then
        require('minuet.backends.common').terminate_cycle(request.cycle_id)
    end
    if lease and controller.is_current(lease) then
        if invalid_reason then
            controller.finish(lease, 'stale', invalid_reason)
        else
            controller.release(lease)
        end
    end
    reset_ctx(ctx)
    ctx.pending_cycle_id = nil
    ctx.request = nil
    if internal.current_request == request then
        internal.current_request = nil
    end
    clear_preview(bufnr)
end

---@param ctx minuet.VirtualtextSuggestionContext
---@return boolean Returns true if there are suggestions matching the user’s typed text; otherwise, false.
local function update_suggestion_on_typing(ctx)
    if not (ctx and ctx.suggestions and ctx.choice) then
        return false
    end

    local bufnr = api.nvim_get_current_buf()
    local last_typed_text = get_last_typed_text(ctx, bufnr)
    if not (last_typed_text and #last_typed_text > 0) then
        return false
    end

    local typed = table.concat(last_typed_text, '\n')
    if #typed == 0 or typed ~= ctx.suggestions[ctx.choice]:sub(1, #typed) then
        return false
    end

    for i, suggestion in ipairs(ctx.suggestions) do
        if suggestion:sub(1, #typed) == typed then
            ctx.suggestions[i] = suggestion:sub(#typed + 1, -1)
        else
            ctx.suggestions[i] = ''
        end
    end

    update_preview(ctx, bufnr)
    stop_timer()

    if ctx.suggestions[ctx.choice] == '' and ctx.request then
        local request = ctx.request
        local lease = ctx.lease
        request.consumed = true
        require('minuet.backends.common').terminate_cycle(request.cycle_id)
        if lease then
            controller.release(lease)
        end
        clear_preview(bufnr)
        reset_ctx(ctx)
        ctx.pending_cycle_id = nil
        ctx.request = nil
        if internal.current_request == request then
            internal.current_request = nil
        end
    end
    return true
end

local action = {}

---@param bufnr integer
---@param intent? minuet.SuggestionIntent
---@return boolean started
local function trigger(bufnr, intent)
    intent = intent or 'auto'
    if bufnr ~= api.nvim_get_current_buf() or vim.fn.mode() ~= 'i' then
        return false
    end

    local config = require('minuet').config
    local loaded, provider = pcall(require, 'minuet.backends.' .. config.provider)
    if not loaded then
        utils.notify('Minuet completion provider is not supported.', 'error', vim.log.levels.ERROR)
        return false
    end

    local changedtick = api.nvim_buf_get_changedtick(bufnr)
    local cursor = api.nvim_win_get_cursor(0)
    local original_line = api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ''
    local lease = controller.begin {
        source = 'fim',
        intent = intent,
        bufnr = bufnr,
        changedtick = changedtick,
    }
    if not lease then
        return false
    end

    local built, completion_context = pcall(function()
        return utils.get_context(utils.make_cmp_context())
    end)
    if not built then
        controller.release(lease)
        utils.notify('Failed to build completion context.', 'error', vim.log.levels.ERROR)
        return false
    end

    utils.notify('Minuet virtual text started', 'verbose')

    local cycle_id = metrics.begin_cycle {
        channel = 'completion',
        frontend = 'virtualtext',
        provider_id = config.provider,
    }
    ---@type minuet.VirtualtextRequest
    local request = {
        bufnr = bufnr,
        cycle_id = cycle_id,
        has_result = false,
        dismissed = false,
        callback_seen = false,
        consumed = false,
        changedtick = changedtick,
        cursor = vim.deepcopy(cursor),
        original_line = original_line,
        lease = lease,
    }
    local ctx = get_ctx(bufnr)
    clear_preview(bufnr)
    reset_ctx(ctx)
    ctx.pending_cycle_id = cycle_id
    ctx.dismissed_cycle_id = nil
    ctx.request = request
    ctx.lease = lease
    internal.current_request = request
    lease.cycle_id = cycle_id

    controller.attach(lease, {
        cancel = function(reason)
            if ctx.request ~= request or ctx.lease ~= lease then
                return
            end
            request.invalid_reason = reason == 'buffer_unloaded' and 'buffer_unloaded'
                or reason == 'buffer_changed' and 'context_changed'
                or 'superseded'
            cleanup(ctx, bufnr, request.invalid_reason)
        end,
        can_accept = function()
            if
                api.nvim_get_current_buf() ~= bufnr
                or not api.nvim_buf_is_loaded(bufnr)
                or ctx.request ~= request
                or ctx.lease ~= lease
                or not get_current_suggestion(ctx)
            then
                return false, 'context_changed'
            end
            local extmark = api.nvim_buf_get_extmark_by_id(bufnr, internal.ns_id, internal.extmark_id, {})
            return extmark[1] ~= nil, 'context_changed'
        end,
        accept = function()
            action.accept()
        end,
        dismiss = function(_, explicit)
            if not explicit or ctx.request ~= request or ctx.lease ~= lease then
                return
            end
            request.dismissed = true
            ctx.dismissed_cycle_id = cycle_id
            metrics.suggestion_event(cycle_id, 'dismissed')
            require('minuet.duet.scheduler').dismissed(bufnr, api.nvim_buf_get_changedtick(bufnr))
            cleanup(ctx, bufnr)
        end,
        is_visible = function()
            if ctx.lease ~= lease or not api.nvim_buf_is_loaded(bufnr) then
                return false
            end
            local extmark = api.nvim_buf_get_extmark_by_id(bufnr, internal.ns_id, internal.extmark_id, {})
            return extmark[1] ~= nil
        end,
    })

    local called = pcall(provider.complete, completion_context, function(data)
        request.callback_seen = true
        local has_data = data and next(data) ~= nil
        if has_data then
            request.has_result = true
            metrics.cycle_has_result(cycle_id)
        end

        if
            request.invalid_reason
            or internal.current_request ~= request
            or ctx.request ~= request
            or ctx.lease ~= lease
            or not controller.is_current(lease)
        then
            if has_data and not request.dismissed and not request.consumed then
                -- Notify if outdated (and non-empty) completion items arrive
                utils.notify('Completion items arrived, but too late, aborted', 'debug', 'info')
                metrics.suggestion_event(cycle_id, 'stale', request.invalid_reason or 'superseded')
            end
            return
        end

        if not api.nvim_buf_is_loaded(bufnr) then
            request.invalid_reason = 'buffer_unloaded'
            if has_data then
                metrics.suggestion_event(cycle_id, 'stale', 'buffer_unloaded')
            end
            cleanup(ctx, bufnr, 'buffer_unloaded')
            return
        end
        if
            api.nvim_get_current_buf() ~= bufnr
            or api.nvim_buf_get_changedtick(bufnr) ~= request.changedtick
            or not vim.deep_equal(api.nvim_win_get_cursor(0), request.cursor)
            or (api.nvim_buf_get_lines(bufnr, request.cursor[1] - 1, request.cursor[1], false)[1] or '')
                ~= request.original_line
        then
            cleanup(ctx, bufnr, 'context_changed')
            return
        end

        data = utils.list_dedup(data or {})

        if next(data) then
            request.consumed = false
            ctx.suggestions = data
            ctx.cycle_id = cycle_id
            if not ctx.choice then
                ctx.choice = 1
            end
            ctx.shown_choices = {}
        end

        update_preview(ctx, bufnr)
        if not next(data) and not metrics.cycle_has_pending_requests(cycle_id) then
            cleanup(ctx, bufnr)
        end
    end, {
        cycle_id = cycle_id,
        frontend = 'virtualtext',
    })
    if not called then
        controller.release(lease)
        cleanup(ctx, bufnr)
        utils.notify('Failed to start completion request.', 'error', vim.log.levels.ERROR)
        return false
    end
    return true
end

local function advance(count, ctx)
    if ctx ~= get_ctx() then
        return
    end

    ctx.choice = (ctx.choice + count) % #ctx.suggestions
    if ctx.choice < 1 then
        ctx.choice = #ctx.suggestions
    end

    update_preview(ctx, api.nvim_get_current_buf())
end

local function schedule()
    if internal.is_on_throttle then
        return
    end

    stop_timer()

    local config = require('minuet').config
    local bufnr = api.nvim_get_current_buf()

    local timer
    timer = vim.defer_fn(function()
        if internal.timer == timer then
            internal.timer = nil
        end
        local show_on_completion_menu = require('minuet').config.virtualtext.show_on_completion_menu

        if
            not should_auto_trigger()
            or internal.is_on_throttle
            or (not show_on_completion_menu and completion_menu_visible())
            or (not utils.run_hooks_until_failure(config.enable_predicates))
        then
            return
        end

        internal.is_on_throttle = true
        internal.throttle_timer = vim.defer_fn(function()
            internal.throttle_timer = nil
            internal.is_on_throttle = false
        end, config.throttle)

        trigger(bufnr, 'auto')
    end, config.debounce)
    internal.timer = timer
end

action.next = function()
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf(), 'manual')
        return
    end

    advance(1, ctx)
end

action.prev = function()
    local ctx = get_ctx()

    -- no suggestion request yet
    if not ctx.suggestions then
        trigger(api.nvim_get_current_buf(), 'manual')
        return
    end

    advance(-1, ctx)
end

---@param n_lines? integer Number of lines to accept from the suggestion. If nil, accepts all lines.
---Accepts the current suggestion by inserting it at the cursor position.
---If n_lines is provided, only the first n_lines of the suggestion are inserted.
---After insertion, moves the cursor to the end of the inserted text.
function action.accept(n_lines)
    local bufnr = api.nvim_get_current_buf()
    local ctx = get_ctx()
    local suggestion = get_current_suggestion(ctx)
    local lease = ctx.lease
    if not suggestion or not lease or not controller.is_current(lease) then
        return false
    end

    local suggestions = vim.split(suggestion, '\n')
    local remaining_suggestions = {}
    local cycle_id = ctx.cycle_id
    local request = ctx.request
    local changedtick = api.nvim_buf_get_changedtick(bufnr)
    local cursor = api.nvim_win_get_cursor(0)
    local line, col = cursor[1] - 1, cursor[2]
    local original_line = api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ''

    if n_lines then
        -- NOTE: If the first line is an empty string (""), it indicates that
        -- the original suggestion began with a newline character. This
        -- typically occurs during partial completion: when the user accepts
        -- the first line, the remaining suggestion may start with '\n'. In
        -- this scenario, we increment n_lines by 1 because the user intends to
        -- accept the next visible line of text, which corresponds to the
        -- subsequent element in the suggestions list.
        if suggestions[1] == '' then
            n_lines = n_lines + 1
        end
        n_lines = math.min(n_lines, #suggestions)
        remaining_suggestions = vim.list_slice(suggestions, n_lines + 1, #suggestions)
        suggestions = vim.list_slice(suggestions, 1, n_lines)
    end

    clear_preview(bufnr)

    if vim.fn.pumvisible() == 1 then
        -- Accepting Minuet completion while the pum is open is temporary; when
        -- the user closes the pum, Vim restores the buffer state and removes
        -- Minuet's completion text. Therefore we need to close the pum before
        -- accepting.
        api.nvim_feedkeys(api.nvim_replace_termcodes('<C-e>', true, true, true), 'n', true)
    end

    vim.schedule(function()
        if
            not api.nvim_buf_is_loaded(bufnr)
            or api.nvim_get_current_buf() ~= bufnr
            or not controller.is_current(lease)
            or ctx.lease ~= lease
            or api.nvim_buf_get_changedtick(bufnr) ~= changedtick
            or not vim.deep_equal(api.nvim_win_get_cursor(0), cursor)
            or (api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or '') ~= original_line
        then
            cleanup(ctx, bufnr, api.nvim_buf_is_loaded(bufnr) and 'context_changed' or 'buffer_unloaded')
            return
        end

        local ok = pcall(api.nvim_buf_set_text, bufnr, line, col, line, col, suggestions)
        if not ok then
            cleanup(ctx, bufnr, 'context_changed')
            return
        end
        if request and request.cycle_id == cycle_id and #remaining_suggestions == 0 then
            request.consumed = true
        end
        if request then
            require('minuet.backends.common').terminate_cycle(request.cycle_id)
        end
        if cycle_id then
            metrics.suggestion_event(cycle_id, 'accepted')
        end

        local new_col = #suggestions[#suggestions]
        -- For single-line suggestions, adjust the column position by adding the
        -- current column offset
        if #suggestions == 1 then
            new_col = new_col + col
        end
        if api.nvim_get_current_buf() == bufnr then
            pcall(api.nvim_win_set_cursor, 0, { line + #suggestions, new_col })
        end

        if #remaining_suggestions == 0 then
            if request then
                request.consumed = true
            end
            controller.finish(lease, 'accepted')
            clear_preview(bufnr)
            reset_ctx(ctx)
            ctx.pending_cycle_id = nil
            ctx.request = nil
            if internal.current_request == request then
                internal.current_request = nil
            end
            require('minuet.duet.scheduler').after_accept(bufnr)
        end
    end)
    return true
end

function action.accept_n_lines()
    local cursor_pos = vim.api.nvim_win_get_cursor(0)
    local n = vim.fn.input 'accept n lines: '

    -- FIXME: vim.fn.input may change cursor position, we need to restore the
    -- cursor position after the user input.

    vim.api.nvim_win_set_cursor(0, cursor_pos)

    ---@diagnostic disable-next-line:cast-local-type
    n = tonumber(n)
    if not n then
        return
    end
    if n > 0 then
        action.accept(n)
    else
        vim.notify('Invalid number of lines', vim.log.levels.ERROR)
    end
end

function action.accept_line()
    action.accept(1)
end

function action.dismiss()
    local ctx = get_ctx()
    if ctx.lease then
        return controller.dismiss(ctx.lease)
    end
    return false
end

function action.is_visible()
    local bufnr = api.nvim_get_current_buf()
    return not not api.nvim_buf_get_extmark_by_id(bufnr, internal.ns_id, internal.extmark_id, { details = false })[1]
end

function action.disable_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = false
    stop_timer()
    vim.notify('Minuet Virtual Text auto trigger disabled', vim.log.levels.INFO)
end

function action.enable_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = true
    vim.notify('Minuet Virtual Text auto trigger enabled', vim.log.levels.INFO)
end

function action.toggle_auto_trigger()
    vim.b.minuet_virtual_text_auto_trigger = not should_auto_trigger()
    if not should_auto_trigger() then
        stop_timer()
    end
    vim.notify(
        'Minuet Virtual Text auto trigger ' .. (should_auto_trigger() and 'enabled' or 'disabled'),
        vim.log.levels.INFO
    )
end

M.action = action

local autocmd = {}

function autocmd.on_insert_leave()
    local bufnr = api.nvim_get_current_buf()
    cleanup(get_ctx(bufnr), bufnr, 'context_changed')
end

---@param info { buf: integer }
function autocmd.on_buf_leave(info)
    local ctx = internal.context[info.buf]
    if ctx then
        cleanup(ctx, info.buf, 'context_changed')
    end
end

function autocmd.on_insert_enter()
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_buf_enter()
    if vim.fn.mode():match '^[iR]' then
        autocmd.on_insert_enter()
    end
end

function autocmd.on_cursor_moved_i()
    local ctx = get_ctx()

    if update_suggestion_on_typing(ctx) then
        return
    end

    -- we don't cleanup immediately if the completion has arrived but not
    -- display yet.
    if ctx.shown_choices and next(ctx.shown_choices) then
        local bufnr = api.nvim_get_current_buf()
        cleanup(ctx, bufnr, 'context_changed')
    end
    if should_auto_trigger() then
        schedule()
    end
end

function autocmd.on_cursor_hold_i()
    local bufnr = api.nvim_get_current_buf()
    update_preview(get_ctx(bufnr), bufnr)
end

function autocmd.on_text_changed_p()
    autocmd.on_cursor_moved_i()
end

---@param info { buf: integer }
function autocmd.on_buf_unload(info)
    local ctx = internal.context[info.buf]
    if ctx then
        cleanup(ctx, info.buf, 'buffer_unloaded')
    end
    internal.context[info.buf] = nil
end

local function create_autocmds()
    api.nvim_create_autocmd('InsertLeave', {
        group = internal.augroup,
        callback = autocmd.on_insert_leave,
        desc = '[minuet.virtualtext] insert leave',
    })

    api.nvim_create_autocmd('BufLeave', {
        group = internal.augroup,
        callback = autocmd.on_buf_leave,
        desc = '[minuet.virtualtext] buf leave',
    })

    api.nvim_create_autocmd('InsertEnter', {
        group = internal.augroup,
        callback = autocmd.on_insert_enter,
        desc = '[minuet.virtualtext] insert enter',
    })

    api.nvim_create_autocmd('BufEnter', {
        group = internal.augroup,
        callback = autocmd.on_buf_enter,
        desc = '[minuet.virtualtext] buf enter',
    })

    api.nvim_create_autocmd('CursorMovedI', {
        group = internal.augroup,
        callback = autocmd.on_cursor_moved_i,
        desc = '[minuet.virtualtext] cursor moved insert',
    })

    api.nvim_create_autocmd('TextChangedP', {
        group = internal.augroup,
        callback = autocmd.on_text_changed_p,
        desc = '[minuet.virtualtext] text changed p',
    })

    api.nvim_create_autocmd('BufUnload', {
        group = internal.augroup,
        callback = autocmd.on_buf_unload,
        desc = '[minuet.virtualtext] buf unload',
    })
end

local function set_keymaps(keymap)
    if keymap.accept then
        vim.keymap.set('i', keymap.accept, action.accept, {
            desc = '[minuet.virtualtext] accept suggestion',
            silent = true,
        })
    end

    if keymap.accept_line then
        vim.keymap.set('i', keymap.accept_line, action.accept_line, {
            desc = '[minuet.virtualtext] accept suggestion (line)',
            silent = true,
        })
    end

    if keymap.accept_n_lines then
        vim.keymap.set('i', keymap.accept_n_lines, action.accept_n_lines, {
            desc = '[minuet.virtualtext] accept suggestion (n lines)',
            silent = true,
        })
    end

    if keymap.next then
        vim.keymap.set('i', keymap.next, action.next, {
            desc = '[minuet.virtualtext] next suggestion',
            silent = true,
        })
    end

    if keymap.prev then
        vim.keymap.set('i', keymap.prev, action.prev, {
            desc = '[minuet.virtualtext] prev suggestion',
            silent = true,
        })
    end

    if keymap.dismiss then
        vim.keymap.set('i', keymap.dismiss, action.dismiss, {
            desc = '[minuet.virtualtext] dismiss suggestion',
            silent = true,
        })
    end
end

function M.setup()
    local config = require('minuet').config
    api.nvim_clear_autocmds { group = M.augroup }
    stop_throttle_timer()
    for bufnr, ctx in pairs(internal.context) do
        cleanup(ctx, bufnr, 'superseded')
    end
    internal.context = {}
    internal.current_request = nil

    if #config.virtualtext.auto_trigger_ft > 0 then
        api.nvim_create_autocmd('FileType', {
            pattern = config.virtualtext.auto_trigger_ft,
            callback = function()
                if not vim.tbl_contains(config.virtualtext.auto_trigger_ignore_ft, vim.bo.ft) then
                    vim.b.minuet_virtual_text_auto_trigger = true
                end
            end,
            group = M.augroup,
            desc = 'minuet virtual text filetype auto trigger',
        })
    end

    create_autocmds()
    set_keymaps(config.virtualtext.keymap)
end

return M
