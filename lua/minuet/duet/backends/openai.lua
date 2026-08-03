local base = require 'minuet.duet.backends.openai_base'
local utils = require 'minuet.duet.utils'

local M = {}

M.provider_id = 'openai'

function M.complete(context, callback, lifecycle)
    local options = vim.deepcopy(require('minuet').config.duet.provider_options.openai)

    options.provider_id = M.provider_id
    options.provider = 'openai'
    options.name = 'OpenAI'
    options.api_key_error = 'Minuet duet OpenAI API key is not set.'

    base.complete_openai_base(options, context, callback, lifecycle)
end

return M
