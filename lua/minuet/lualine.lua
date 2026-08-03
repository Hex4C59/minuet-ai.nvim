local M = require('lualine.component'):extend()

M.processing = false
M.spinner_index = 1
M.n_requests = 1
M.n_finished_requests = 0
M.provider = nil
M.model = nil
M.current_cycle_id = nil
M.finished_request_ids = {}

local default_options = {
    -- the symbols that are used to create spinner animation
    spinner_symbols = {
        '⠋',
        '⠙',
        '⠹',
        '⠸',
        '⠼',
        '⠴',
        '⠦',
        '⠧',
        '⠇',
        '⠏',
    },
    -- the name displayed in the lualine. Set to "provider", "model" or "both"
    display_name = 'both',
    -- separator between provider and model name for option "both"
    provider_model_separator = ':',
    -- whether show display_name when no completion requests are active
    display_on_idle = false,
}

-- Initializer
function M:init(options)
    M.super.init(self, options)
    self.options = vim.tbl_extend('keep', self.options or {}, default_options)
    self.spinner_symbols_len = #self.options.spinner_symbols

    local group = vim.api.nvim_create_augroup('MinuetLualine', { clear = true })

    vim.api.nvim_create_autocmd({ 'User' }, {
        pattern = 'MinuetRequestStartedPre',
        group = group,
        callback = function(request)
            local data = request.data or {}
            self.processing = false
            self.current_cycle_id = data.cycle_id
            self.finished_request_ids = {}
            self.n_requests = type(data.n_requests) == 'number' and data.n_requests > 0 and data.n_requests or 1
            self.n_finished_requests = 0

            local provider = type(data.name) == 'string' and data.name ~= '' and data.name or nil
            provider = provider or (type(data.provider) == 'string' and data.provider ~= '' and data.provider or nil)
            provider = provider
                or (type(data.provider_id) == 'string' and data.provider_id ~= '' and data.provider_id or nil)
            local model = type(data.model) == 'string' and data.model ~= '' and data.model or nil
            local fallback = provider or model or 'Minuet'
            self.provider = provider or fallback
            self.model = model or fallback

            if self.options.display_name == 'model' then
                self.display_name = self.model
            elseif self.options.display_name == 'provider' then
                self.display_name = self.provider
            elseif provider and model then
                self.display_name = provider .. self.options.provider_model_separator .. model
            else
                self.display_name = fallback
            end
        end,
    })

    vim.api.nvim_create_autocmd({ 'User' }, {
        pattern = 'MinuetRequestStarted',
        group = group,
        callback = function(request)
            local data = request.data or {}
            if data.cycle_id ~= nil and data.cycle_id ~= self.current_cycle_id then
                return
            end
            self.processing = true
        end,
    })

    vim.api.nvim_create_autocmd({ 'User' }, {
        pattern = 'MinuetRequestFinished',
        group = group,
        callback = function(request)
            local data = request.data or {}
            if data.cycle_id ~= nil and data.cycle_id ~= self.current_cycle_id then
                return
            end
            if data.request_id ~= nil then
                if self.finished_request_ids[data.request_id] then
                    return
                end
                self.finished_request_ids[data.request_id] = true
            end

            self.n_finished_requests = self.n_finished_requests + 1
            if self.n_finished_requests >= self.n_requests then
                self.processing = false
            end
        end,
    })
end

-- Function that runs every time statusline is updated
function M:update_status()
    if self.processing then
        self.spinner_index = (self.spinner_index % self.spinner_symbols_len) + 1
        local request = self.display_name or 'Minuet'
        if self.n_requests > 1 then
            request = request .. ' ' .. string.format('(%s/%s)', self.n_finished_requests + 1, self.n_requests)
        end
        return request .. ' ' .. self.options.spinner_symbols[self.spinner_index]
    else
        return self.options.display_on_idle and self.display_name or nil
    end
end

return M
