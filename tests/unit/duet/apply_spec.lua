local helpers = require 'tests.helpers'

---@param overrides? table
---@param lines? string[]
---@return table
local function fixture(overrides, lines)
    helpers.setup_root_config(vim.tbl_deep_extend('force', {
        duet = {
            max_edit_lines = 40,
            max_edit_chars = 12000,
        },
    }, overrides or {}))
    local controller = helpers.reload 'minuet.suggestion'
    local apply = helpers.reload 'minuet.duet.apply'
    local bufnr = helpers.create_buffer(lines or { 'alpha' }, { 1, 0 })
    local lease = controller.begin {
        source = 'duet',
        intent = 'manual',
        bufnr = bufnr,
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
    }
    return {
        apply = apply,
        bufnr = bufnr,
        controller = controller,
        lease = lease,
    }
end

---@param f table
---@param proposed_lines string[]
---@param cursor? minuet.DuetParseCursor
---@return minuet.DuetEdit?, string?
local function prepare(f, proposed_lines, cursor)
    local original_lines = vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false)
    return f.apply.prepare({
        bufnr = f.bufnr,
        changedtick = vim.api.nvim_buf_get_changedtick(f.bufnr),
        range = { start_row = 0, end_row = #original_lines },
        original_lines = original_lines,
        proposed_lines = proposed_lines,
        cursor = cursor or { row_offset = 0, col = 0 },
    }, f.lease)
end

return {
    {
        name = 'duet.apply filters no-op cursor-only and whitespace-only edits',
        run = function()
            local f = fixture(nil, { '  alpha  ', 'beta' })
            local edit, reason = prepare(f, { '  alpha  ', 'beta' }, { row_offset = 1, col = 2 })
            helpers.expect_equal(edit, nil)
            helpers.expect_equal(reason, 'no_op')

            edit, reason = prepare(f, { 'alpha', '  beta  ' })
            helpers.expect_equal(edit, nil)
            helpers.expect_equal(reason, 'whitespace_only')

            edit = prepare(f, { '  alpha  ', 'gamma' })
            helpers.expect_truthy(edit)
            helpers.delete_buffer(f.bufnr)
        end,
    },
    {
        name = 'duet.apply computes changed lines and honors inclusive line limit',
        run = function()
            local f = fixture({ duet = { max_edit_lines = 1 } }, { 'one', 'two' })
            local edit, reason = prepare(f, { 'ONE', 'two' })
            helpers.expect_truthy(edit)
            helpers.expect_equal(edit.changed_lines, 1)

            edit, reason = prepare(f, { 'ONE', 'TWO' })
            helpers.expect_equal(edit, nil)
            helpers.expect_equal(reason, 'too_many_lines')
            helpers.delete_buffer(f.bufnr)
        end,
    },
    {
        name = 'duet.apply honors inclusive proposed byte limit',
        run = function()
            local f = fixture({ duet = { max_edit_chars = 4 } }, { 'a' })
            local edit = prepare(f, { 'bbbb' })
            helpers.expect_truthy(edit)
            helpers.expect_equal(edit.proposed_bytes, 4)
            require('minuet').config.duet.max_edit_chars = 3
            local rejected, reason = prepare(f, { 'bbbb' })
            helpers.expect_equal(rejected, nil)
            helpers.expect_equal(reason, 'too_many_bytes')
            helpers.delete_buffer(f.bufnr)
        end,
    },
    {
        name = 'duet.apply supports insertion replacement and deletion hunks',
        run = function()
            local f = fixture(nil, { 'one', 'two' })
            local inserted = prepare(f, { 'zero', 'one', 'two' })
            local replaced = prepare(f, { 'one', 'TWO' })
            local deleted = prepare(f, { 'one' })
            helpers.expect_truthy(inserted and #inserted.hunks > 0)
            helpers.expect_truthy(replaced and #replaced.hunks > 0)
            helpers.expect_truthy(deleted and #deleted.hunks > 0)
            helpers.delete_buffer(f.bufnr)
        end,
    },
    {
        name = 'duet.apply preflight rejects changedtick original range and wrong buffer',
        run = function()
            local f = fixture(nil, { 'alpha' })
            local edit = prepare(f, { 'bravo' })
            helpers.expect_truthy(edit)
            vim.api.nvim_buf_set_lines(f.bufnr, 0, -1, false, { 'changed' })
            helpers.expect_falsy(f.apply.preflight(edit, f.lease))

            edit.changedtick = vim.api.nvim_buf_get_changedtick(f.bufnr)
            helpers.expect_falsy(f.apply.preflight(edit, f.lease))

            local other = helpers.create_buffer({ 'other' }, { 1, 0 })
            helpers.expect_falsy(f.apply.preflight(edit, f.lease))
            helpers.delete_buffer(other)
            helpers.delete_buffer(f.bufnr)
        end,
    },
    {
        name = 'duet.apply rejects invalid unloaded nonmodifiable and out-of-range inputs',
        run = function()
            local f = fixture(nil, { 'alpha' })
            vim.bo[f.bufnr].modifiable = false
            local edit, reason = prepare(f, { 'bravo' })
            helpers.expect_equal(edit, nil)
            helpers.expect_equal(reason, 'stale')
            vim.bo[f.bufnr].modifiable = true

            edit, reason = f.apply.prepare({
                bufnr = f.bufnr,
                changedtick = vim.api.nvim_buf_get_changedtick(f.bufnr),
                range = { start_row = 0, end_row = 2 },
                original_lines = { 'alpha' },
                proposed_lines = { 'bravo' },
                cursor = { row_offset = 0, col = 0 },
            }, f.lease)
            helpers.expect_equal(edit, nil)
            helpers.expect_equal(reason, 'invalid')

            helpers.delete_buffer(f.bufnr)
            edit, reason = f.apply.prepare({
                bufnr = f.bufnr,
                changedtick = 1,
                range = { start_row = 0, end_row = 1 },
                original_lines = { 'alpha' },
                proposed_lines = { 'bravo' },
                cursor = { row_offset = 0, col = 0 },
            }, f.lease)
            helpers.expect_equal(edit, nil)
            helpers.expect_equal(reason, 'stale')
        end,
    },
    {
        name = 'duet.apply mutates once and clamps the cursor',
        run = function()
            local f = fixture(nil, { 'alpha' })
            local edit = prepare(f, { 'bravo', 'x' }, { row_offset = 99, col = 99 })
            helpers.expect_truthy(edit)
            f.controller.mark_visible(f.lease)
            f.controller.mark_accepting(f.lease)
            helpers.expect_truthy(f.apply.apply(edit, f.lease))
            helpers.expect_equal(vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false), { 'bravo', 'x' })
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 2, 0 })
            helpers.delete_buffer(f.bufnr)
        end,
    },
    {
        name = 'duet.apply does not report success when the buffer API fails',
        run = function()
            local f = fixture(nil, { 'alpha' })
            local edit = prepare(f, { 'bravo' })
            f.controller.mark_visible(f.lease)
            f.controller.mark_accepting(f.lease)
            local original = vim.api.nvim_buf_set_lines
            vim.api.nvim_buf_set_lines = function()
                error 'buffer write fixture failure'
            end
            local ok, reason = f.apply.apply(edit, f.lease)
            vim.api.nvim_buf_set_lines = original
            helpers.expect_falsy(ok)
            helpers.expect_equal(reason, 'buffer_write')
            helpers.expect_equal(vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false), { 'alpha' })
            helpers.delete_buffer(f.bufnr)
        end,
    },
    {
        name = 'duet.apply creates a separate undo unit from the preceding user edit',
        run = function()
            local f = fixture(nil, { 'alpha' })
            vim.bo[f.bufnr].undolevels = -1
            vim.bo[f.bufnr].undolevels = 1000
            local keys = vim.api.nvim_replace_termcodes('A-user<C-g>u<Esc>', true, false, true)
            vim.api.nvim_feedkeys(keys, 'xt', false)
            local before_suggestion = vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false)
            local edit = prepare(f, { 'alpha-user-model' }, { row_offset = 0, col = 16 })
            f.controller.mark_visible(f.lease)
            f.controller.mark_accepting(f.lease)
            helpers.expect_truthy(f.apply.apply(edit, f.lease))

            vim.cmd 'undo'
            helpers.expect_equal(vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false), before_suggestion)
            vim.cmd 'undo'
            helpers.expect_equal(vim.api.nvim_buf_get_lines(f.bufnr, 0, -1, false), { 'alpha' })
            helpers.delete_buffer(f.bufnr)
        end,
    },
    {
        name = 'duet.apply prepares a hidden lease target but writes only after focus',
        run = function()
            local f = fixture(nil, { 'origin' })
            local target = vim.api.nvim_create_buf(true, true)
            vim.bo[target].buftype = ''
            vim.api.nvim_buf_set_lines(target, 0, -1, false, { 'target' })
            f.lease.target_bufnr = target
            f.lease.target_changedtick = vim.api.nvim_buf_get_changedtick(target)
            f.lease.cross_buffer = true
            local edit = f.apply.prepare({
                bufnr = target,
                changedtick = f.lease.target_changedtick,
                range = { start_row = 0, end_row = 1 },
                original_lines = { 'target' },
                proposed_lines = { 'changed' },
                cursor = { row_offset = 0, col = 7 },
            }, f.lease)
            helpers.expect_truthy(edit)
            f.controller.mark_visible(f.lease)
            f.controller.mark_accepting(f.lease)
            helpers.expect_falsy(f.apply.apply(edit, f.lease))
            helpers.expect_equal(vim.api.nvim_buf_get_lines(target, 0, -1, false), { 'target' })

            vim.api.nvim_set_current_buf(target)
            helpers.expect_truthy(f.apply.apply(edit, f.lease))
            helpers.expect_equal(vim.api.nvim_buf_get_lines(target, 0, -1, false), { 'changed' })
            helpers.delete_buffer(target)
            helpers.delete_buffer(f.bufnr)
        end,
    },
}
