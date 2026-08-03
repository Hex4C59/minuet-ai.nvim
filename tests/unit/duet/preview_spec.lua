local helpers = require 'tests.helpers'

local function get_extmarks(bufnr, ns_id)
    return vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
end

return {
    {
        name = 'duet.preview does not render a cursor-only edit',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'alpha', 'beta' }, { 1, 0 })
            local state = {}
            local edit = {
                range = {
                    start_row = 0,
                    end_row = 2,
                },
                original_lines = { 'alpha', 'beta' },
                proposed_lines = { 'alpha', 'beta' },
                cursor = {
                    row_offset = 1,
                    col = 2,
                },
                hunks = {},
            }

            preview.render(bufnr, state, edit)

            helpers.expect_equal(get_extmarks(bufnr, preview.ns_id), {})
            helpers.expect_falsy(preview.is_visible(bufnr, state))

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview renders inserted lines as virtual lines',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 0 })
            local state = {}
            local edit = {
                range = {
                    start_row = 0,
                    end_row = 1,
                },
                original_lines = { 'alpha' },
                proposed_lines = { 'alpha', 'bravo' },
                cursor = {
                    row_offset = 1,
                    col = 3,
                },
            }
            edit.hunks = require('minuet.duet.apply').compute_hunks(edit.original_lines, edit.proposed_lines)

            preview.render(bufnr, state, edit)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            helpers.expect_equal(#extmarks, 1)
            helpers.expect_equal(extmarks[1][4].virt_lines, {
                {
                    { 'bra', 'MinuetDuetAdd' },
                    { '|', 'MinuetDuetCursor' },
                    { 'vo', 'MinuetDuetAdd' },
                },
            })
            helpers.expect_truthy(preview.is_visible(bufnr, state))

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview renders and clears an ASCII remote jump hint and target sign',
        run = function()
            helpers.setup_root_config {
                duet = {
                    preview = {
                        jump_text = 'Next edit: line %d',
                        jump_sign = '>>',
                    },
                },
            }

            local preview = helpers.reload 'minuet.duet.preview'
            local bufnr = helpers.create_buffer({ 'one', 'two', 'three', 'four', 'five' }, { 1, 0 })
            local state = {}

            preview.render_jump(bufnr, state, 0, 4)

            local extmarks = get_extmarks(bufnr, preview.ns_id)
            helpers.expect_equal(#extmarks, 2)
            helpers.expect_equal(extmarks[1][2], 0)
            helpers.expect_equal(extmarks[1][4].virt_text, { { 'Next edit: line 5', 'MinuetDuetJump' } })
            helpers.expect_equal(extmarks[2][2], 4)
            helpers.expect_equal(extmarks[2][4].sign_text, '>>')
            helpers.expect_equal(extmarks[2][4].sign_hl_group, 'MinuetDuetJump')
            helpers.expect_equal(state.preview_kind, 'jump')
            helpers.expect_truthy(preview.is_visible(bufnr, state))

            preview.clear(bufnr, state)
            helpers.expect_equal(get_extmarks(bufnr, preview.ns_id), {})
            helpers.expect_equal(state.preview_kind, nil)
            helpers.expect_falsy(preview.is_visible(bufnr, state))
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.preview renders and clears a cross-buffer hint and hidden target sign',
        run = function()
            helpers.setup_root_config()
            local preview = helpers.reload 'minuet.duet.preview'
            local origin = helpers.create_buffer({ 'origin' }, { 1, 0 })
            local target = helpers.create_buffer({ 'one', 'two' }, { 1, 0 })
            vim.api.nvim_set_current_buf(origin)
            local state = {}
            local original_width = vim.api.nvim_win_get_width(0)
            vim.api.nvim_win_set_width(0, 40)

            preview.render_cross_jump(origin, target, state, 0, 1, string.rep('segment/', 20) .. 'target.lua')

            local origin_marks = get_extmarks(origin, preview.ns_id)
            local target_marks = get_extmarks(target, preview.ns_id)
            local message = origin_marks[1][4].virt_text[1][1]
            helpers.expect_truthy(vim.fn.strdisplaywidth(message) <= math.max(vim.api.nvim_win_get_width(0) - 4, 12))
            helpers.expect_match(message, '^%.%.%.')
            helpers.expect_match(message, 'target%.lua:2$')
            helpers.expect_equal(target_marks[1][4].sign_text, '>>')
            helpers.expect_equal(state.preview_kind, 'cross_jump')
            helpers.expect_truthy(preview.is_visible(origin, state))

            preview.clear(origin, state)
            helpers.expect_equal(get_extmarks(origin, preview.ns_id), {})
            helpers.expect_equal(get_extmarks(target, preview.ns_id), {})
            vim.api.nvim_win_set_width(0, original_width)
            helpers.delete_buffer(target)
            helpers.delete_buffer(origin)
        end,
    },
}
