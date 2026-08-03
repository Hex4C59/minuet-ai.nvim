local helpers = require 'tests.helpers'

---@param run fun(fixture: table)
local function with_cross_buffer(run)
    local original_hidden = vim.o.hidden
    helpers.setup_root_config {
        duet = {
            provider = 'cross_buffer_test',
            scope = 'workspace',
            candidates = {
                cursor = false,
                recent_edits = false,
                diagnostics = false,
                references = true,
                text = false,
                related_buffers = true,
                max_candidates = 8,
            },
            editable_region = { lines_before = 0, lines_after = 0 },
            recent_edits = { enabled = false },
            auto_trigger = { enabled = false },
            preview = {
                cursor = '|',
                cross_jump_text = 'Next edit: %s:%d',
                jump_sign = '>>',
            },
        },
    }
    local requests = {}
    local origin = helpers.create_buffer({ 'local origin = true' }, { 1, 0 })
    vim.bo[origin].buftype = ''
    vim.bo[origin].bufhidden = ''
    vim.api.nvim_buf_set_name(origin, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-origin.lua'))
    vim.bo[origin].modified = true
    local target = helpers.create_buffer({ 'local target = 1' }, { 1, 0 })
    vim.bo[target].buftype = ''
    vim.bo[target].bufhidden = ''
    vim.bo[target].undolevels = -1
    vim.bo[target].undolevels = 1000
    vim.api.nvim_buf_set_name(target, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-target.lua'))
    vim.bo[target].modified = false
    vim.api.nvim_set_current_buf(origin)
    vim.o.hidden = false
    vim.cmd 'clearjumps'

    package.loaded['minuet.duet.symbols'] = {
        collect = function(_, callback, options)
            helpers.expect_equal(options.related_buffers, true)
            callback {
                bufnr = origin,
                changedtick = vim.api.nvim_buf_get_changedtick(origin),
                identifiers = { 'target' },
                references = {},
                related_references = {
                    { bufnr = target, row = 0, col = 6, path = 'tests/cross-target.lua', name = 'target' },
                },
                text_matches = {},
                definitions = {},
                symbols = {},
                timed_out = false,
            }
            return function() end
        end,
        reset = function() end,
        invalidate = function() end,
    }
    package.loaded['minuet.duet.backends.cross_buffer_test'] = {
        complete = function(context, callback)
            requests[#requests + 1] = { context = context, callback = callback }
        end,
    }

    local duet = helpers.reload 'minuet.duet'
    duet.setup()
    local ok, err = xpcall(function()
        run {
            duet = duet,
            origin = origin,
            target = target,
            requests = requests,
            tab = helpers.reload 'minuet.tab',
        }
    end, debug.traceback)

    pcall(vim.api.nvim_clear_autocmds, { group = duet.augroup })
    pcall(function()
        require('minuet.duet.scheduler').reset()
    end)
    vim.o.hidden = original_hidden
    helpers.delete_buffer(target)
    helpers.delete_buffer(origin)
    package.loaded['minuet.duet.backends.cross_buffer_test'] = nil
    if not ok then
        error(err)
    end
end

local function show_cross_preview(fixture)
    helpers.expect_truthy(fixture.duet.action.predict())
    helpers.expect_equal(#fixture.requests, 1)
    helpers.expect_equal(fixture.requests[1].context.bufnr, fixture.target)
    helpers.expect_equal(fixture.requests[1].context.original_lines, { 'local target = 1' })
    helpers.expect_equal(vim.api.nvim_get_current_buf(), fixture.origin)
    helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 0 })
    fixture.requests[1].callback [[<editable_region>
local target = 2<cursor_position/>
</editable_region>]]
    helpers.wait_until(function()
        return fixture.duet.action.is_visible()
    end, 500)
end

return {
    {
        name = 'cursor tab cross-buffer edit jumps then applies once with undo and jumplist return',
        run = function()
            with_cross_buffer(function(fixture)
                show_cross_preview(fixture)
                local preview = require 'minuet.duet.preview'
                local origin_marks =
                    vim.api.nvim_buf_get_extmarks(fixture.origin, preview.ns_id, 0, -1, { details = true })
                local target_marks =
                    vim.api.nvim_buf_get_extmarks(fixture.target, preview.ns_id, 0, -1, { details = true })
                helpers.expect_match(vim.inspect(origin_marks), 'Next edit: tests/cross%-target.lua:1')
                helpers.expect_match(vim.inspect(target_marks), 'sign_text = ">>"')
                helpers.expect_falsy(vim.inspect(target_marks):find('local target = 2', 1, true))

                helpers.expect_truthy(fixture.tab.accept())
                helpers.expect_equal(vim.api.nvim_get_current_buf(), fixture.target)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.target, 0, -1, false), { 'local target = 1' })
                helpers.expect_equal(require('minuet.suggestion').current().phase, 'visible')
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.accepted, 0)
                local jumps = vim.fn.getjumplist()[1]
                helpers.expect_truthy(vim.tbl_contains(
                    vim.tbl_map(function(item)
                        return item.bufnr
                    end, jumps),
                    fixture.origin
                ))

                helpers.expect_truthy(fixture.tab.accept())
                helpers.wait_until(function()
                    return vim.api.nvim_buf_get_lines(fixture.target, 0, -1, false)[1] == 'local target = 2'
                end, 500)
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.accepted, 1)
                helpers.expect_equal(require('minuet.suggestion').current(), nil)

                vim.cmd 'undo'
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.target, 0, -1, false), { 'local target = 1' })
                vim.api.nvim_exec_autocmds('TextChanged', { buffer = fixture.target })
                helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.reverted, 1)
                vim.cmd 'normal! \15'
                helpers.expect_equal(vim.api.nvim_get_current_buf(), fixture.origin)
            end)
        end,
    },
    {
        name = 'cursor tab cross-buffer dismiss before and after jump never writes either buffer',
        run = function()
            with_cross_buffer(function(fixture)
                show_cross_preview(fixture)
                helpers.expect_truthy(fixture.duet.action.dismiss())
                helpers.expect_equal(vim.api.nvim_get_current_buf(), fixture.origin)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.target, 0, -1, false), { 'local target = 1' })
            end)
            with_cross_buffer(function(fixture)
                show_cross_preview(fixture)
                helpers.expect_truthy(fixture.tab.accept())
                helpers.expect_truthy(fixture.duet.action.dismiss())
                helpers.expect_equal(vim.api.nvim_get_current_buf(), fixture.target)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.target, 0, -1, false), { 'local target = 1' })
            end)
        end,
    },
    {
        name = 'cursor tab cross-buffer target changes fence the active suggestion',
        run = function()
            with_cross_buffer(function(fixture)
                show_cross_preview(fixture)
                vim.api.nvim_buf_set_lines(fixture.target, 0, 1, false, { 'local target = 99' })
                vim.api.nvim_exec_autocmds('TextChanged', { buffer = fixture.target })
                helpers.expect_equal(require('minuet.suggestion').current(), nil)
                helpers.expect_falsy(fixture.duet.action.is_visible())
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.target, 0, -1, false), {
                    'local target = 99',
                })
            end)
        end,
    },
    {
        name = 'cursor tab cross-buffer path identity changes fence the active suggestion',
        run = function()
            with_cross_buffer(function(fixture)
                show_cross_preview(fixture)
                vim.api.nvim_buf_set_name(
                    fixture.target,
                    vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-target-renamed.lua')
                )
                helpers.expect_falsy(fixture.duet.action.apply())
                helpers.expect_equal(require('minuet.suggestion').current(), nil)
                helpers.expect_equal(vim.api.nvim_get_current_buf(), fixture.origin)
                helpers.expect_equal(vim.api.nvim_buf_get_lines(fixture.target, 0, -1, false), {
                    'local target = 1',
                })
            end)
        end,
    },
}
