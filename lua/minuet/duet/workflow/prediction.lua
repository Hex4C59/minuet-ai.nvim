local M = {}

---@param deps table
---@return table
function M.new(deps)
    local api = deps.api
    local state_store = deps.state

    ---@return string
    local function current_provider()
        return require('minuet').config.duet.provider
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
            deps.utils.notify('Minuet duet provider is not supported: ' .. provider_name, 'error', vim.log.levels.ERROR)
            return false
        end

        local changedtick = api.nvim_buf_get_changedtick(bufnr)
        local lease = deps.controller.begin {
            source = 'duet',
            intent = intent,
            bufnr = bufnr,
            changedtick = changedtick,
        }
        if not lease then
            return false
        end

        local state = state_store.get(bufnr)
        state_store.clear(bufnr, state)
        state.lease = lease

        deps.controller.attach(lease, {
            cancel = function(reason)
                deps.lifecycle.cancel(lease, reason)
            end,
            can_accept = function()
                if state.lease ~= lease or not deps.preview.is_visible(bufnr, state) then
                    return false, 'apply_validation'
                end
                if not deps.lifecycle.anchors_valid(lease) then
                    return false, 'apply_validation'
                end
                local expected_bufnr = lease.jumped and lease.target_bufnr or lease.origin_bufnr
                if api.nvim_get_current_buf() ~= expected_bufnr then
                    return false, 'apply_validation'
                end
                return deps.apply.preflight(state.edit, lease)
            end,
            accept = function()
                local edit = state.edit
                if not edit then
                    deps.lifecycle.cancel(lease, 'apply_validation')
                    return
                end
                if lease.jump_required and not lease.jumped then
                    deps.lifecycle.focus_remote_edit(lease, edit)
                    return
                end
                vim.schedule(function()
                    deps.lifecycle.perform_apply(lease, edit)
                end)
            end,
            dismiss = function(_, explicit)
                if explicit then
                    deps.lifecycle.dismiss(lease)
                else
                    deps.lifecycle.cancel(lease, 'apply_validation')
                end
            end,
            is_visible = function()
                return state.lease == lease and deps.preview.is_visible(bufnr, state)
            end,
        })

        deps.edits.ensure_setup()
        deps.edits.flush(bufnr, { wait = true })
        if
            not deps.controller.is_current(lease)
            or bufnr ~= api.nvim_get_current_buf()
            or api.nvim_buf_get_changedtick(bufnr) ~= changedtick
        then
            deps.controller.invalidate(lease, 'buffer_changed')
            return false
        end

        ---@param semantic minuet.DuetSemanticContext
        ---@return boolean
        local function continue_prediction(semantic)
            if
                not deps.controller.is_current(lease)
                or bufnr ~= api.nvim_get_current_buf()
                or api.nvim_buf_get_changedtick(bufnr) ~= changedtick
            then
                deps.controller.invalidate(lease, 'buffer_changed')
                return false
            end
            state.semantic_cancel = nil
            state.semantic = semantic
            local origin = api.nvim_win_get_cursor(0)
            local candidate = deps.candidates.select(bufnr, { semantic = semantic })
            if not candidate then
                deps.controller.release(lease)
                state_store.clear(bufnr, state)
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
                deps.controller.release(lease)
                state_store.clear(bufnr, state)
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
                local root = deps.guards.workspace_path(bufnr)
                local target_path = root and deps.guards.relative_path(root, api.nvim_buf_get_name(target_bufnr)) or nil
                if not root or not target_path then
                    deps.controller.release(lease)
                    state_store.clear(bufnr, state)
                    return false
                end
                lease.workspace_root = root
                lease.target_path = target_path
            end

            local built, current_context = pcall(deps.context.build, target_bufnr, candidate, semantic)
            if not built or type(current_context) ~= 'table' then
                deps.controller.release(lease)
                state_store.clear(bufnr, state)
                deps.utils.notify('Failed to build duet context.', 'error', vim.log.levels.ERROR)
                return false
            end

            local request_seq = state_store.next_request_seq()
            local cycle_id = deps.metrics.begin_cycle {
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

            deps.utils.notify('Minuet duet started', 'verbose', vim.log.levels.INFO)
            deps.scheduler.note_request_started()

            local called = pcall(backend.complete, current_context, function(text)
                local has_text = type(text) == 'string' and text ~= ''
                if has_text then
                    request.has_result = true
                    deps.metrics.cycle_has_result(cycle_id)
                end

                vim.schedule(function()
                    if request.dismissed then
                        return
                    end
                    if not api.nvim_buf_is_loaded(bufnr) or not api.nvim_buf_is_loaded(target_bufnr) then
                        request.invalid_reason = 'buffer_unloaded'
                        if has_text then
                            deps.metrics.suggestion_event(cycle_id, 'stale', 'buffer_unloaded')
                        end
                        deps.controller.finish(lease, 'stale', 'buffer_unloaded')
                        if state.lease == lease then
                            state_store.clear(bufnr, state)
                        end
                        return
                    end
                    if
                        state.pending_seq ~= request_seq
                        or state.pending_request ~= request
                        or state.lease ~= lease
                        or not deps.controller.is_current(lease)
                    then
                        if has_text then
                            deps.metrics.suggestion_event(cycle_id, 'stale', request.invalid_reason or 'superseded')
                        end
                        return
                    end

                    state.pending_seq = nil
                    state.pending_request = nil
                    if not has_text then
                        deps.controller.release(lease)
                        state_store.clear(bufnr, state)
                        return
                    end
                    if
                        bufnr ~= api.nvim_get_current_buf()
                        or api.nvim_buf_get_changedtick(bufnr) ~= changedtick
                        or api.nvim_buf_get_changedtick(target_bufnr) ~= current_context.changedtick
                        or not deps.candidates.exists(candidate, { semantic = semantic, origin_bufnr = bufnr })
                    then
                        deps.metrics.suggestion_event(cycle_id, 'stale', 'buffer_changed')
                        deps.controller.finish(lease, 'stale', 'buffer_changed')
                        state_store.clear(bufnr, state)
                        return
                    end

                    local parsed, _, parse_reason = deps.utils.parse_duet_response(text, current_context)
                    if not parsed then
                        deps.metrics.suggestion_event(cycle_id, 'parse_failed', parse_reason or 'invalid_markers')
                        deps.controller.release(lease)
                        state_store.clear(bufnr, state)
                        deps.utils.notify(
                            'Minuet duet response has invalid editable-region markers.',
                            'warn',
                            vim.log.levels.WARN
                        )
                        return
                    end

                    local edit, filter_reason = deps.apply.prepare({
                        bufnr = target_bufnr,
                        changedtick = current_context.changedtick,
                        range = current_context.range,
                        original_lines = current_context.original_lines,
                        proposed_lines = parsed.lines,
                        cursor = parsed.cursor,
                    }, lease)
                    if not edit then
                        if filter_reason == 'stale' or filter_reason == 'invalid' then
                            deps.metrics.suggestion_event(cycle_id, 'stale', 'buffer_changed')
                            deps.controller.finish(lease, 'stale', 'buffer_changed')
                        else
                            deps.metrics.suggestion_event(cycle_id, 'filtered', filter_reason)
                            deps.controller.release(lease)
                        end
                        state_store.clear(bufnr, state)
                        return
                    end
                    if deps.quality.is_repeat(edit) then
                        deps.metrics.suggestion_event(cycle_id, 'filtered', 'repeat')
                        deps.controller.release(lease)
                        state_store.clear(bufnr, state)
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
                        if not deps.lifecycle.anchors_valid(lease) then
                            deps.metrics.suggestion_event(cycle_id, 'stale', 'buffer_changed')
                            deps.controller.finish(lease, 'stale', 'buffer_changed')
                            state_store.clear(bufnr, state)
                            return
                        end
                        deps.preview.render_cross_jump(
                            bufnr,
                            target_bufnr,
                            state,
                            state.origin_row,
                            target_row,
                            deps.guards.safe_label(lease.target_path)
                        )
                    elseif jump_required then
                        deps.preview.render_jump(bufnr, state, state.origin_row, target_row)
                    else
                        deps.preview.render(target_bufnr, state, edit)
                    end
                    if deps.preview.is_visible(bufnr, state) then
                        deps.metrics.suggestion_event(cycle_id, 'preview_shown')
                        if not deps.controller.mark_visible(lease) then
                            state_store.clear(bufnr, state)
                        end
                    else
                        deps.controller.release(lease)
                        state_store.clear(bufnr, state)
                    end
                end)
            end, {
                cycle_id = cycle_id,
                frontend = 'duet',
            })

            if not called then
                deps.controller.release(lease)
                state_store.clear(bufnr, state)
                deps.utils.notify('Failed to start duet request.', 'error', vim.log.levels.ERROR)
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
        local semantic_cancel = deps.symbols.collect(bufnr, function(semantic)
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

    return {
        predict = predict,
    }
end

return M
