local helpers = require 'tests.helpers'

return {
    {
        name = 'utils.trim_completion_items skips whitespace-only completion items',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'

            helpers.expect_equal(utils.trim_completion_items { '  foo  ', '   ', '\n\t', ' bar' }, { 'foo', 'bar' })
        end,
    },
    {
        name = 'utils.filter_text keeps leading newline while matching duplicated context',
        run = function()
            helpers.setup_root_config {
                before_cursor_filter_length = 2,
                after_cursor_filter_length = 0,
            }

            local utils = helpers.reload 'minuet.utils'

            helpers.expect_equal(
                utils.filter_text('\nfoo', {
                    lines_before = 'foo',
                    lines_after = '',
                }),
                '\nfoo'
            )
        end,
    },
    {
        name = 'utils.no_stream_decode ignores non-string extracted text',
        run = function()
            helpers.setup_root_config()

            local utils = helpers.reload 'minuet.utils'
            local data_file = vim.fn.tempname()
            vim.fn.writefile({ '{}' }, data_file)

            local result = utils.no_stream_decode(
                {
                    code = 0,
                    stdout = vim.json.encode {
                        choices = {
                            { text = { 'not a string' } },
                        },
                    },
                },
                data_file,
                'TestProvider',
                function(json)
                    return json.choices[1].text
                end
            )

            helpers.expect_falsy(result)
            helpers.expect_falsy(vim.uv.fs_stat(data_file))
        end,
    },
    {
        name = 'utils.stream_decode assembles chunks and classifies every failure family',
        run = function()
            helpers.setup_root_config()
            local utils = helpers.reload 'minuet.utils'

            local function stream(parts)
                local lines = {}
                for _, part in ipairs(parts) do
                    lines[#lines + 1] = 'data: ' .. vim.json.encode { delta = part }
                    lines[#lines + 1] = ''
                end
                return table.concat(lines, '\n')
            end

            local function extract(json)
                return json.delta
            end

            local success = utils.stream_decode(
                { code = 0, stdout = stream { '<editable_', 'region>' } },
                nil,
                'Fixture',
                extract,
                { notify = false }
            )
            helpers.expect_equal(success.status, 'success')
            helpers.expect_equal(success.text, '<editable_region>')

            local partial = utils.stream_decode(
                { code = 28, stdout = stream { 'partial' } },
                nil,
                'Fixture',
                extract,
                { notify = false }
            )
            helpers.expect_equal(partial.status, 'partial')
            helpers.expect_equal(partial.reason, 'timeout')
            helpers.expect_equal(partial.text, 'partial')

            local timeout = utils.stream_decode({ code = 28, stdout = '' }, nil, 'Fixture', extract, { notify = false })
            helpers.expect_equal(timeout.status, 'timeout')
            helpers.expect_equal(timeout.reason, 'timeout')

            local transport = utils.stream_decode(
                { code = 7, stdout = 'PRIVATE_RAW_RESPONSE' },
                nil,
                'Fixture',
                extract,
                { notify = false }
            )
            helpers.expect_equal(transport.status, 'transport_error')
            helpers.expect_equal(transport.reason, 'transport_error')
            helpers.expect_falsy(transport.text)

            local invalid_json = utils.stream_decode(
                { code = 0, stdout = 'data: {broken}\n\n' },
                nil,
                'Fixture',
                extract,
                { notify = false }
            )
            helpers.expect_equal(invalid_json.status, 'invalid_response')
            helpers.expect_equal(invalid_json.reason, 'invalid_json')

            local extractor_error = utils.stream_decode(
                { code = 0, stdout = stream { 'value' } },
                nil,
                'Fixture',
                function()
                    error 'PRIVATE_EXTRACTOR_ERROR'
                end,
                { notify = false }
            )
            helpers.expect_equal(extractor_error.status, 'invalid_response')
            helpers.expect_equal(extractor_error.reason, 'extractor_error')

            local empty = utils.stream_decode(
                { code = 0, stdout = stream { '' } },
                nil,
                'Fixture',
                extract,
                { notify = false }
            )
            helpers.expect_equal(empty.status, 'empty_response')
            helpers.expect_equal(empty.reason, 'empty_response')
        end,
    },
    {
        name = 'utils.make_tmp_file uses private permissions and reference-counted cleanup',
        run = function()
            helpers.setup_root_config()
            local utils = helpers.reload 'minuet.utils'
            local path

            local ok, err = xpcall(function()
                local lease
                path, lease = utils.make_tmp_file({ prompt = 'TEMP_FILE_SENTINEL' }, 2)
                helpers.expect_truthy(path)
                helpers.expect_truthy(lease)
                helpers.expect_equal(vim.fn.getfperm(path), 'rw-------')
                helpers.expect_truthy(table.concat(vim.fn.readfile(path), ''):find('TEMP_FILE_SENTINEL', 1, true))

                helpers.expect_truthy(lease:release())
                helpers.expect_truthy(vim.uv.fs_stat(path), 'shared request file was removed too early')
                helpers.expect_truthy(lease:release())
                helpers.expect_falsy(vim.uv.fs_stat(path), 'request file remained after its final release')
                helpers.expect_falsy(lease:release(), 'lease cleanup must be idempotent')
            end, debug.traceback)

            if path then
                pcall(vim.uv.fs_unlink, path)
            end
            if not ok then
                error(err)
            end
        end,
    },
    {
        name = 'utils.make_tmp_file encodes before allocating a filesystem path',
        run = function()
            helpers.setup_root_config()
            local utils = helpers.reload 'minuet.utils'
            local original_tempname = vim.fn.tempname
            local tempname_called = false

            vim.fn.tempname = function()
                tempname_called = true
                return original_tempname()
            end
            local ok, path = pcall(utils.make_tmp_file, { unsupported = function() end })
            vim.fn.tempname = original_tempname

            helpers.expect_truthy(ok)
            helpers.expect_falsy(path)
            helpers.expect_falsy(tempname_called)
        end,
    },
}
