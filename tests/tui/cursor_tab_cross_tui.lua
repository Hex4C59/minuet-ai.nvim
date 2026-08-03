local helpers = require 'tests.helpers'

helpers.setup_root_config {
    duet = {
        provider = 'cross_tui_test',
        scope = 'workspace',
        candidates = {
            cursor = false,
            recent_edits = false,
            diagnostics = false,
            references = true,
            text = false,
            related_buffers = true,
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

vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = 'yes'
vim.o.wrap = false
vim.o.laststatus = 2
vim.o.showmode = false
vim.o.background = vim.env.MINUET_TUI_BACKGROUND == 'light' and 'light' or 'dark'

local origin = helpers.create_buffer({ 'local origin = true' }, { 1, 0 })
vim.bo[origin].buftype = ''
vim.api.nvim_buf_set_name(origin, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-tui-origin.lua'))
local target = helpers.create_buffer({ 'local target = 1' }, { 1, 0 })
vim.bo[target].buftype = ''
vim.bo[target].undolevels = -1
vim.bo[target].undolevels = 1000
vim.api.nvim_buf_set_name(target, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-tui-target.lua'))
vim.bo[target].modified = false
vim.api.nvim_set_current_buf(origin)
vim.cmd 'clearjumps'

package.loaded['minuet.duet.symbols'] = {
    collect = function(_, callback)
        callback {
            identifiers = { 'target' },
            references = {},
            related_references = {
                { bufnr = target, row = 0, col = 6, path = 'tests/cross-tui-target.lua', name = 'target' },
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

local callback
package.loaded['minuet.duet.backends.cross_tui_test'] = {
    complete = function(_, complete)
        callback = complete
    end,
}

local duet = helpers.reload 'minuet.duet'
duet.setup()
assert(duet.action.predict(), 'cross TUI prediction did not start')
assert(callback, 'cross TUI backend callback was not captured')
callback [[<editable_region>
local target = 2<cursor_position/>
</editable_region>]]
helpers.wait_until(function()
    return duet.action.is_visible()
end, 500, 'cross TUI jump preview did not become visible')

local function visible_text()
    vim.cmd 'redraw'
    local rows = {}
    for row = 1, math.min(vim.o.lines - 2, 12) do
        local cells = {}
        for col = 1, vim.o.columns do
            cells[col] = vim.fn.screenstring(row, col)
        end
        rows[row] = table.concat(cells)
    end
    return table.concat(rows, '\n')
end

local initial_screen = visible_text()
assert(initial_screen:find('Next edit: tests/cross-tui-target.lua:1', 1, true), 'cross-buffer hint is not visible')
assert(not initial_screen:find('local target = 2', 1, true), 'target diff leaked before cross-buffer focus')
local preview = require 'minuet.duet.preview'
local target_marks = vim.api.nvim_buf_get_extmarks(target, preview.ns_id, 0, -1, { details = true })
assert(vim.inspect(target_marks):find('sign_text = ">>"', 1, true), 'hidden target sign is missing')

assert(require('minuet.tab').accept(), 'first cross TUI Tab was not handled')
assert(vim.api.nvim_get_current_buf() == target, 'first cross TUI Tab did not switch buffers')
assert(vim.api.nvim_buf_get_lines(target, 0, -1, false)[1] == 'local target = 1', 'first cross TUI Tab wrote target')
local focused_screen = visible_text()
assert(focused_screen:find('local target = 2', 1, true), 'cross-buffer focused diff is not visible')
assert(not focused_screen:find('Next edit:', 1, true), 'cross-buffer origin hint remained after focus')

assert(require('minuet.tab').accept(), 'second cross TUI Tab was not handled')
helpers.wait_until(function()
    return vim.api.nvim_buf_get_lines(target, 0, -1, false)[1] == 'local target = 2'
end, 500, 'second cross TUI Tab did not apply')
vim.cmd 'undo'
assert(vim.api.nvim_buf_get_lines(target, 0, -1, false)[1] == 'local target = 1', 'cross TUI undo failed')
vim.cmd 'normal! \15'
assert(vim.api.nvim_get_current_buf() == origin, 'cross TUI jumplist did not return to origin')

print(
    ('CROSS TUI PASS %dx%d TERM=%s background=%s'):format(
        vim.o.columns,
        vim.o.lines,
        vim.env.TERM or '',
        vim.o.background
    )
)
vim.cmd 'qa!'
