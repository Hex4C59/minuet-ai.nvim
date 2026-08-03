local helpers = require 'tests.helpers'

---@param count integer
---@return string[]
local function numbered_lines(count)
    local lines = {}
    for index = 1, count do
        lines[index] = ('line %d'):format(index)
    end
    return lines
end

return {
    {
        name = 'duet candidates returns the current cursor without LSP or edit history',
        run = function()
            helpers.setup_root_config()
            local candidates = helpers.reload 'minuet.duet.candidates'
            local bufnr = helpers.create_buffer({ 'alpha', 'beta' }, { 2, 2 })

            local input_cursor = { row = 1, col = 200 }
            local collected = candidates.collect(bufnr, {
                cursor = input_cursor,
                events = {},
                diagnostics = {},
            })

            helpers.expect_equal(collected, {
                {
                    bufnr = bufnr,
                    row = 1,
                    col = 4,
                    source = 'cursor',
                    score = 100,
                    distance = 0,
                    metadata = { sources = { 'cursor' } },
                },
            })
            helpers.expect_equal(input_cursor, { row = 1, col = 200 })
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet candidates merges recent edit and diagnostic signals without retaining messages',
        run = function()
            helpers.setup_root_config()
            local candidates = helpers.reload 'minuet.duet.candidates'
            local bufnr = helpers.create_buffer(numbered_lines(100), { 1, 0 })
            local sentinel = 'DIAGNOSTIC_PRIVATE_SENTINEL_4721'
            local events = {
                {
                    bufnr = bufnr,
                    diff = '@@ -50,1 +50,1 @@\n-old\n+new',
                },
            }
            local diagnostics = {
                { lnum = 49, col = 3, severity = vim.diagnostic.severity.WARN, message = sentinel },
                { lnum = 49, col = 5, severity = vim.diagnostic.severity.ERROR, message = sentinel },
                { lnum = 49, col = 7, severity = vim.diagnostic.severity.ERROR, message = sentinel },
            }

            local collected = candidates.collect(bufnr, {
                cursor = { row = 0, col = 0 },
                events = events,
                diagnostics = diagnostics,
            })

            helpers.expect_equal(collected[1].row, 49)
            helpers.expect_equal(collected[1].col, 0)
            helpers.expect_equal(collected[1].source, 'recent_edit')
            helpers.expect_equal(collected[1].score, 145.5)
            helpers.expect_equal(collected[1].metadata.sources, { 'recent_edit', 'diagnostic' })
            helpers.expect_equal(collected[1].metadata.severity, vim.diagnostic.severity.ERROR)
            helpers.expect_equal(collected[1].metadata.edit_age, 0)
            helpers.expect_equal(collected[2].source, 'cursor')
            helpers.expect_falsy(vim.inspect(collected):find(sentinel, 1, true))

            collected[1].metadata.sources[1] = 'cursor'
            local second = candidates.collect(bufnr, {
                cursor = { row = 0, col = 0 },
                events = events,
                diagnostics = diagnostics,
            })
            helpers.expect_equal(second[1].metadata.sources, { 'recent_edit', 'diagnostic' })
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet candidates parses multi-hunk rows clamps deletions and ignores other buffers',
        run = function()
            helpers.setup_root_config {
                duet = {
                    candidates = {
                        cursor = false,
                        diagnostics = false,
                        max_candidates = 8,
                    },
                },
            }
            local candidates = helpers.reload 'minuet.duet.candidates'
            local bufnr = helpers.create_buffer(numbered_lines(20), { 10, 0 })
            local events = {
                { bufnr = bufnr + 1000, diff = '@@ -1 +1 @@\n-old\n+new' },
                {
                    bufnr = bufnr,
                    diff = table.concat({
                        '@@ -3,1 +3,1 @@',
                        '-old',
                        '+new',
                        '@@ -20,1 +21,0 @@',
                        '-gone',
                        '@@ malformed @@',
                    }, '\n'),
                },
            }

            local collected = candidates.collect(bufnr, {
                cursor = { row = 9, col = 0 },
                events = events,
                diagnostics = {},
            })

            helpers.expect_equal(
                vim.tbl_map(function(item)
                    return item.row
                end, collected),
                { 2, 19 }
            )
            helpers.expect_equal(collected[1].score, 86.5)
            helpers.expect_equal(collected[2].score, 85)
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet candidates merges provisional reference and text signals deterministically',
        run = function()
            helpers.setup_root_config {
                duet = {
                    candidates = {
                        cursor = true,
                        recent_edits = false,
                        diagnostics = false,
                        references = true,
                        text = true,
                        max_candidates = 8,
                    },
                },
            }
            local candidates = helpers.reload 'minuet.duet.candidates'
            local bufnr = helpers.create_buffer(numbered_lines(30), { 1, 0 })
            local semantic = {
                references = { { row = 20, col = 2, name = 'PRIVATE_IDENTIFIER' } },
                text_matches = {
                    { row = 20, col = 4, name = 'PRIVATE_IDENTIFIER' },
                    { row = 20, col = 6, name = 'PRIVATE_IDENTIFIER' },
                },
            }
            local collected = candidates.collect(bufnr, {
                cursor = { row = 0, col = 0 },
                events = {},
                diagnostics = {},
                semantic = semantic,
            })
            helpers.expect_equal(collected[1].row, 20)
            helpers.expect_equal(collected[1].source, 'reference')
            helpers.expect_equal(collected[1].score, 110)
            helpers.expect_equal(collected[1].metadata.sources, { 'reference', 'text' })
            helpers.expect_equal(collected[1].metadata.identifier_count, 1)
            helpers.expect_falsy(vim.inspect(collected):find('PRIVATE_IDENTIFIER', 1, true))
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet candidates uses stable ties source switches limits and buffer guards',
        run = function()
            helpers.setup_root_config {
                duet = {
                    candidates = {
                        cursor = false,
                        recent_edits = false,
                        diagnostics = true,
                        max_candidates = 2,
                    },
                },
            }
            local candidates = helpers.reload 'minuet.duet.candidates'
            local bufnr = helpers.create_buffer(numbered_lines(30), { 16, 0 })
            local diagnostics = {
                { lnum = 20, col = 0, severity = vim.diagnostic.severity.INFO },
                { lnum = 10, col = 0, severity = vim.diagnostic.severity.INFO },
                { lnum = 0, col = 0, severity = vim.diagnostic.severity.HINT },
            }

            local collected = candidates.collect(bufnr, {
                cursor = { row = 15, col = 0 },
                events = {},
                diagnostics = diagnostics,
            })
            helpers.expect_equal(
                vim.tbl_map(function(item)
                    return item.row
                end, collected),
                { 10, 20 }
            )

            vim.bo[bufnr].modifiable = false
            helpers.expect_equal(candidates.collect(bufnr), {})
            vim.bo[bufnr].modifiable = true
            helpers.delete_buffer(bufnr)
            helpers.expect_equal(candidates.collect(bufnr), {})
        end,
    },
    {
        name = 'duet candidates requires both workspace scope and related-buffer opt-in',
        run = function()
            helpers.setup_root_config {
                duet = {
                    scope = 'workspace',
                    candidates = {
                        cursor = false,
                        recent_edits = false,
                        diagnostics = false,
                        references = false,
                        text = false,
                        related_buffers = true,
                    },
                },
            }
            local candidates = helpers.reload 'minuet.duet.candidates'
            local origin = helpers.create_buffer({ 'origin' }, { 1, 0 })
            vim.bo[origin].buftype = ''
            vim.api.nvim_buf_set_name(origin, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-origin.lua'))
            local target = helpers.create_buffer({ 'zero', 'targetValue' }, { 1, 0 })
            vim.bo[target].buftype = ''
            vim.api.nvim_buf_set_name(target, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-target.lua'))
            vim.api.nvim_set_current_buf(origin)
            local semantic = {
                related_references = {
                    { bufnr = target, row = 1, col = 3, path = 'ignored', name = 'PRIVATE_NAME' },
                    { bufnr = target, row = 1, col = 7, path = 'ignored', name = 'PRIVATE_NAME' },
                },
            }

            local collected = candidates.collect(origin, { semantic = semantic })
            helpers.expect_equal(collected, {
                {
                    bufnr = target,
                    row = 1,
                    col = 3,
                    source = 'related_buffer',
                    score = 55,
                    distance = 0,
                    metadata = { sources = { 'related_buffer' }, identifier_count = 1 },
                },
            })
            helpers.expect_falsy(vim.inspect(collected):find('PRIVATE_NAME', 1, true))
            helpers.expect_truthy(candidates.exists(collected[1], { semantic = semantic, origin_bufnr = origin }))

            require('minuet').config.duet.scope = 'buffer'
            helpers.expect_equal(candidates.collect(origin, { semantic = semantic }), {})
            require('minuet').config.duet.scope = 'workspace'
            require('minuet').config.duet.candidates.related_buffers = false
            helpers.expect_equal(candidates.collect(origin, { semantic = semantic }), {})
            require('minuet').config.duet.candidates.related_buffers = true
            vim.bo[target].modifiable = false
            helpers.expect_equal(candidates.collect(origin, { semantic = semantic }), {})

            vim.bo[target].modifiable = true
            helpers.delete_buffer(target)
            helpers.delete_buffer(origin)
        end,
    },
}
