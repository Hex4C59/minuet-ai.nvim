local helpers = require 'tests.helpers'

return {
    {
        name = 'duet.action.predict trims duplicated non-editable region text from the duet response',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                        before_region_filter_length = 3,
                        after_region_filter_length = 3,
                    },
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local pending_callback

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'before', 'return 1', 'after' }, { 2, 8 })

            duet.action.predict()
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')

            pending_callback [[<editable_region>
before
return 42<cursor_position/>
after
</editable_region>]]

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            duet.action.apply()

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'before', 'return 42', 'after' })
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 2, 8 })

            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.preview_shown, 1)
            helpers.expect_equal(cycles.accepted, 1)
            vim.cmd 'undo'
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr })
            helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.reverted, 1)
            helpers.expect_equal(cycles.accepted_visible, 1)

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.predict followed by apply updates the buffer and cursor',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                    preview = {
                        cursor = '|',
                    },
                },
            }

            local pending_callback
            local seen_context

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(context, callback)
                    seen_context = context
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()

            helpers.expect_equal(seen_context.original_lines, { 'return 1' })
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')

            pending_callback [[<editable_region>
return 42<cursor_position/>
</editable_region>]]

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            duet.action.apply()

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 42' })
            helpers.expect_equal(vim.api.nvim_win_get_cursor(0), { 1, 8 })
            helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after apply')

            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.preview_shown, 1)
            helpers.expect_equal(cycles.accepted, 1)

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.predict discards stale provider responses',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 7' })

            pending_callback [[<editable_region>
return 42<cursor_position/>
</editable_region>]]

            vim.wait(50, function()
                return false
            end, 10)

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 7' })
            helpers.expect_falsy(duet.action.is_visible(), 'stale duet preview should not render')

            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.with_result, 1)
            helpers.expect_equal(cycles.preview_shown, 0)
            helpers.expect_equal(cycles.stale, 1)

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.dismiss clears the preview without changing the buffer',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')

            pending_callback [[<editable_region>
return 42<cursor_position/>
</editable_region>]]

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            duet.action.dismiss()

            helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after dismiss')
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 1' })

            duet.action.apply()

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 1' })

            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.preview_shown, 1)
            helpers.expect_equal(cycles.dismissed, 1)
            helpers.expect_equal(cycles.accepted, 0)

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.apply becomes a no-op after the preview is cleared by editing',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback

            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()

            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()
            helpers.expect_truthy(pending_callback, 'backend callback was not captured')

            pending_callback [[<editable_region>
return 42<cursor_position/>
</editable_region>]]

            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 7' })
            vim.api.nvim_exec_autocmds('TextChanged', { buffer = bufnr, modeline = false })

            helpers.expect_falsy(duet.action.is_visible(), 'preview should be cleared after editing the buffer')

            duet.action.apply()

            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 7' })

            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.preview_shown, 1)
            helpers.expect_equal(cycles.stale, 1)
            helpers.expect_equal(cycles.accepted, 0)

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.predict rejects a superseded non-empty callback',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local callbacks = {}
            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    callbacks[#callbacks + 1] = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })

            duet.action.predict()
            duet.action.predict()
            helpers.expect_equal(#callbacks, 2)

            callbacks[1] [[<editable_region>
return 10<cursor_position/>
</editable_region>]]
            vim.wait(20)
            helpers.expect_falsy(duet.action.is_visible(), 'superseded callback rendered a preview')

            callbacks[2] [[<editable_region>
return 20<cursor_position/>
</editable_region>]]
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'newest duet callback did not render')

            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.started, 2)
            helpers.expect_equal(cycles.with_result, 2)
            helpers.expect_equal(cycles.preview_shown, 1)
            helpers.expect_equal(cycles.stale, 1)

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet malformed output emits a classified parse failure without response text',
        run = function()
            local sentinel = 'DUET_PRIVATE_RESPONSE_SENTINEL_71f4'
            helpers.setup_root_config {
                notify = 'warn',
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback
            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local notifications, restore_notifications = helpers.capture_notifications()
            local group = vim.api.nvim_create_augroup('MinuetDuetParseFailureSpec', { clear = true })
            local lifecycle
            vim.api.nvim_create_autocmd('User', {
                group = group,
                pattern = 'MinuetSuggestionLifecycle',
                callback = function(args)
                    lifecycle = args.data
                end,
            })

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
            duet.action.predict()
            pending_callback(sentinel)

            helpers.wait_until(function()
                return require('minuet.metrics').get().channels.duet.cycles.parse_failed == 1
            end, 1000, 'duet parse failure was not recorded')

            helpers.expect_equal(lifecycle.kind, 'parse_failed')
            helpers.expect_equal(lifecycle.reason, 'invalid_markers')
            helpers.expect_falsy(vim.inspect(lifecycle):find(sentinel, 1, true))
            helpers.expect_falsy(vim.inspect(notifications):find(sentinel, 1, true))
            helpers.expect_falsy(duet.action.is_visible())

            restore_notifications()
            pcall(vim.api.nvim_del_augroup_by_id, group)
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet.action.apply classifies changed preview state as apply validation stale',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback
            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local group = vim.api.nvim_create_augroup('MinuetDuetApplyStaleSpec', { clear = true })
            local stale_reason
            vim.api.nvim_create_autocmd('User', {
                group = group,
                pattern = 'MinuetSuggestionLifecycle',
                callback = function(args)
                    if args.data.kind == 'stale' then
                        stale_reason = args.data.reason
                    end
                end,
            })

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
            duet.action.predict()
            pending_callback [[<editable_region>
return 42<cursor_position/>
</editable_region>]]
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 1000, 'duet preview did not become visible')

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'return 7' })
            duet.action.apply()

            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.stale, 1)
            helpers.expect_equal(cycles.accepted, 0)
            helpers.expect_equal(stale_reason, 'apply_validation')
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 7' })

            pcall(vim.api.nvim_del_augroup_by_id, group)
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet cursor-only response is filtered before preview',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }

            local pending_callback
            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    pending_callback = callback
                end,
            }

            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
            duet.action.predict()
            pending_callback [[<editable_region>
return 1<cursor_position/>
</editable_region>]]

            helpers.wait_until(function()
                return require('minuet.suggestion').current() == nil
            end, 1000, 'cursor-only duet response did not release its lease')
            helpers.expect_falsy(duet.action.is_visible())
            helpers.expect_equal(require('minuet.metrics').get().channels.duet.cycles.preview_shown, 0)

            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet filters whitespace-only and oversized responses before preview',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    max_edit_lines = 40,
                    max_edit_chars = 8,
                    editable_region = {
                        lines_before = 0,
                        lines_after = 0,
                    },
                },
            }
            local callbacks = {}
            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    callbacks[#callbacks + 1] = callback
                end,
            }
            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local bufnr = helpers.create_buffer({ 'alpha' }, { 1, 5 })

            duet.action.predict()
            callbacks[1] [[<editable_region>
 alpha <cursor_position/>
</editable_region>]]
            helpers.wait_until(function()
                return require('minuet.suggestion').current() == nil
            end, 500)
            helpers.expect_falsy(duet.action.is_visible())

            duet.action.predict()
            callbacks[2] [[<editable_region>
alpha extended<cursor_position/>
</editable_region>]]
            helpers.wait_until(function()
                return require('minuet.suggestion').current() == nil
            end, 500)
            helpers.expect_falsy(duet.action.is_visible())
            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.with_result, 2)
            helpers.expect_equal(cycles.preview_shown, 0)
            helpers.expect_equal(cycles.stale, 0)
            helpers.expect_equal(cycles.filtered, 2)
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet suppresses an identical same-context suggestion before a second preview',
        run = function()
            helpers.setup_root_config {
                duet = {
                    provider = 'test',
                    editable_region = { lines_before = 0, lines_after = 0 },
                    quality = {
                        repeat_suppression = { enabled = true, ttl = 30000, max_entries = 128 },
                    },
                },
            }
            local callbacks = {}
            package.loaded['minuet.duet.backends.test'] = {
                complete = function(_, callback)
                    callbacks[#callbacks + 1] = callback
                end,
            }
            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local bufnr = helpers.create_buffer({ 'return 1' }, { 1, 8 })
            local response = [[<editable_region>
return 42<cursor_position/>
</editable_region>]]

            duet.action.predict()
            callbacks[1](response)
            helpers.wait_until(function()
                return duet.action.is_visible()
            end, 500)
            duet.action.dismiss()

            duet.action.predict()
            callbacks[2](response)
            helpers.wait_until(function()
                return require('minuet.suggestion').current() == nil
            end, 500)
            local cycles = require('minuet.metrics').get().channels.duet.cycles
            helpers.expect_equal(cycles.preview_shown, 1)
            helpers.expect_equal(cycles.filtered, 1)
            helpers.expect_equal(cycles.accepted, 0)
            helpers.expect_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), { 'return 1' })
            helpers.delete_buffer(bufnr)
        end,
    },
}
