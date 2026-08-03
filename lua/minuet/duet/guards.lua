local api = vim.api

local M = {}

---@param path string
---@return boolean
function M.is_secret_path(path)
    local tail = vim.fn.fnamemodify(path, ':t'):lower()
    return tail == '.env'
        or vim.startswith(tail, '.env.')
        or tail == '.netrc'
        or tail == '.npmrc'
        or tail == '.pypirc'
        or tail == 'credentials'
        or tail == 'credentials.json'
        or tail == 'service-account.json'
        or tail == 'id_rsa'
        or tail == 'id_ed25519'
        or tail:match '%.pem$' ~= nil
        or tail:match '%.key$' ~= nil
        or tail:match '%.p12$' ~= nil
        or tail:match '%.pfx$' ~= nil
end

---@param bufnr integer
---@param require_listed? boolean
---@param max_size? integer
---@return boolean
function M.is_safe_buffer(bufnr, require_listed, max_size)
    local safe = type(bufnr) == 'number'
        and api.nvim_buf_is_valid(bufnr)
        and api.nvim_buf_is_loaded(bufnr)
        and vim.bo[bufnr].buftype == ''
        and not vim.bo[bufnr].binary
        and (not require_listed or vim.bo[bufnr].buflisted)
        and not M.is_secret_path(api.nvim_buf_get_name(bufnr))
    if not safe then
        return false
    end
    if type(max_size) == 'number' and max_size >= 0 then
        local line_count = api.nvim_buf_line_count(bufnr)
        local ok, size = pcall(api.nvim_buf_get_offset, bufnr, line_count)
        return ok and size <= max_size
    end
    return true
end

---@param root string
---@param path string
---@return string?
function M.relative_path(root, path)
    if root == '' or path == '' then
        return nil
    end
    root = vim.fs.normalize(root)
    path = vim.fs.normalize(path)
    local prefix = root:sub(-1) == '/' and root or root .. '/'
    if path == root then
        return vim.fn.fnamemodify(path, ':t')
    end
    if not vim.startswith(path, prefix) then
        return nil
    end
    local relative = path:sub(#prefix + 1)
    if relative == '' or relative == '..' or vim.startswith(relative, '../') then
        return nil
    end
    return relative
end

---@param bufnr integer
---@return string?, string
function M.workspace_path(bufnr)
    local path = api.nvim_buf_get_name(bufnr)
    if path == '' then
        return nil, '[No Name]'
    end

    local roots = {}
    local ok, clients = pcall(vim.lsp.get_clients, { bufnr = bufnr })
    for _, client in ipairs(ok and clients or {}) do
        if type(client.root_dir) == 'string' then
            roots[#roots + 1] = client.root_dir
        end
        for _, folder in ipairs(type(client.workspace_folders) == 'table' and client.workspace_folders or {}) do
            if type(folder.uri) == 'string' then
                local converted, root = pcall(vim.uri_to_fname, folder.uri)
                if converted then
                    roots[#roots + 1] = root
                end
            end
        end
    end
    roots[#roots + 1] = vim.fn.getcwd()
    table.sort(roots, function(left, right)
        return #left > #right
    end)
    for _, root in ipairs(roots) do
        local relative = M.relative_path(root, path)
        if relative then
            return vim.fs.normalize(root), relative
        end
    end
    return nil, vim.fn.fnamemodify(path, ':t')
end

---@param value string
---@return string
function M.safe_label(value)
    return tostring(value):gsub('[\r\n<>]', '_')
end

---@param uri string
---@param root string?
---@return string?
function M.uri_path(uri, root)
    if type(uri) ~= 'string' or not vim.startswith(uri, 'file://') then
        return nil
    end
    local ok, path = pcall(vim.uri_to_fname, uri)
    if not ok or M.is_secret_path(path) then
        return nil
    end
    return root and M.relative_path(root, path) or vim.fn.fnamemodify(path, ':t')
end

return M
