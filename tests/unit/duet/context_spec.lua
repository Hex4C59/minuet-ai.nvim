local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.context.build captures the editable region around the cursor',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 1,
                        lines_after = 1,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'zero', 'one', 'two', 'three' }, { 3, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'zero')
            helpers.expect_equal(built.editable_region_before_cursor, 'one\ntw')
            helpers.expect_equal(built.editable_region_after_cursor, 'o\nthree')
            helpers.expect_equal(built.non_editable_region_after, '')
            helpers.expect_equal(built.original_lines, { 'one', 'two', 'three' })
            helpers.expect_equal(built.range, {
                start_row = 1,
                end_row = 4,
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build handles an empty buffer',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 2,
                        lines_after = 2,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ '' }, { 1, 0 })
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, '')
            helpers.expect_equal(built.editable_region_before_cursor, '')
            helpers.expect_equal(built.editable_region_after_cursor, '')
            helpers.expect_equal(built.non_editable_region_after, '')
            helpers.expect_equal(built.original_lines, { '' })
            helpers.expect_equal(built.range, {
                start_row = 0,
                end_row = 1,
            })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build keeps non-editable regions within the context window unchanged',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    non_editable_region = {
                        context_window = 100,
                        context_ratio = 0.75,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'alpha', 'edit', 'omega' }, { 2, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'alpha')
            helpers.expect_equal(built.editable_region_before_cursor, 'ed')
            helpers.expect_equal(built.editable_region_after_cursor, 'it')
            helpers.expect_equal(built.non_editable_region_after, 'omega')
            helpers.expect_equal(built.original_lines, { 'edit' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build truncates only the non-editable region before the editable region',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    non_editable_region = {
                        context_window = 20,
                        context_ratio = 0.75,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'before-one', 'before-two', 'before-three', 'edit', 'x' }, { 4, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'before-three')
            helpers.expect_equal(built.editable_region_before_cursor, 'ed')
            helpers.expect_equal(built.editable_region_after_cursor, 'it')
            helpers.expect_equal(built.non_editable_region_after, 'x')
            helpers.expect_equal(built.original_lines, { 'edit' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build truncates only the non-editable region after the editable region',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    non_editable_region = {
                        context_window = 20,
                        context_ratio = 0.75,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'b', 'edit', 'after-one', 'after-two', 'after-three' }, { 2, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'b')
            helpers.expect_equal(built.editable_region_before_cursor, 'ed')
            helpers.expect_equal(built.editable_region_after_cursor, 'it')
            helpers.expect_equal(built.non_editable_region_after, 'after-one')
            helpers.expect_equal(built.original_lines, { 'edit' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build truncates both non-editable regions using context ratio',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    non_editable_region = {
                        context_window = 40,
                        context_ratio = 0.75,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({
                'before-one',
                'before-two',
                'before-three',
                'edit',
                'after-one',
                'after-two',
                'after-three',
            }, { 4, 2 })

            local built = context.build(bufnr)

            helpers.expect_equal(built.non_editable_region_before, 'before-two\nbefore-three')
            helpers.expect_equal(built.editable_region_before_cursor, 'ed')
            helpers.expect_equal(built.editable_region_after_cursor, 'it')
            helpers.expect_equal(built.non_editable_region_after, 'after-one')
            helpers.expect_equal(built.original_lines, { 'edit' })

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build renders bounded semantic evidence without diagnostic metadata leakage',
        run = function()
            helpers.setup_root_config {
                duet = {
                    context = {
                        max_chars = 1000,
                        evidence_max_chars = 260,
                        diagnostic_radius = 20,
                        max_diagnostics = 2,
                    },
                    recent_edits = { enabled = false },
                },
            }
            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'local alpha = 1', 'return alpha' }, { 1, 0 })
            vim.bo[bufnr].buftype = ''
            vim.bo[bufnr].filetype = 'lua'
            vim.api.nvim_buf_set_name(bufnr, vim.fs.joinpath(vim.fn.getcwd(), 'src', 'evidence.lua'))
            local namespace = vim.api.nvim_create_namespace 'minuet-context-evidence'
            vim.diagnostic.set(namespace, bufnr, {
                {
                    lnum = 1,
                    col = 0,
                    severity = vim.diagnostic.severity.ERROR,
                    message = 'bounded\nmessage',
                    code = 'PRIVATE_CODE',
                    source = 'PRIVATE_SOURCE',
                    user_data = { secret = 'PRIVATE_USER_DATA' },
                },
            })
            local built = context.build(bufnr, {
                bufnr = bufnr,
                row = 1,
                col = 7,
                source = 'reference',
            }, {
                identifiers = { 'alpha' },
                references = { { row = 1, col = 7, name = 'alpha' } },
                definitions = { { path = 'src/evidence.lua', row = 0, name = 'alpha' } },
            })
            helpers.expect_match(built.context_evidence, 'Current file: src/evidence.lua')
            helpers.expect_match(built.context_evidence, 'Candidate source: reference')
            helpers.expect_match(built.context_evidence, 'bounded message')
            helpers.expect_match(built.context_evidence, '</context_evidence>$')
            helpers.expect_falsy(built.context_evidence:find('PRIVATE_CODE', 1, true))
            helpers.expect_falsy(built.context_evidence:find('PRIVATE_SOURCE', 1, true))
            helpers.expect_falsy(built.context_evidence:find('PRIVATE_USER_DATA', 1, true))
            local total = vim.fn.strchars(
                built.non_editable_region_before
                    .. built.editable_region_before_cursor
                    .. built.editable_region_after_cursor
                    .. built.non_editable_region_after
                    .. built.recent_edits
                    .. built.context_evidence
            )
            helpers.expect_truthy(total <= 1000)
            vim.diagnostic.reset(namespace, bufnr)
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build rejects an editable region beyond the total context budget',
        run = function()
            helpers.setup_root_config {
                duet = {
                    context = { max_chars = 3 },
                    editable_region = { lines_before = 0, lines_after = 0 },
                },
            }
            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'too long' }, { 1, 0 })
            local ok = pcall(context.build, bufnr)
            helpers.expect_falsy(ok)
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.context.build uses an explicit candidate without moving the window cursor',
        run = function()
            helpers.setup_root_config {
                duet = {
                    editable_region = {
                        lines_before = 1,
                        lines_after = 1,
                    },
                },
            }

            local context = helpers.reload 'minuet.duet.context'
            local bufnr = helpers.create_buffer({ 'zero', 'one', 'two', 'three', 'four' }, { 1, 2 })
            local built = context.build(bufnr, { bufnr = bufnr, row = 3, col = 99 })

            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 2 })
            helpers.expect_equal(built.editable_region_before_cursor, 'two\nthree')
            helpers.expect_equal(built.editable_region_after_cursor, '\nfour')
            helpers.expect_equal(built.original_lines, { 'two', 'three', 'four' })
            helpers.expect_equal(built.range, { start_row = 2, end_row = 5 })

            local ok = pcall(context.build, bufnr, { bufnr = bufnr + 1, row = 0, col = 0 })
            helpers.expect_falsy(ok, 'cross-buffer context candidate should be rejected')
            helpers.delete_buffer(bufnr)
        end,
    },
}
