local api = vim.api
local apply = require 'minuet.duet.apply'
local candidates = require 'minuet.duet.candidates'
local context = require 'minuet.duet.context'
local controller = require 'minuet.suggestion'
local edits = require 'minuet.duet.edits'
local feedback = require 'minuet.duet.feedback'
local guards = require 'minuet.duet.guards'
local metrics = require 'minuet.metrics'
local preview = require 'minuet.duet.preview'
local quality = require 'minuet.duet.quality'
local scheduler = require 'minuet.duet.scheduler'
local symbols = require 'minuet.duet.symbols'
local utils = require 'minuet.duet.utils'

local M = {}

M.augroup = api.nvim_create_augroup('MinuetDuet', { clear = true })

local internal = {
    ---@type table<integer, minuet.DuetState>
    states = {},
    request_seq = 0,
}

---@class minuet.DuetRequestState
---@field seq integer
---@field cycle_id integer
---@field lease minuet.SuggestionLease
---@field has_result boolean
---@field dismissed boolean
---@field invalid_reason? 'superseded'|'buffer_changed'|'buffer_unloaded'|'apply_validation'

---@class minuet.DuetState
---@field pending_seq? integer
---@field pending_request? minuet.DuetRequestState
---@field cycle_id? integer
---@field lease? minuet.SuggestionLease
---@field edit? minuet.DuetEdit
---@field candidate? minuet.DuetCandidate
---@field origin_row? integer
---@field origin_col? integer
---@field jump_required? boolean
---@field target_bufnr? integer
---@field cross_buffer? boolean
---@field focusing? boolean
---@field extmarks? { bufnr: integer, id: integer }[]
---@field preview_kind? 'jump'|'cross_jump'|'edit'
---@field semantic? minuet.DuetSemanticContext
---@field semantic_cancel? fun()

---@param bufnr integer
---@return minuet.DuetState
local function get_state(bufnr)
    local state = internal.states[bufnr]
    if not state then
        state = {}
        internal.states[bufnr] = state
    end
    return state
end

---@param bufnr integer
---@param state minuet.DuetState
local function clear_state(bufnr, state)
    local semantic_cancel = state.semantic_cancel
    state.semantic_cancel = nil
    if semantic_cancel then
        semantic_cancel()
    end
    preview.clear(bufnr, state)
    state.pending_seq = nil
    state.pending_request = nil
    state.cycle_id = nil
    state.lease = nil
    state.edit = nil
    state.candidate = nil
    state.origin_row = nil
    state.origin_col = nil
    state.jump_required = nil
    state.target_bufnr = nil
    state.cross_buffer = nil
    state.focusing = nil
    state.semantic = nil
end

---@param lease minuet.SuggestionLease?
---@return minuet.DuetState?
local function state_for_lease(lease)
    if not lease then
        return nil
    end
    return internal.states[lease.state_bufnr or lease.bufnr]
end

---@return string
local function current_provider()
    return require('minuet').config.duet.provider
end

---@param reason string
---@return 'superseded'|'buffer_changed'|'buffer_unloaded'|'apply_validation'
local function stale_reason(reason)
    if
        reason == 'buffer_changed'
        or reason == 'buffer_unloaded'
        or reason == 'apply_validation'
        or reason == 'superseded'
    then
        return reason
    end
    return 'superseded'
end

---@param lease minuet.SuggestionLease
---@return boolean
local function anchors_valid(lease)
    if
        not api.nvim_buf_is_valid(lease.origin_bufnr)
        or not api.nvim_buf_is_loaded(lease.origin_bufnr)
        or api.nvim_buf_get_changedtick(lease.origin_bufnr) ~= lease.origin_changedtick
        or not api.nvim_buf_is_valid(lease.target_bufnr)
        or not api.nvim_buf_is_loaded(lease.target_bufnr)
        or api.nvim_buf_get_changedtick(lease.target_bufnr) ~= lease.target_changedtick
    then
        return false
    end
    if not lease.cross_buffer then
        return true
    end

    local config = require('minuet').config.duet
    if
        not guards.is_safe_buffer(lease.target_bufnr, true, config.auto_trigger.max_buffer_size)
        or not vim.bo[lease.target_bufnr].modifiable
        or type(lease.workspace_root) ~= 'string'
        or guards.relative_path(lease.workspace_root, api.nvim_buf_get_name(lease.origin_bufnr)) == nil
    then
        return false
    end
    local target_path = guards.relative_path(lease.workspace_root, api.nvim_buf_get_name(lease.target_bufnr))
    return target_path ~= nil and target_path == lease.target_path
