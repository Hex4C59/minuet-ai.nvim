local api = vim.api

local guards = require 'minuet.duet.guards'

local M = {}

---@param path string
---@return string
local function without_extension(path)
    return (path:gsub('%.d%.ts$', ''):gsub('%.[^/%.]+$', ''):gsub('/index$', ''):gsub('/init$', ''))
end

---@param bufnr integer
---@return table<string, boolean>
local function import_targets(bufnr)
    local targets = {}
    for _, line in ipairs(api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        for module in line:gmatch [=[require%s*%(%s*['"]([%w_%.%-%/]+)['"]%s*%)]=] do
            targets[module:gsub('%.', '/')] = true
        end
        for module in line:gmatch [=[require%s*['"]([%w_%.%-%/]+)['"]]=] do
            targets[module:gsub('%.', '/')] = true
        end
        local relative = line:match [=[from%s+['"]([%.%/][^'"]+)['"]]=]
            or line:match [=[import%s+['"]([%.%/][^'"]+)['"]]=]
            or line:match [=[require%s*%(%s*['"]([%.%/][^'"]+)['"]%s*%)]=]
        if relative then
            targets[relative] = true
        end
        local python = line:match '^%s*from%s+([%.]+[%w_%.]+)%s+import%s+'
        if python and vim.startswith(python, '.') then
            local dots, module = python:match '^(%.+)(.*)$'
            targets[string.rep('../', math.max(#dots - 1, 0)) .. module:gsub('%.', '/')] = true
        end
    end
    return targets
end

---@param bufnr integer
---@param max_chars integer
---@return string
function M.render(bufnr, max_chars)
    local config = require('minuet').config.duet.context.related_files
    if not config.enabled or max_chars <= 0 then
        return ''
    end
    local root, current_relative = guards.workspace_path(bufnr)
    if not root then
        return ''
    end
    local targets = import_targets(bufnr)
    if vim.tbl_isempty(targets) then
        return ''
    end

    local current_dir = vim.fs.dirname(current_relative)
    local max_buffer_size = require('minuet').config.duet.recent_edits.max_buffer_size
    local matches = {}
    for _, target_bufnr in ipairs(api.nvim_list_bufs()) do
        if target_bufnr ~= bufnr and guards.is_safe_buffer(target_bufnr, true, max_buffer_size) then
            local relative = guards.relative_path(root, api.nvim_buf_get_name(target_bufnr))
            if relative then
                local normalized = without_extension(relative)
                for target in pairs(targets) do
                    local resolved = target
                    if vim.startswith(target, '.') then
                        resolved = vim.fs.normalize(vim.fs.joinpath(current_dir, target))
                    end
                    resolved = without_extension(resolved)
                    if normalized == resolved or vim.endswith(normalized, '/' .. resolved) then
                        matches[#matches + 1] = { bufnr = target_bufnr, path = relative }
                        break
                    end
                end
            end
        end
    end
    table.sort(matches, function(left, right)
        return left.path < right.path
    end)

    local chunks = {}
    local used = 0
    local max_files = math.min(math.max(config.max_files or 0, 0), 16)
    local per_file = math.min(math.max(config.per_file_max_chars or 0, 0), max_chars)
    for index = 1, math.min(#matches, max_files) do
        local match = matches[index]
        local path = match.path:gsub('[<>&"]', '_')
        local text = table.concat(api.nvim_buf_get_lines(match.bufnr, 0, -1, false), '\n')
        text = vim.fn.strcharpart(text, 0, per_file)
        local chunk = ('<related_file path="%s">\n%s\n</related_file>'):format(path, text)
        local remaining = max_chars - used
        if vim.fn.strchars(chunk) > remaining then
            break
        end
        chunks[#chunks + 1] = chunk
        used = used + vim.fn.strchars(chunk) + 1
    end
    return table.concat(chunks, '\n')
end

M._import_targets = import_targets

return M
