local M = {}

---@param deps table
---@return table
function M.new(deps)
    local api = deps.api
    local state_store = deps.state

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
            not deps.guards.is_safe_buffer(lease.target_bufnr, true, config.auto_trigger.max_buffer_size)
            or not vim.bo[lease.target_bufnr].modifiable
            or type(lease.workspace_root) ~= 'string'
            or deps.guards.relative_path(lease.workspace_root, api.nvim_buf_get_name(lease.origin_bufnr)) == nil
        then
            return false
        end
        local target_path = deps.guards.relative_path(lease.workspace_root, api.nvim_buf_get_name(lease.target_bufnr))
        return target_path ~= nil and target_path == lease.target_path
    end

    ---@param lease minuet.SuggestionLease
    ---@param reason string
    local function cancel_lease(lease, reason)
        local state_bufnr = lease.state_bufnr or lease.bufnr
        local state = state_store.states()[state_bufnr]
        if not state or state.lease ~= lease then
            return
        end

        local classified_reason = stale_reason(reason)
        local request = state.pending_request
        if request and request.lease == lease then
            request.invalid_reason = classified_reason
            if request.has_result and not request.dismissed then
                deps.metrics.suggestion_event(request.cycle_id, 'stale', classified_reason)
            end
            require('minuet.duet.backends.common').terminate_cycle(request.cycle_id)
        end
        if state.cycle_id then
            deps.metrics.suggestion_event(state.cycle_id, 'stale', classified_reason)
        end
        state_store.clear(state_bufnr, state)
    end

    ---@param lease minuet.SuggestionLease
    local function dismiss_lease(lease)
        local state_bufnr = lease.state_bufnr or lease.bufnr
        local state = state_store.states()[state_bufnr]
        if not state or state.lease ~= lease then
            return
        end

        local request = state.pending_request
        if request and request.lease == lease then
            request.dismissed = true
            deps.metrics.suggestion_event(request.cycle_id, 'dismissed')
            require('minuet.duet.backends.common').terminate_cycle(request.cycle_id)
        end
        if state.cycle_id then
            deps.metrics.suggestion_event(state.cycle_id, 'dismissed')
        end
        local current_tick = api.nvim_buf_is_valid(lease.target_bufnr)
                and api.nvim_buf_get_changedtick(lease.target_bufnr)
            or lease.target_changedtick
        deps.scheduler.dismissed(lease.target_bufnr, current_tick)
        state_store.clear(state_bufnr, state)
    end

    ---@param lease minuet.SuggestionLease
    ---@param edit minuet.DuetEdit
    ---@return boolean
    local function perform_apply(lease, edit)
        local state_bufnr = lease.state_bufnr or lease.bufnr
        local state = state_store.states()[state_bufnr]
        if not state or state.lease ~= lease or state.edit ~= edit then
            return false
        end

        local applied = anchors_valid(lease) and deps.apply.apply(edit, lease)
        if not applied then
            if state.cycle_id then
                deps.metrics.suggestion_event(state.cycle_id, 'stale', 'apply_validation')
            end
            deps.controller.finish(lease, 'stale', 'apply_validation')
            state_store.clear(state_bufnr, state)
            return false
        end

        local cycle_id = state.cycle_id
        if cycle_id then
            deps.metrics.suggestion_event(cycle_id, 'accepted')
            deps.feedback.track_accept(cycle_id, edit.bufnr)
        end
        deps.controller.finish(lease, 'accepted')
        state_store.clear(state_bufnr, state)
        deps.scheduler.after_accept(edit.bufnr)
        return true
    end

    ---Focus a remote edit without changing the buffer or completing its lifecycle.
    ---@param lease minuet.SuggestionLease
    ---@param edit minuet.DuetEdit
    ---@return boolean
    local function focus_remote_edit(lease, edit)
        local state_bufnr = lease.state_bufnr or lease.bufnr
        local state = state_store.states()[state_bufnr]
        if
            not state
            or state.lease ~= lease
            or state.edit ~= edit
            or not deps.apply.preflight(edit, lease)
            or type(lease.target_row) ~= 'number'
            or type(lease.target_col) ~= 'number'
            or not anchors_valid(lease)
        then
            deps.controller.invalidate(lease, 'apply_validation')
            return false
        end

        if lease.cross_buffer then
            if api.nvim_get_current_buf() ~= lease.origin_bufnr then
                deps.controller.invalidate(lease, 'apply_validation')
                return false
            end
            state.focusing = true
            local switched = pcall(vim.cmd, ('hide buffer %d'):format(lease.target_bufnr))
            state.focusing = false
            if not switched or api.nvim_get_current_buf() ~= lease.target_bufnr then
                deps.controller.invalidate(lease, 'apply_validation')
                return false
            end
        end

        local focused = pcall(api.nvim_win_set_cursor, 0, { lease.target_row + 1, lease.target_col })
        if not focused then
            deps.controller.invalidate(lease, 'apply_validation')
            return false
        end

        lease.jumped = true
        lease.jump_required = false
        state.jump_required = false
        deps.preview.render(edit.bufnr, state, edit)
        if not deps.preview.is_visible(edit.bufnr, state) or not deps.controller.resume_visible(lease) then
            deps.controller.invalidate(lease, 'apply_validation')
            return false
        end
        return true
    end

    return {
        anchors_valid = anchors_valid,
        cancel = cancel_lease,
        dismiss = dismiss_lease,
        perform_apply = perform_apply,
        focus_remote_edit = focus_remote_edit,
    }
end

return M
