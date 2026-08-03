local helpers = require 'tests.helpers'

local function setup_feedback(overrides)
    helpers.setup_root_config {
        duet = {
            quality = vim.tbl_deep_extend('force', {
                undo_window = 10000,
                max_pending_undo = 64,
            }, overrides or {}),
        },
    }
    local metrics = helpers.reload 'minuet.metrics'
    metrics._reset()
    metrics.setup { enabled = true }
    local feedback = helpers.reload 'minuet.duet.feedback'
    feedback.setup()
    local bufnr = helpers.create_buffer({ 'before' }, { 1, 0 })
    vim.bo[bufnr].undolevels = -1
    vim.bo[bufnr].undolevels = 1000
    return feedback, metrics, bufnr
end

local function cycle(metrics)
    local cycle_id = metrics.begin_cycle {
        channel = 'duet',
        frontend = 'duet',
        provider_id = 'openai_compatible',
    }
    metrics.suggestion_event(cycle_id, 'preview_shown')
    metrics.suggestion_event(cycle_id, 'accepted')
    return cycle_id
end

return {
    {
        name = 'duet feedback counts an accepted edit only when undo crosses its sequence',
        run = function()
            local feedback, metrics, bufnr = setup_feedback()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'suggestion' })
            feedback.track_accept(cycle(metrics), bufnr)

            local keys = vim.api.nvim_replace_termcodes('A later user edit<C-g>u<Esc>', true, false, true)
            vim.api.nvim_feedkeys(keys, 'xt', false)
            vim.cmd 'undo'
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
            helpers.expect_equal(metrics.get().channels.duet.cycles.reverted, 0)

            vim.cmd 'undo'
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
            helpers.expect_equal(metrics.get().channels.duet.cycles.reverted, 1)
            helpers.expect_equal(feedback._inspect().count, 0)
            helpers.delete_buffer(bufnr)
            feedback.reset()
            metrics._reset()
        end,
    },
    {
        name = 'duet feedback expires and bounds pending undo observations',
        run = function()
            local feedback, metrics, bufnr = setup_feedback { undo_window = 1, max_pending_undo = 2 }
            for index = 1, 3 do
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'suggestion ' .. index })
                feedback.track_accept(cycle(metrics), bufnr)
            end
            helpers.expect_equal(feedback._inspect().count, 2)
            vim.wait(10)
            helpers.expect_equal(feedback._inspect().count, 0)
            helpers.delete_buffer(bufnr)
            feedback.reset()
            metrics._reset()
        end,
    },
}
