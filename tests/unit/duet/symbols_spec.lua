local helpers = require 'tests.helpers'

---@param run fun(fixture: table)
local function with_symbols(run)
    helpers.setup_root_config {
        duet = {
            lsp = {
                timeout = 40,
                cache_ttl = 30000,
            },
            recent_edits = { enabled = false },
        },
    }
    local original_get_clients = vim.lsp.get_clients
    local bufnr = helpers.create_buffer({
        'local renamedField = 1',
        'local unrelated = true',
        'return renamedField',
    }, { 1, 0 })
    vim.bo[bufnr].buftype = ''
    vim.api.nvim_buf_set_name(bufnr, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'semantic-fixture.lua'))
    package.loaded['minuet.duet.edits'] = {
        get_events = function()
            return {
                {
                    bufnr = bufnr,
                    diff = table.concat({
                        '--- old',
                        '+++ new',
                        '@@ -1 +1 @@',
                        '-local oldField = 1',
                        '+local renamedField = oldField',
                        '+return if true then renamedField',
                    }, '\n'),
                },
            }
        end,
    }
    local symbols = helpers.reload 'minuet.duet.symbols'
    local ok, err = xpcall(function()
        run { bufnr = bufnr, symbols = symbols }
    end, debug.traceback)
    symbols.reset()
    vim.lsp.get_clients = original_get_clients
    helpers.delete_buffer(bufnr)
    if not ok then
        error(err)
    end
end

