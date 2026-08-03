local base = require 'minuet.backends.openai_base'
local utils = require 'minuet.utils'

local M = {}

M.provider_id = 'openai'

M.is_available = function()
    local config = require('minuet').config
    return utils.get_api_key(config.provider_options.openai.api_key) and true or false
end

if not M.is_available() then
    utils.notify('OpenAI API key is not set', 'error', vim.log.levels.ERROR)
end

M.complete = function(context, callback, lifecycle)
    local config = require('minuet').config
    local options = vim.deepcopy(config.provider_options.openai)
    options.provider_id = M.provider_id
    options.provider = 'openai_compatible'
    options.name = 'OpenAI'

    base.complete_openai_base(options, context, callback, lifecycle)
end

return M
