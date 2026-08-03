local helpers = require 'tests.helpers'

return {
    {
        name = 'duet related remains inert by default and renders only explicit safe loaded imports',
        run = function()
            helpers.setup_root_config()
            local current = helpers.create_buffer({ [[local helper = require('pkg.helper')]] }, { 1, 0 })
            vim.bo[current].buftype = ''
            vim.api.nvim_buf_set_name(current, vim.fs.joinpath(vim.fn.getcwd(), 'app', 'main.lua'))
            local related_buf = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_lines(related_buf, 0, -1, false, { 'return { value = 42 }' })
            vim.api.nvim_buf_set_name(related_buf, vim.fs.joinpath(vim.fn.getcwd(), 'pkg', 'helper.lua'))
            local secret = vim.api.nvim_create_buf(true, false)
            vim.api.nvim_buf_set_lines(secret, 0, -1, false, { 'SECRET_SENTINEL' })
            vim.api.nvim_buf_set_name(secret, vim.fs.joinpath(vim.fn.getcwd(), 'pkg', '.env'))

            local related = helpers.reload 'minuet.duet.related_files'
            helpers.expect_equal(related.render(current, 4000), '')
            require('minuet').config.duet.context.related_files.enabled = true
            local rendered = related.render(current, 4000)
            helpers.expect_match(rendered, '<related_file path="pkg/helper.lua">')
            helpers.expect_match(rendered, 'value = 42')
            helpers.expect_falsy(rendered:find('SECRET_SENTINEL', 1, true))

            helpers.delete_buffer(secret)
            helpers.delete_buffer(related_buf)
            helpers.delete_buffer(current)
        end,
    },
    {
        name = 'duet guards rejects escapes secrets binary and non-file buffers',
        run = function()
            helpers.setup_root_config()
            local guards = helpers.reload 'minuet.duet.guards'
            helpers.expect_equal(guards.relative_path('/workspace', '/workspace/src/a.lua'), 'src/a.lua')
            helpers.expect_equal(guards.relative_path('/workspace', '/other/a.lua'), nil)
            helpers.expect_truthy(guards.is_secret_path '/tmp/.env.local')
            helpers.expect_truthy(guards.is_secret_path '/tmp/client.pem')
            helpers.expect_falsy(guards.is_secret_path '/tmp/main.lua')

            local bufnr = helpers.create_buffer({ 'safe' }, { 1, 0 })
            vim.bo[bufnr].buftype = 'nofile'
            helpers.expect_falsy(guards.is_safe_buffer(bufnr, true))
            helpers.delete_buffer(bufnr)
        end,
    },
}
