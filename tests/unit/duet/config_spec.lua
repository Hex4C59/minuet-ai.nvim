local helpers = require 'tests.helpers'

return {
    {
        name = 'duet config keeps automatic requests opt-in with conservative limits',
        run = function()
            helpers.setup_root_config()
            local config = require('minuet').config.duet
            helpers.expect_equal(config.auto_trigger.enabled, false)
            helpers.expect_equal(config.auto_trigger.debounce, 900)
            helpers.expect_equal(config.auto_trigger.throttle, 1500)
            helpers.expect_equal(config.auto_trigger.max_buffer_size, 1000000)
            helpers.expect_equal(config.auto_trigger.filetype, {})
            helpers.expect_equal(config.quality.undo_window, 10000)
            helpers.expect_equal(config.quality.max_pending_undo, 64)
            helpers.expect_equal(config.quality.repeat_suppression.enabled, true)
            helpers.expect_equal(config.quality.repeat_suppression.ttl, 30000)
            helpers.expect_equal(config.quality.repeat_suppression.max_entries, 128)
            helpers.expect_equal(config.max_edit_lines, 40)
            helpers.expect_equal(config.max_edit_chars, 12000)
            helpers.expect_equal(config.scope, 'buffer')
            helpers.expect_equal(config.jump_requires_confirmation, true)
            helpers.expect_equal(config.candidates.max_candidates, 8)
            helpers.expect_equal(config.candidates.references, true)
            helpers.expect_equal(config.candidates.text, true)
            helpers.expect_equal(config.candidates.related_buffers, false)
            helpers.expect_equal(config.lsp.timeout, 120)
            helpers.expect_equal(config.lsp.cache_ttl, 30000)
            helpers.expect_equal(config.context.max_chars, 48000)
            helpers.expect_equal(config.context.related_files.enabled, false)
            helpers.expect_equal(config.preview.jump_text, 'Next edit: line %d')
            helpers.expect_equal(config.preview.cross_jump_text, 'Next edit: %s:%d')
            helpers.expect_equal(config.preview.jump_sign, '>>')
        end,
    },
    {
        name = 'duet config secret guards reject credential paths and binary buffers',
        run = function()
            helpers.setup_root_config()
            local config = require('minuet').config.duet
            local bufnr = helpers.create_buffer({ 'sentinel' }, { 1, 0 })
            vim.bo[bufnr].buftype = ''
            local rejected = {
                '.env',
                '.env.local',
                '.netrc',
                '.npmrc',
                '.pypirc',
                'credentials',
                'credentials.json',
                'service-account.json',
                'id_rsa',
                'id_ed25519',
                'client.pem',
                'client.key',
                'client.p12',
                'client.pfx',
            }

            for index, tail in ipairs(rejected) do
                vim.api.nvim_buf_set_name(bufnr, ('/tmp/minuet-secret-%d/%s'):format(index, tail))
                helpers.expect_falsy(
                    require('minuet.utils').run_hooks_until_failure(config.auto_trigger.enable_predicates, bufnr),
                    'automatic guard allowed ' .. tail
                )
                helpers.expect_falsy(
                    require('minuet.utils').run_hooks_until_failure(config.recent_edits.enable_predicates, bufnr),
                    'recent-edits guard allowed ' .. tail
                )
            end

            vim.api.nvim_buf_set_name(bufnr, '/tmp/minuet-secret-safe/main.lua')
            helpers.expect_truthy(
                require('minuet.utils').run_hooks_until_failure(config.auto_trigger.enable_predicates, bufnr)
            )
            vim.bo[bufnr].binary = true
            helpers.expect_falsy(
                require('minuet.utils').run_hooks_until_failure(config.auto_trigger.enable_predicates, bufnr)
            )
            helpers.delete_buffer(bufnr)
        end,
    },
    {
        name = 'duet config gives recent edits and auto trigger independent predicate lists',
        run = function()
            helpers.setup_root_config()
            local config = require('minuet').config.duet
            helpers.expect_falsy(config.auto_trigger.enable_predicates == config.recent_edits.enable_predicates)
            local recent_count = #config.recent_edits.enable_predicates
            table.insert(config.auto_trigger.enable_predicates, function()
                return false
            end)
            helpers.expect_equal(#config.recent_edits.enable_predicates, recent_count)
        end,
    },
    {
        name = 'duet setup normalizes invalid timer and edit limit values',
        run = function()
            helpers.setup_root_config {
                duet = {
                    auto_trigger = {
                        enabled = false,
                        debounce = -1,
                        throttle = 'invalid',
                        max_buffer_size = 0 / 0,
                        filetype = {
                            lua = { debounce = -1, throttle = 25 },
                            bad = 'invalid',
                            [7] = { debounce = 1 },
                        },
                    },
                    max_edit_lines = -2,
                    max_edit_chars = 'invalid',
                    quality = {
                        undo_window = -1,
                        max_pending_undo = 99999,
                        repeat_suppression = {
                            enabled = 'invalid',
                            ttl = 99999999,
                            max_entries = -1,
                        },
                    },
                    scope = 'invalid',
                    jump_requires_confirmation = 'invalid',
                    candidates = {
                        cursor = 'invalid',
                        recent_edits = 1,
                        diagnostics = nil,
                        max_candidates = 1000,
                    },
                    lsp = {
                        timeout = 99999,
                        cache_ttl = -1,
                        max_cache_buffers = 0,
                    },
                    context = {
                        max_chars = 'invalid',
                        evidence_max_chars = -1,
                        related_files = {
                            enabled = 'invalid',
                            max_files = -1,
                        },
                    },
                    preview = {
                        jump_text = '%s %d',
                        cross_jump_text = '%s',
                        jump_sign = 'toolong',
                    },
                    recent_edits = {
                        enabled = false,
                    },
                },
            }
            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local config = require('minuet').config.duet
            helpers.expect_equal(config.auto_trigger.debounce, 900)
            helpers.expect_equal(config.auto_trigger.throttle, 1500)
            helpers.expect_equal(config.auto_trigger.max_buffer_size, 1000000)
            helpers.expect_equal(config.auto_trigger.filetype, {
                lua = { debounce = 900, throttle = 25 },
            })
            helpers.expect_equal(config.quality.undo_window, 10000)
            helpers.expect_equal(config.quality.max_pending_undo, 4096)
            helpers.expect_equal(config.quality.repeat_suppression.enabled, true)
            helpers.expect_equal(config.quality.repeat_suppression.ttl, 3600000)
            helpers.expect_equal(config.quality.repeat_suppression.max_entries, 128)
            helpers.expect_equal(config.max_edit_lines, 40)
            helpers.expect_equal(config.max_edit_chars, 12000)
            helpers.expect_equal(config.scope, 'buffer')
            helpers.expect_equal(config.jump_requires_confirmation, true)
            helpers.expect_equal(config.candidates.cursor, true)
            helpers.expect_equal(config.candidates.recent_edits, true)
            helpers.expect_equal(config.candidates.diagnostics, true)
            helpers.expect_equal(config.candidates.max_candidates, 64)
            helpers.expect_equal(config.candidates.references, true)
            helpers.expect_equal(config.candidates.text, true)
            helpers.expect_equal(config.candidates.related_buffers, false)
            helpers.expect_equal(config.lsp.timeout, 2000)
            helpers.expect_equal(config.lsp.cache_ttl, 30000)
            helpers.expect_equal(config.lsp.max_cache_buffers, 1)
            helpers.expect_equal(config.context.max_chars, 48000)
            helpers.expect_equal(config.context.evidence_max_chars, 4800)
            helpers.expect_equal(config.context.related_files.enabled, false)
            helpers.expect_equal(config.context.related_files.max_files, 3)
            helpers.expect_equal(config.preview.jump_text, 'Next edit: line %d')
            helpers.expect_equal(config.preview.cross_jump_text, 'Next edit: %s:%d')
            helpers.expect_equal(config.preview.jump_sign, '>>')
            require('minuet.duet.scheduler').reset()
        end,
    },
    {
        name = 'duet setup preserves valid cursor-only and jump preview configuration',
        run = function()
            helpers.setup_root_config {
                duet = {
                    scope = 'cursor',
                    jump_requires_confirmation = false,
                    candidates = {
                        cursor = false,
                        recent_edits = false,
                        diagnostics = true,
                        max_candidates = 1,
                    },
                    preview = {
                        jump_text = 'Edit at %d',
                        jump_sign = '>',
                    },
                },
            }
            local duet = helpers.reload 'minuet.duet'
            duet.setup()
            local config = require('minuet').config.duet
            helpers.expect_equal(config.scope, 'cursor')
            helpers.expect_equal(config.jump_requires_confirmation, false)
            helpers.expect_equal(config.candidates, {
                cursor = false,
                recent_edits = false,
                diagnostics = true,
                references = true,
                related_buffers = false,
                text = true,
                max_candidates = 1,
            })
            helpers.expect_equal(config.preview.jump_text, 'Edit at %d')
            helpers.expect_equal(config.preview.jump_sign, '>')
            require('minuet.duet.scheduler').reset()
        end,
    },
}
