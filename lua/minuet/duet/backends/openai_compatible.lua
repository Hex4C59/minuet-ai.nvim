local base = require 'minuet.duet.backends.openai_base'
local utils = require 'minuet.duet.utils'

local M = {}

M.provider_id = 'openai_compatible'

local notified_on_endpoint = false

function M.complete(context, callback, lifecycle)
    local options = vim.deepcopy(require('minuet').config.duet.provider_options.openai_compatible)

    if not notified_on_endpoint and not options.end_point:find 'chat' then
        utils.notify('Minuet duet expects an OpenAI-compatible chat endpoint.', 'warn', vim.log.levels.WARN)
        notified_on_endpoint = true
    end

    options.provider_id = M.provider_id
    options.provider = 'openai_compatible'
    options.name = options.name or 'OpenAI Compatible'
    options.api_key_error =
        'Minuet duet OpenAI-compatible API key is not set, or the configured environment variable is missing.'

    base.complete_openai_base(options, context, callback, lifecycle)
end

return M
