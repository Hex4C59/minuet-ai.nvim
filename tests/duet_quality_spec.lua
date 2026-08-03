local helpers = require 'tests.helpers'

local function edit(overrides)
    return vim.tbl_deep_extend('force', {
        bufnr = 7,
        changedtick = 11,
        range = { start_row = 2, end_row = 3 },
        proposed_lines = { 'PRIVATE_SOURCE_SENTINEL' },
    }, overrides or {})
end

return {
    {
        name = 'duet quality suppresses only identical bounded in-memory edit fingerprints',
        run = function()
            helpers.setup_root_config {
                duet = {
                    quality = {
                        repeat_suppression = { enabled = true, ttl = 30000, max_entries = 2 },
                    },
                },
            }
            local quality = helpers.reload 'minuet.duet.quality'
            helpers.expect_falsy(quality.is_repeat(edit()))
            helpers.expect_truthy(quality.is_repeat(edit()))
            helpers.expect_falsy(quality.is_repeat(edit { changedtick = 12 }))
            helpers.expect_falsy(quality.is_repeat(edit { proposed_lines = { 'different' } }))
            helpers.expect_equal(quality._inspect().count, 2)
            helpers.expect_falsy(vim.inspect(quality._inspect()):find('PRIVATE_SOURCE_SENTINEL', 1, true))

            quality.reset()
            helpers.expect_equal(quality._inspect().count, 0)
        end,
    },
    {
        name = 'duet quality honors disabled and expired repeat suppression',
        run = function()
            helpers.setup_root_config {
                duet = {
                    quality = {
                        repeat_suppression = { enabled = false, ttl = 30000, max_entries = 2 },
                    },
                },
            }
            local quality = helpers.reload 'minuet.duet.quality'
            helpers.expect_falsy(quality.is_repeat(edit()))
            helpers.expect_falsy(quality.is_repeat(edit()))
            helpers.expect_equal(quality._inspect().count, 0)

            require('minuet').config.duet.quality.repeat_suppression.enabled = true
            require('minuet').config.duet.quality.repeat_suppression.ttl = 1
            helpers.expect_falsy(quality.is_repeat(edit()))
            vim.wait(10)
            helpers.expect_falsy(quality.is_repeat(edit()))
        end,
    },
}