end

---@param lease minuet.SuggestionLease
---@param reason string
local function cancel_lease(lease, reason)
    local state_bufnr = lease.state_bufnr or lease.bufnr
    local state = internal.states[state_bufnr]
    if not state or state.lease ~= lease then
        return
    end

    local classified_reason = stale_reason(reason)
    local request = state.pending_request
    if request and request.lease == lease then
        request.invalid_reason = classified_reason
        if request.has_result and not request.dismissed then
            metrics.suggestion_event(request.cycle_id, 'stale', classified_reason)
        end
        require('minuet.duet.backends.common').terminate_cycle(request.cycle_id)
    end
    if state.cycle_id then
        metrics.suggestion_event(state.cycle_id, 'stale', classified_reason)
    end
    clear_state(state_bufnr, state)
end

---@param lease minuet.SuggestionLease
local function dismiss_lease(lease)
    local state_bufnr = lease.state_bufnr or lease.bufnr
    local state = internal.states[state_bufnr]
    if not state or state.lease ~= lease then
        return
    end

    local request = state.pending_request
    if request and request.lease == lease then
        request.dismissed = true
        metrics.suggestion_event(request.cycle_id, 'dismissed')
        require('minuet.duet.backends.common').terminate_cycle(request.cycle_id)
    end
    if state.cycle_id then
        metrics.suggestion_event(state.cycle_id, 'dismissed')
    end
    local current_tick = api.nvim_buf_is_valid(lease.target_bufnr) and api.nvim_buf_get_changedtick(lease.target_bufnr)
        or lease.target_changedtick
    scheduler.dismissed(lease.target_bufnr, current_tick)
    clear_state(state_bufnr, state)
end

---@param lease minuet.SuggestionLease
---@param edit minuet.DuetEdit
---@return boolean
local function perform_apply(lease, edit)
    local state_bufnr = lease.state_bufnr or lease.bufnr
    local state = internal.states[state_bufnr]
    if not state or state.lease ~= lease or state.edit ~= edit then
        return false
    end

    local applied = anchors_valid(lease) and apply.apply(edit, lease)
    if not applied then
        if state.cycle_id then
            metrics.suggestion_event(state.cycle_id, 'stale', 'apply_validation')
        end
        controller.finish(lease, 'stale', 'apply_validation')
        clear_state(state_bufnr, state)
        return false
    end

    local cycle_id = state.cycle_id
    if cycle_id then
        metrics.suggestion_event(cycle_id, 'accepted')
        feedback.track_accept(cycle_id, edit.bufnr)
    end
    controller.finish(lease, 'accepted')
    clear_state(state_bufnr, state)
    scheduler.after_accept(edit.bufnr)
    return true
end

---Focus a remote edit without changing the buffer or completing its lifecycle.
---@param lease minuet.SuggestionLease
---@param edit minuet.DuetEdit
---@return boolean
local function focus_remote_edit(lease, edit)
    local state_bufnr = lease.state_bufnr or lease.bufnr
    local state = internal.states[state_bufnr]
    if
        not state
        or state.lease ~= lease
        or state.edit ~= edit
        or not apply.preflight(edit, lease)
        or type(lease.target_row) ~= 'number'
        or type(lease.target_col) ~= 'number'
        or not anchors_valid(lease)
    then
        controller.invalidate(lease, 'apply_validation')
        return false
    end

    if lease.cross_buffer then
        if api.nvim_get_current_buf() ~= lease.origin_bufnr then
            controller.invalidate(lease, 'apply_validation')
            return false
        end
        state.focusing = true
        local switched = pcall(vim.cmd, ('hide buffer %d'):format(lease.target_bufnr))
        state.focusing = false
        if not switched or api.nvim_get_current_buf() ~= lease.target_bufnr then
            controller.invalidate(lease, 'apply_validation')
            return false
        end
    end

    local focused = pcall(api.nvim_win_set_cursor, 0, { lease.target_row + 1, lease.target_col })
    if not focused then
        controller.invalidate(lease, 'apply_validation')
        return false
    end

    lease.jumped = true
    lease.jump_required = false
    state.jump_required = false
    preview.render(edit.bufnr, state, edit)
    if not preview.is_visible(edit.bufnr, state) or not controller.resume_visible(lease) then
        controller.invalidate(lease, 'apply_validation')
        return false
    end
    return true
