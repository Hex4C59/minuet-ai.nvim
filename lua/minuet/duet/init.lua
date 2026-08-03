local api = vim.api
local apply = require 'minuet.duet.apply'
local candidates = require 'minuet.duet.candidates'
local context = require 'minuet.duet.context'
local controller = require 'minuet.suggestion'
local edits = require 'minuet.duet.edits'
local feedback = require 'minuet.duet.undo_feedback'
local guards = require 'minuet.duet.guards'
local metrics = require 'minuet.metrics'
local preview = require 'minuet.duet.preview'
local quality = require 'minuet.duet.repeat_suppression'
local scheduler = require 'minuet.duet.scheduler'
local symbols = require 'minuet.duet.symbols'
local utils = require 'minuet.duet.utils'
local workflow_state = require 'minuet.duet.workflow.state'
local workflow_lifecycle = require 'minuet.duet.workflow.lifecycle'
local workflow_prediction = require 'minuet.duet.workflow.prediction'

local M = {}

M.augroup = api.nvim_create_augroup('MinuetDuet', { clear = true })

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

local state_store = workflow_state.new(preview)
local lifecycle = workflow_lifecycle.new {
    api = api,
    state = state_store,
    apply = apply,
    controller = controller,
    feedback = feedback,
    guards = guards,
    metrics = metrics,
    preview = preview,
    scheduler = scheduler,
}
local prediction = workflow_prediction.new {
    api = api,
    apply = apply,
    candidates = candidates,
    context = context,
    controller = controller,
    edits = edits,
    guards = guards,
    lifecycle = lifecycle,
    metrics = metrics,
    preview = preview,
    quality = quality,
    scheduler = scheduler,
    state = state_store,
    symbols = symbols,
    utils = utils,
}

local action = {}

function action.predict()
    return prediction.predict 'manual'
end

function action.apply()
    local lease = controller.current()
    local state = state_store.for_lease(lease)
    if
        not lease
        or not state
        or lease.source ~= 'duet'
        or lease.phase ~= 'visible'
        or not state.edit
        or not lifecycle.anchors_valid(lease)
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
        return lifecycle.focus_remote_edit(lease, state.edit)
    end
    return lifecycle.perform_apply(lease, state.edit)
end

function action.dismiss()
    local lease = controller.current()
    local state = state_store.for_lease(lease)
    if state and state.lease == lease and lease.source == 'duet' then
        return controller.dismiss(lease)
    end
    return false
end

function action.is_visible()
    local lease = controller.current()
    local state = state_store.for_lease(lease)
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
    state_store.clear_all()

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
            local state = state_store.for_lease(lease)
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
            state_store.drop(info.buf)
            symbols.invalidate(info.buf)
        end,
        desc = '[minuet.duet] clear state on buffer wipeout',
    })

    api.nvim_create_autocmd('DiagnosticChanged', {
        group = M.augroup,
        callback = function(info)
            local state = state_store.states()[info.buf]
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
    scheduler.setup(prediction.predict)
end

return M
