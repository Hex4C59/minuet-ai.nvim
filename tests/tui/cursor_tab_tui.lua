local helpers = require 'tests.helpers'

helpers.setup_root_config {
    duet = {
        provider = 'tui_test',
        scope = 'buffer',
        jump_requires_confirmation = true,
        candidates = {
            cursor = false,
            recent_edits = false,
            diagnostics = true,
            max_candidates = 8,
        },
        editable_region = {
            lines_before = 0,
            lines_after = 0,
        },
        recent_edits = {
            enabled = false,
        },
        auto_trigger = {
            enabled = false,
        },
        preview = {
            cursor = '|',
            jump_text = 'Next edit: line %d',
            jump_sign = '>>',
        },
    },
}

local callback
package.loaded['minuet.duet.backends.tui_test'] = {
    complete = function(_, complete)
        callback = complete
    end,
}

vim.o.number = false
vim.o.relativenumber = false
vim.o.signcolumn = 'yes'
vim.o.wrap = false
vim.o.laststatus = 2
vim.o.showmode = false
vim.o.background = vim.env.MINUET_TUI_BACKGROUND == 'light' and 'light' or 'dark'

local long_origin = vim.env.MINUET_TUI_LONG_LINE == '1'
local origin_line = long_origin and ('local origin = "' .. string.rep('x', 160) .. '"') or 'local origin = true'
local bufnr = helpers.create_buffer({
    origin_line,
    '',
    'local middle = true',
    '',
    'local target = 1',
    'return target',
}, { 1, 0 })
vim.bo[bufnr].buftype = ''
vim.bo[bufnr].undolevels = -1
vim.bo[bufnr].undolevels = 1000
vim.api.nvim_buf_set_name(bufnr, ('/tmp/minuet-tui-%d.lua'):format(bufnr))
local diagnostic_namespace = vim.api.nvim_create_namespace 'minuet-tui-diagnostic'
vim.diagnostic.set(diagnostic_namespace, bufnr, {
    {
        lnum = 4,
        col = 6,
        severity = vim.diagnostic.severity.ERROR,
        message = 'TUI_PRIVATE_SENTINEL',
    },
})

local duet = helpers.reload 'minuet.duet'
duet.setup()
assert(duet.action.predict(), 'TUI prediction did not start')
assert(callback, 'TUI backend callback was not captured')
callback [[<editable_region>
local target = 2<cursor_position/>
</editable_region>]]
helpers.wait_until(function()
    return duet.action.is_visible()
end, 500, 'TUI jump preview did not become visible')

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
if not long_origin then
    assert(initial_screen:find('Next edit: line 5', 1, true), 'jump hint is not visible in terminal cells')
end
assert(initial_screen:find('>>', 1, true), 'target sign is not visible in terminal cells')
assert(not initial_screen:find('TUI_PRIVATE_SENTINEL', 1, true), 'diagnostic message leaked into the UI')
assert(not initial_screen:find('local target = 2', 1, true), 'remote diff was expanded before focus')

assert(require('minuet.tab').accept(), 'first TUI Tab was not handled')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 5, 6 }), 'first TUI Tab did not focus the target')
assert(vim.api.nvim_buf_get_lines(bufnr, 4, 5, false)[1] == 'local target = 1', 'first TUI Tab wrote the buffer')
local focused_screen = visible_text()
assert(focused_screen:find('local target = 2', 1, true), 'focused diff is not visible in terminal cells')
assert(not focused_screen:find('Next edit: line 5', 1, true), 'origin hint remained after focus')

assert(require('minuet.tab').accept(), 'second TUI Tab was not handled')
helpers.wait_until(function()
    return vim.api.nvim_buf_get_lines(bufnr, 4, 5, false)[1] == 'local target = 2'
end, 500, 'second TUI Tab did not apply')
vim.cmd 'undo'
assert(vim.api.nvim_buf_get_lines(bufnr, 4, 5, false)[1] == 'local target = 1', 'one undo did not revert the edit')

print(
    ('TUI PASS %dx%d TERM=%s background=%s long_origin=%s'):format(
        vim.o.columns,
        vim.o.lines,
        vim.env.TERM or '',
        vim.o.background,
        tostring(long_origin)
    )
)
vim.cmd 'qa!'
