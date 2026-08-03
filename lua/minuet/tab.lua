local M = {}

---@return boolean handled
function M.accept()
    return require('minuet.suggestion').accept_visible()
end

---@param fallback? string|fun(): string
---@return string
function M.accept_or_fallback(fallback)
    if M.accept() then
        return ''
    end

    if type(fallback) == 'function' then
        return fallback()
    end
    if type(fallback) == 'string' then
        return fallback
    end
    return '<Tab>'
end

return M