end

---@param intent? minuet.SuggestionIntent
---@return boolean started
local function predict(intent)
    intent = intent or 'manual'
    local bufnr = api.nvim_get_current_buf()
    if not api.nvim_buf_is_loaded(bufnr) or not vim.bo[bufnr].modifiable then
        return false
    end

    local provider_name = current_provider()
    local ok, backend = pcall(require, 'minuet.duet.backends.' .. provider_name)
    if not ok then
        utils.notify('Minuet duet provider is not supported: ' .. provider_name, 'error', vim.log.levels.ERROR)
        return false
    end

    local changedtick = api.nvim_buf_get_changedtick(bufnr)
    local lease = controller.begin {
        source = 'duet',
        intent = intent,
        bufnr = bufnr,
        changedtick = changedtick,
    }
    if not lease then
        return false
    end

    local state = get_state(bufnr)
    clear_state(bufnr, state)
    state.lease = lease

    controller.attach(lease, {
        cancel = function(reason)
            cancel_lease(lease, reason)
        end,
        can_accept = function()
            if state.lease ~= lease or not preview.is_visible(bufnr, state) then
                return false, 'apply_validation'
            end
            if not anchors_valid(lease) then
                return false, 'apply_validation'
            end
            local expected_bufnr = lease.jumped and lease.target_bufnr or lease.origin_bufnr
            if api.nvim_get_current_buf() ~= expected_bufnr then
                return false, 'apply_validation'
            end
            return apply.preflight(state.edit, lease)
        end,
        accept = function()
            local edit = state.edit
            if not edit then
                cancel_lease(lease, 'apply_validation')
                return
            end
            if lease.jump_required and not lease.jumped then
                focus_remote_edit(lease, edit)
                return
            end
            vim.schedule(function()
                perform_apply(lease, edit)
            end)
        end,
        dismiss = function(_, explicit)
            if explicit then
                dismiss_lease(lease)
            else
                cancel_lease(lease, 'apply_validation')
            end
        end,
        is_visible = function()
            return state.lease == lease and preview.is_visible(bufnr, state)
        end,
    })

    edits.ensure_setup()
    edits.flush(bufnr, { wait = true })
    if
        not controller.is_current(lease)
        or bufnr ~= api.nvim_get_current_buf()
        or api.nvim_buf_get_changedtick(bufnr) ~= changedtick
    then
        controller.invalidate(lease, 'buffer_changed')
        return false
    end

    ---@param semantic minuet.DuetSemanticContext
    ---@return boolean
    local function continue_prediction(semantic)
        if
            not controller.is_current(lease)
            or bufnr ~= api.nvim_get_current_buf()
            or api.nvim_buf_get_changedtick(bufnr) ~= changedtick
        then
            controller.invalidate(lease, 'buffer_changed')
            return false
        end
        state.semantic_cancel = nil
        state.semantic = semantic
        local origin = api.nvim_win_get_cursor(0)
        local candidate = candidates.select(bufnr, { semantic = semantic })
        if not candidate then
            controller.release(lease)
            clear_state(bufnr, state)
            return false
        end
        state.candidate = candidate
        state.origin_row = origin[1] - 1
        state.origin_col = origin[2]
        local target_bufnr = candidate.bufnr
        local cross_buffer = target_bufnr ~= bufnr
        if
            not api.nvim_buf_is_valid(target_bufnr)
            or not api.nvim_buf_is_loaded(target_bufnr)
            or not vim.bo[target_bufnr].modifiable
        then
            controller.release(lease)
            clear_state(bufnr, state)
            return false
        end
        lease.origin_bufnr = bufnr
        lease.origin_changedtick = changedtick
        lease.target_bufnr = target_bufnr
        lease.target_changedtick = api.nvim_buf_get_changedtick(target_bufnr)
        lease.state_bufnr = bufnr
        lease.cross_buffer = cross_buffer
        state.target_bufnr = target_bufnr
        state.cross_buffer = cross_buffer
        if cross_buffer then
            local root = guards.workspace_path(bufnr)
            local target_path = root and guards.relative_path(root, api.nvim_buf_get_name(target_bufnr)) or nil
            if not root or not target_path then
                controller.release(lease)
                clear_state(bufnr, state)
                return false
            end
            lease.workspace_root = root
            lease.target_path = target_path
        end

        local built, current_context = pcall(context.build, target_bufnr, candidate, semantic)
        if not built or type(current_context) ~= 'table' then
            controller.release(lease)
            clear_state(bufnr, state)
            utils.notify('Failed to build duet context.', 'error', vim.log.levels.ERROR)
            return false
        end

        internal.request_seq = internal.request_seq + 1
        local request_seq = internal.request_seq
        local cycle_id = metrics.begin_cycle {
            channel = 'duet',
            frontend = 'duet',
            provider_id = provider_name,
        }
        lease.cycle_id = cycle_id
        ---@type minuet.DuetRequestState
        local request = {
            seq = request_seq,
            cycle_id = cycle_id,
            lease = lease,
            has_result = false,
            dismissed = false,
        }
        state.pending_seq = request_seq
        state.pending_request = request

        utils.notify('Minuet duet started', 'verbose', vim.log.levels.INFO)
        scheduler.note_request_started()

        local called = pcall(backend.complete, current_context, function(text)
            local has_text = type(text) == 'string' and text ~= ''
            if has_text then
                request.has_result = true
                metrics.cycle_has_result(cycle_id)
            end

            vim.schedule(function()
                if request.dismissed then
                    return
                end
                if not api.nvim_buf_is_loaded(bufnr) or not api.nvim_buf_is_loaded(target_bufnr) then
                    request.invalid_reason = 'buffer_unloaded'
                    if has_text then
                        metrics.suggestion_event(cycle_id, 'stale', 'buffer_unloaded')
                    end
                    controller.finish(lease, 'stale', 'buffer_unloaded')
                    if state.lease == lease then
                        clear_state(bufnr, state)
                    end
                    return
                end
                if
                    state.pending_seq ~= request_seq
                    or state.pending_request ~= request
                    or state.lease ~= lease
                    or not controller.is_current(lease)
                then
                    if has_text then
                        metrics.suggestion_event(cycle_id, 'stale', request.invalid_reason or 'superseded')
                    end
                    return
                end

                state.pending_seq = nil
                state.pending_request = nil
                if not has_text then
                    controller.release(lease)
                    clear_state(bufnr, state)
                    return
                end
                if
                    bufnr ~= api.nvim_get_current_buf()
                    or api.nvim_buf_get_changedtick(bufnr) ~= changedtick
                    or api.nvim_buf_get_changedtick(target_bufnr) ~= current_context.changedtick
                    or not candidates.exists(candidate, { semantic = semantic, origin_bufnr = bufnr })
                then
                    metrics.suggestion_event(cycle_id, 'stale', 'buffer_changed')
                    controller.finish(lease, 'stale', 'buffer_changed')
                    clear_state(bufnr, state)
                    return
                end

                local parsed, _, parse_reason = utils.parse_duet_response(text, current_context)
                if not parsed then
                    metrics.suggestion_event(cycle_id, 'parse_failed', parse_reason or 'invalid_markers')
                    controller.release(lease)
                    clear_state(bufnr, state)
                    utils.notify(
                        'Minuet duet response has invalid editable-region markers.',
                        'warn',
                        vim.log.levels.WARN
                    )
                    return
                end

                local edit, filter_reason = apply.prepare({
                    bufnr = target_bufnr,
                    changedtick = current_context.changedtick,
                    range = current_context.range,
                    original_lines = current_context.original_lines,
                    proposed_lines = parsed.lines,
                    cursor = parsed.cursor,
                }, lease)
                if not edit then
                    if filter_reason == 'stale' or filter_reason == 'invalid' then
                        metrics.suggestion_event(cycle_id, 'stale', 'buffer_changed')
                        controller.finish(lease, 'stale', 'buffer_changed')
                    else
                        metrics.suggestion_event(cycle_id, 'filtered', filter_reason)
                        controller.release(lease)
                    end
                    clear_state(bufnr, state)
                    return
                end
                if quality.is_repeat(edit) then
                    metrics.suggestion_event(cycle_id, 'filtered', 'repeat')
                    controller.release(lease)
                    clear_state(bufnr, state)
                    return
                end

                state.cycle_id = cycle_id
                state.edit = edit
                local first_hunk = edit.hunks[1]
                local line_count = math.max(api.nvim_buf_line_count(target_bufnr), 1)
                local target_row =
                    math.min(math.max(edit.range.start_row + math.max(first_hunk[1] - 1, 0), 0), line_count - 1)
                local target_line = api.nvim_buf_get_lines(target_bufnr, target_row, target_row + 1, false)[1] or ''
                local target_col = target_row == candidate.row and math.min(candidate.col, #target_line) or 0
                local config = require('minuet').config.duet
                local jump_required = cross_buffer
                    or (config.jump_requires_confirmation ~= false and target_row ~= state.origin_row)
                lease.target_row = target_row
                lease.target_col = target_col
                lease.jump_required = jump_required
                state.jump_required = jump_required
                if cross_buffer then
                    if not anchors_valid(lease) then
                        metrics.suggestion_event(cycle_id, 'stale', 'buffer_changed')
                        controller.finish(lease, 'stale', 'buffer_changed')
                        clear_state(bufnr, state)
                        return
                    end
                    preview.render_cross_jump(
                        bufnr,
                        target_bufnr,
                        state,
                        state.origin_row,
                        target_row,
                        guards.safe_label(lease.target_path)
                    )
                elseif jump_required then
                    preview.render_jump(bufnr, state, state.origin_row, target_row)
                else
                    preview.render(target_bufnr, state, edit)
                end
                if preview.is_visible(bufnr, state) then
                    metrics.suggestion_event(cycle_id, 'preview_shown')
                    if not controller.mark_visible(lease) then
                        clear_state(bufnr, state)
                    end
                else
                    controller.release(lease)
                    clear_state(bufnr, state)
                end
            end)
        end, {
            cycle_id = cycle_id,
            frontend = 'duet',
        })

        if not called then
            controller.release(lease)
            clear_state(bufnr, state)
            utils.notify('Failed to start duet request.', 'error', vim.log.levels.ERROR)
            return false
        end
        return true
    end

    local duet_config = require('minuet').config.duet
    if
        duet_config.scope == 'cursor'
        or (duet_config.candidates.references == false and duet_config.candidates.text == false)
    then
        return continue_prediction {
            bufnr = bufnr,
            changedtick = changedtick,
            identifiers = {},
            text_matches = {},
            references = {},
            related_references = {},
            definitions = {},
            symbols = {},
            timed_out = false,
        }
    end

    local semantic_delivered = false
    local semantic_cancel = symbols.collect(bufnr, function(semantic)
        semantic_delivered = true
        continue_prediction(semantic)
    end, {
        references = duet_config.candidates.references,
        text = duet_config.candidates.text,
        related_buffers = duet_config.scope == 'workspace' and duet_config.candidates.related_buffers,
    })
    if not semantic_delivered then
        state.semantic_cancel = semantic_cancel
    end
    return true
end

local action = {}

function action.predict()
    return predict 'manual'
end

function action.apply()
    local lease = controller.current()
    local state = state_for_lease(lease)
    if
        not lease
        or not state
        or lease.source ~= 'duet'
        or lease.phase ~= 'visible'
        or not state.edit
        or not anchors_valid(lease)
        or not apply.preflight(state.edit, lease)
    then
        if lease and lease.source == 'duet' then
            controller.invalidate(lease, 'apply_validation')
        end
        utils.notify('No valid Minuet duet prediction to apply.', 'warn', vim.log.levels.WARN)
        return false
    end

    if not controller.mark_accepting(lease) then
        return false
    end
    if lease.jump_required and not lease.jumped then
        return focus_remote_edit(lease, state.edit)
    end
    return perform_apply(lease, state.edit)
end

function action.dismiss()
    local lease = controller.current()
    local state = state_for_lease(lease)
    if state and state.lease == lease and lease.source == 'duet' then
        return controller.dismiss(lease)
    end
    return false
end

function action.is_visible()
    local lease = controller.current()
    local state = state_for_lease(lease)
    return state ~= nil and preview.is_visible(api.nvim_get_current_buf(), state)
end

M.action = action

---@param value any
---@param default integer
---@return integer
local function normalize_nonnegative_integer(value, default)
    if type(value) ~= 'number' or value ~= math.floor(value) or value < 0 then
        return default
    end
    return value
end

function M.setup()
    api.nvim_clear_autocmds { group = M.augroup }
    for bufnr, state in pairs(internal.states) do
        preview.clear(bufnr, state)
    end
    internal.states = {}

    local config = require('minuet').config.duet
    local defaults = require 'minuet.duet.config'
    config.auto_trigger.debounce =
        normalize_nonnegative_integer(config.auto_trigger.debounce, defaults.auto_trigger.debounce)
    config.auto_trigger.throttle =
        normalize_nonnegative_integer(config.auto_trigger.throttle, defaults.auto_trigger.throttle)
    config.auto_trigger.max_buffer_size =
        normalize_nonnegative_integer(config.auto_trigger.max_buffer_size, defaults.auto_trigger.max_buffer_size)
    if type(config.auto_trigger.filetype) ~= 'table' then
        config.auto_trigger.filetype = {}
    end
    local filetype_policies = {}
    for filetype, policy in pairs(config.auto_trigger.filetype) do
        if type(filetype) == 'string' and filetype ~= '' and type(policy) == 'table' then
            local normalized = {}
            if policy.debounce ~= nil then
                normalized.debounce =
                    math.min(normalize_nonnegative_integer(policy.debounce, config.auto_trigger.debounce), 3600000)
            end
            if policy.throttle ~= nil then
                normalized.throttle =
                    math.min(normalize_nonnegative_integer(policy.throttle, config.auto_trigger.throttle), 3600000)
            end
            filetype_policies[filetype] = normalized
        end
    end
    config.auto_trigger.filetype = filetype_policies
    config.max_edit_lines = normalize_nonnegative_integer(config.max_edit_lines, defaults.max_edit_lines)
    config.max_edit_chars = normalize_nonnegative_integer(config.max_edit_chars, defaults.max_edit_chars)
    if type(config.quality) ~= 'table' then
        config.quality = vim.deepcopy(defaults.quality)
    end
    config.quality.undo_window =
        math.min(normalize_nonnegative_integer(config.quality.undo_window, defaults.quality.undo_window), 600000)
    config.quality.max_pending_undo = math.min(
        normalize_nonnegative_integer(config.quality.max_pending_undo, defaults.quality.max_pending_undo),
        4096
    )
    if type(config.quality.repeat_suppression) ~= 'table' then
        config.quality.repeat_suppression = vim.deepcopy(defaults.quality.repeat_suppression)
    end
    if type(config.quality.repeat_suppression.enabled) ~= 'boolean' then
        config.quality.repeat_suppression.enabled = defaults.quality.repeat_suppression.enabled
    end
    config.quality.repeat_suppression.ttl = math.min(
        normalize_nonnegative_integer(config.quality.repeat_suppression.ttl, defaults.quality.repeat_suppression.ttl),
        3600000
    )
    config.quality.repeat_suppression.max_entries = math.min(
        normalize_nonnegative_integer(
            config.quality.repeat_suppression.max_entries,
            defaults.quality.repeat_suppression.max_entries
        ),
        4096
    )
    if config.scope ~= 'cursor' and config.scope ~= 'buffer' and config.scope ~= 'workspace' then
        config.scope = defaults.scope
    end
    if type(config.jump_requires_confirmation) ~= 'boolean' then
        config.jump_requires_confirmation = defaults.jump_requires_confirmation
    end
    if type(config.candidates) ~= 'table' then
        config.candidates = vim.deepcopy(defaults.candidates)
    end
    for _, source in ipairs { 'cursor', 'recent_edits', 'diagnostics', 'references', 'text', 'related_buffers' } do
        if type(config.candidates[source]) ~= 'boolean' then
            config.candidates[source] = defaults.candidates[source]
        end
    end
    local max_candidates =
        normalize_nonnegative_integer(config.candidates.max_candidates, defaults.candidates.max_candidates)
    config.candidates.max_candidates = math.min(math.max(max_candidates, 1), 64)
    if type(config.lsp) ~= 'table' then
        config.lsp = vim.deepcopy(defaults.lsp)
    end
    for key, fallback in pairs(defaults.lsp) do
        local maximum = key == 'timeout' and 2000 or (key == 'cache_ttl' and 3600000 or 1024)
        local minimum = (key == 'timeout' or key == 'cache_ttl' or key == 'max_symbol_queries') and 0 or 1
        config.lsp[key] = math.min(math.max(normalize_nonnegative_integer(config.lsp[key], fallback), minimum), maximum)
    end
    if type(config.context) ~= 'table' then
        config.context = vim.deepcopy(defaults.context)
    end
    for _, key in ipairs { 'max_chars', 'evidence_max_chars', 'diagnostic_radius', 'max_diagnostics' } do
        config.context[key] = normalize_nonnegative_integer(config.context[key], defaults.context[key])
    end
    if type(config.context.related_files) ~= 'table' then
        config.context.related_files = vim.deepcopy(defaults.context.related_files)
    end
    if type(config.context.related_files.enabled) ~= 'boolean' then
        config.context.related_files.enabled = defaults.context.related_files.enabled
    end
    for _, key in ipairs { 'max_chars', 'max_files', 'per_file_max_chars' } do
        config.context.related_files[key] =
            normalize_nonnegative_integer(config.context.related_files[key], defaults.context.related_files[key])
    end
    if type(config.preview) ~= 'table' then
        config.preview = vim.deepcopy(defaults.preview)
    end
    local jump_text = config.preview.jump_text
    local placeholder_count = type(jump_text) == 'string' and select(2, jump_text:gsub('%%d', '')) or 0
    local valid_jump_text = placeholder_count == 1 and pcall(string.format, jump_text, 1)
    if not valid_jump_text then
        config.preview.jump_text = defaults.preview.jump_text
    end
    local cross_jump_text = config.preview.cross_jump_text
    local format_text = type(cross_jump_text) == 'string' and cross_jump_text:gsub('%%%%', '') or ''
    local string_count = select(2, format_text:gsub('%%s', ''))
    local integer_count = select(2, format_text:gsub('%%d', ''))
    local format_count = 0
    for _ in format_text:gmatch '%%[-+ #0]*%d*%.?%d*[aAcdeEfgGiouXxqs]' do
        format_count = format_count + 1
    end
    local valid_cross_jump_text = string_count == 1
        and integer_count == 1
        and format_count == 2
        and pcall(string.format, cross_jump_text, 'path.lua', 1)
    if not valid_cross_jump_text then
        config.preview.cross_jump_text = defaults.preview.cross_jump_text
    end
    local jump_sign = config.preview.jump_sign
    if
        type(jump_sign) ~= 'string'
        or jump_sign == ''
        or vim.fn.strdisplaywidth(jump_sign) < 1
        or vim.fn.strdisplaywidth(jump_sign) > 2
    then
        config.preview.jump_sign = defaults.preview.jump_sign
    end

    api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI', 'TextChangedP' }, {
        group = M.augroup,
        callback = function(info)
            controller.invalidate_buffer(info.buf, 'buffer_changed', 'duet')
        end,
        desc = '[minuet.duet] invalidate prediction on text change',
    })

    api.nvim_create_autocmd('BufLeave', {
        group = M.augroup,
        callback = function(info)
            local lease = controller.current()
            local state = state_for_lease(lease)
            if state and state.focusing and lease and info.buf == lease.origin_bufnr then
                return
            end
            controller.invalidate_buffer(info.buf, 'buffer_changed', 'duet')
        end,
        desc = '[minuet.duet] clear state on buffer leave',
    })

    api.nvim_create_autocmd('BufWipeout', {
        group = M.augroup,
        callback = function(info)
            controller.invalidate_buffer(info.buf, 'buffer_unloaded', 'duet')
            internal.states[info.buf] = nil
            symbols.invalidate(info.buf)
        end,
        desc = '[minuet.duet] clear state on buffer wipeout',
    })

    api.nvim_create_autocmd('DiagnosticChanged', {
        group = M.augroup,
        callback = function(info)
            local state = internal.states[info.buf]
            local candidate = state and state.candidate
            if not candidate or not state.lease then
                return
            end
            if
                vim.tbl_contains(candidate.metadata.sources or {}, 'diagnostic')
                and not candidates.exists(candidate, { semantic = state.semantic })
            then
                controller.invalidate(state.lease, 'context_changed')
            end
        end,
        desc = '[minuet.duet] invalidate prediction when its diagnostic candidate disappears',
    })

    edits.setup()
    symbols.reset()
    quality.reset()
    feedback.setup()
    scheduler.setup(predict)
end

return M