return {
    {
        name = 'duet symbols extracts bounded diff identifiers and local text matches',
        run = function()
            with_symbols(function(fixture)
                local identifiers = fixture.symbols._extract_identifiers(fixture.bufnr, 8)
                helpers.expect_equal(identifiers, { 'renamedField', 'oldField' })
                local matches = fixture.symbols._text_matches(fixture.bufnr, identifiers, 8, 64)
                helpers.expect_equal(
                    vim.tbl_map(function(item)
                        return { item.row, item.col, item.name }
                    end, matches),
                    {
                        { 0, 6, 'renamedField' },
                        { 2, 7, 'renamedField' },
                    }
                )
                helpers.expect_falsy(vim.tbl_contains(identifiers, 'local'))
                helpers.expect_falsy(vim.tbl_contains(identifiers, 'return'))
            end)
        end,
    },
    {
        name = 'duet symbols resolves same-buffer references and reuses same-version cache',
        run = function()
            with_symbols(function(fixture)
                local calls = {}
                local next_id = 0
                local client = {
                    id = 91,
                    name = 'fixture-lsp',
                    root_dir = vim.fn.getcwd(),
                    supports_method = function(_, method)
                        return method == 'textDocument/documentSymbol'
                            or method == 'textDocument/references'
                            or method == 'textDocument/definition'
                    end,
                    request = function(_, method, _, handler)
                        next_id = next_id + 1
                        calls[#calls + 1] = method
                        vim.schedule(function()
                            if method == 'textDocument/documentSymbol' then
                                handler(nil, {
                                    {
                                        name = 'renamedField',
                                        kind = 13,
                                        selectionRange = { start = { line = 0, character = 6 } },
                                    },
                                })
                            elseif method == 'textDocument/references' then
                                handler(nil, {
                                    {
                                        uri = vim.uri_from_bufnr(fixture.bufnr),
                                        range = { start = { line = 2, character = 7 } },
                                    },
                                    {
                                        uri = vim.uri_from_fname(vim.fs.joinpath(vim.fn.getcwd(), 'other.lua')),
                                        range = { start = { line = 9, character = 1 } },
                                    },
                                })
                            else
                                handler(nil, {
                                    uri = vim.uri_from_fname(vim.fs.joinpath(vim.fn.getcwd(), 'defs.lua')),
                                    range = { start = { line = 3, character = 0 } },
                                })
                            end
                        end)
                        return true, next_id
                    end,
                    cancel_request = function() end,
                }
                vim.lsp.get_clients = function()
                    return { client }
                end

                local result
                fixture.symbols.collect(fixture.bufnr, function(value)
                    result = value
                end)
                helpers.wait_until(function()
                    return result ~= nil
                end, 500)
                helpers.expect_equal(result.references, {
                    { row = 2, col = 7, name = 'renamedField' },
                })
                helpers.expect_equal(result.definitions, {
                    { path = 'defs.lua', row = 3, name = 'renamedField' },
                })
                helpers.expect_equal(calls, {
                    'textDocument/documentSymbol',
                    'textDocument/references',
                    'textDocument/definition',
                })

                local cached
                fixture.symbols.collect(fixture.bufnr, function(value)
                    cached = value
                end)
                helpers.expect_truthy(cached)
                helpers.expect_equal(#calls, 3)
                cached.references[1].row = 99
                local third
                fixture.symbols.collect(fixture.bufnr, function(value)
                    third = value
                end)
                helpers.expect_equal(third.references[1].row, 2)

                vim.api.nvim_buf_set_lines(fixture.bufnr, 1, 2, false, { 'local changed = true' })
                local refreshed
                fixture.symbols.collect(fixture.bufnr, function(value)
                    refreshed = value
                end)
                helpers.wait_until(function()
                    return refreshed ~= nil
                end, 500)
                helpers.expect_equal(#calls, 6)
            end)
        end,
    },
    {
        name = 'duet symbols shares one in-flight pipeline across same-version callers',
        run = function()
            with_symbols(function(fixture)
                local handler
                local requests = 0
                vim.lsp.get_clients = function()
                    return {
                        {
                            id = 93,
                            name = 'shared-lsp',
                            supports_method = function(_, method)
                                return method == 'textDocument/documentSymbol'
                            end,
                            request = function(_, _, _, callback)
                                requests = requests + 1
                                handler = callback
                                return true, 21
                            end,
                            cancel_request = function() end,
                        },
                    }
                end
                local first
                local second
                fixture.symbols.collect(fixture.bufnr, function(value)
                    first = value
                end)
                fixture.symbols.collect(fixture.bufnr, function(value)
                    second = value
                end)
                helpers.expect_equal(requests, 1)
                handler(nil, {})
                helpers.expect_truthy(first)
                helpers.expect_truthy(second)
                first.identifiers[1] = 'mutated'
                helpers.expect_falsy(vim.deep_equal(first.identifiers, second.identifiers))
            end)
        end,
    },
    {
        name = 'duet symbols times out cancels requests and fences late callbacks',
        run = function()
            with_symbols(function(fixture)
                local handler
                local cancelled = 0
                vim.lsp.get_clients = function()
                    return {
                        {
                            id = 92,
                            name = 'slow-lsp',
                            supports_method = function(_, method)
                                return method == 'textDocument/documentSymbol'
                            end,
                            request = function(_, _, _, callback)
                                handler = callback
                                return true, 17
                            end,
                            cancel_request = function(_, request_id)
                                helpers.expect_equal(request_id, 17)
                                cancelled = cancelled + 1
                            end,
                        },
                    }
                end
                local callbacks = 0
                local result
                fixture.symbols.collect(fixture.bufnr, function(value)
                    callbacks = callbacks + 1
                    result = value
                end)
                helpers.wait_until(function()
                    return result ~= nil
                end, 500)
                helpers.expect_equal(result.timed_out, true)
                helpers.expect_equal(cancelled, 1)
                handler(nil, {})
                vim.wait(20)
                helpers.expect_equal(callbacks, 1)
            end)
        end,
    },
    {
        name = 'duet symbols maps only safe loaded workspace references without opening URIs',
        run = function()
            with_symbols(function(fixture)
                local target = helpers.create_buffer({ 'a😀renamedField' }, { 1, 0 })
                vim.bo[target].buftype = ''
                vim.api.nvim_buf_set_name(target, vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'cross-symbol.lua'))
                local secret = helpers.create_buffer({ 'renamedField' }, { 1, 0 })
                vim.bo[secret].buftype = ''
                vim.api.nvim_buf_set_name(secret, vim.fs.joinpath(vim.fn.getcwd(), 'tests', '.env'))
                vim.api.nvim_set_current_buf(fixture.bufnr)
                local unopened_uri = vim.uri_from_fname(vim.fs.joinpath(vim.fn.getcwd(), 'tests', 'not-loaded.lua'))
                local buffer_count = #vim.api.nvim_list_bufs()
                local next_id = 0
                vim.lsp.get_clients = function()
                    return {
                        {
                            id = 94,
                            name = 'cross-lsp',
                            root_dir = vim.fn.getcwd(),
                            offset_encoding = 'utf-16',
                            supports_method = function(_, method)
                                return method == 'textDocument/documentSymbol' or method == 'textDocument/references'
                            end,
                            request = function(_, method, _, handler)
                                next_id = next_id + 1
                                vim.schedule(function()
                                    if method == 'textDocument/documentSymbol' then
                                        handler(nil, {
                                            {
                                                name = 'renamedField',
                                                kind = 13,
                                                selectionRange = { start = { line = 0, character = 6 } },
                                            },
                                        })
                                    else
                                        handler(nil, {
                                            {
                                                uri = vim.uri_from_bufnr(target),
                                                range = { start = { line = 0, character = 3 } },
                                            },
                                            {
                                                uri = vim.uri_from_bufnr(secret),
                                                range = { start = { line = 0, character = 0 } },
                                            },
                                            {
                                                uri = unopened_uri,
                                                range = { start = { line = 0, character = 0 } },
                                            },
                                        })
                                    end
                                end)
                                return true, next_id
                            end,
                            cancel_request = function() end,
                        },
                    }
                end

                local result
                fixture.symbols.collect(fixture.bufnr, function(value)
                    result = value
                end, { related_buffers = true })
                helpers.wait_until(function()
                    return result ~= nil
                end, 500)
                helpers.expect_equal(result.related_references, {
                    {
                        bufnr = target,
                        row = 0,
                        col = 5,
                        path = 'tests/cross-symbol.lua',
                        name = 'renamedField',
                    },
                })
                helpers.expect_equal(#vim.api.nvim_list_bufs(), buffer_count)

                fixture.symbols.invalidate(target)
                local refreshed
                fixture.symbols.collect(fixture.bufnr, function(value)
                    refreshed = value
                end, { related_buffers = true })
                helpers.wait_until(function()
                    return refreshed ~= nil
                end, 500)
                helpers.expect_equal(next_id, 4)

                helpers.delete_buffer(secret)
                helpers.delete_buffer(target)
            end)
        end,
    },
}
