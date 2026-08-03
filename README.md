- [Minuet](#minuet)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick Start](#quick-start)
  - [Virtual Text Setup](#virtual-text-setup)
  - [Nvim-cmp setup](#nvim-cmp-setup)
  - [Blink-cmp Setup](#blink-cmp-setup)
  - [In-Process LSP for Built-in Completion and Inline Completion](#in-process-lsp-for-built-in-completion-and-inline-completion)
    - [Completion](#completion)
    - [Inline completion](#inline-completion)
  - [LLM Provider Examples](#llm-provider-examples)
    - [Openrouter deepseek-v4-flash](#openrouter-deepseek-v4-flash)
    - [Opencode Go deepseek-v4-flash](#opencode-go-deepseek-v4-flash)
    - [Deepseek deepseek-v4-flash](#deepseek-deepseek-v4-flash)
    - [Ollama Qwen-2.5-coder:7b](#ollama-qwen-25-coder7b)
    - [Llama.cpp Qwen-2.5-coder:1.5b](#llamacpp-qwen-25-coder15b)
- [Selecting a Provider or Model](#selecting-a-provider-or-model)
  - [Understanding Model Speed](#understanding-model-speed)
- [Configuration](#configuration)
- [API Keys](#api-keys)
- [Prompt](#prompt)
  - [Prefix-First vs. Suffix-First](#prefix-first-vs-suffix-first)
- [Providers](#providers)
  - [OpenAI](#openai)
  - [Claude](#claude)
  - [Codestral](#codestral)
  - [Mercury Coder](#mercury-coder)
  - [Gemini](#gemini)
  - [OpenAI-compatible](#openai-compatible)
  - [OpenAI-FIM-compatible](#openai-fim-compatible)
    - [Non-OpenAI-FIM-Compatible APIs](#non-openai-fim-compatible-apis)
- [Commands](#commands)
  - [`Minuet change_provider`, `Minuet change_model`](#minuet-change_provider-minuet-change_model)
  - [`Minuet change_preset`](#minuet-change_preset)
  - [`Minuet blink`, `Minuet cmp`](#minuet-blink-minuet-cmp)
  - [`Minuet virtualtext`](#minuet-virtualtext)
  - [`Minuet duet`](#minuet-duet)
  - [`Minuet stats`](#minuet-stats)
  - [`Minuet report`](#minuet-report)
  - [`Minuet lsp`](#minuet-lsp)
- [Duet (Next Edit Prediction)](#duet-next-edit-prediction)
  - [Automatic Prediction and Tab](#automatic-prediction-and-tab)
  - [Recent Edits](#recent-edits)
  - [TODO](#todo)
  - [Default Config](#default-config)
- [API](#api)
  - [Virtual Text](#virtual-text)
  - [Duet](#duet)
  - [Unified Tab](#unified-tab)
  - [Session Metrics](#session-metrics)
  - [Offline Quality Report](#offline-quality-report)
  - [Lualine](#lualine)
  - [Minuet Event](#minuet-event)
    - [Standard Completion Events](#standard-completion-events)
    - [Duet Events](#duet-events)
    - [Suggestion Lifecycle](#suggestion-lifecycle)
    - [Event Data](#event-data)
- [FAQ](#faq)
  - [Customize `cmp` ui for source icon and kind icon](#customize-cmp-ui-for-source-icon-and-kind-icon)
  - [Customize `blink` ui for source icon and kind icon](#customize-blink-ui-for-source-icon-and-kind-icon)
  - [Significant Input Delay When Moving to a New Line with `nvim-cmp`](#significant-input-delay-when-moving-to-a-new-line-with-nvim-cmp)
  - [Integration with `lazyvim`](#integration-with-lazyvim)
- [Enhancement](#enhancement)
  - [RAG (Experimental)](#rag-experimental)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [Acknowledgement](#acknowledgement)

# Minuet

Minuet: Dance with Intelligence in Your Code 💃.

`Minuet` brings the grace and harmony of a minuet to your coding process.
Just as dancers move during a minuet.

# Features

- AI-powered code completion with dual modes:
  - Specialized prompts and various enhancements for chat-based LLMs on code completion tasks.
  - Fill-in-the-middle (FIM) completion for compatible models (DeepSeek,
    Codestral, Qwen, and others).
- Support for multiple AI providers (OpenAI, Claude, Gemini, Codestral, Ollama,
  Llama-cpp, and OpenAI-compatible services).
- Customizable configuration options.
- Streaming support to enable completion delivery even with slower LLMs.
- No proprietary binary running in the background. Just curl and your preferred LLM provider.
- Support `virtual-text`, `nvim-cmp`, `blink-cmp`, `built-in`,
  `mini.completion` frontend.
- Act as an **in-process LSP** server to provide completions (opt-in feature).
- Accept multi-line suggestions line-by-line, so longer suggestions can be
  pulled in incrementally in your own pace.
- When your typed text matches the start of a suggestion, Minuet keeps the
  completion in sync of your typed text rather than discarding it, to reduce
  unnecessary LLM requests and conserving resources.
- Support next-edit prediction (NES) via `Minuet duet` commands. This feature
  is highly experimental.

**With nvim-cmp / blink-cmp frontend**:

![example-cmp](./assets/example-cmp.png)

**With builtin completion frontend** (requires nvim 0.11+):

![example-builtin-completion](./assets/example-builtin-completion.jpg)

**With virtual text frontend**:

![example-virtual-text](./assets/example-virtual-text.png)

https://github.com/user-attachments/assets/e0c4f2bd-0361-45b4-8eb4-0f49356bd7d9

**With duet (next-edit prediction)**:

https://github.com/user-attachments/assets/b98699d5-b81d-4061-a1b3-d6f581c6b9b0

<!-- The link above is a showcase video for the virtual text feature, hosted -->
<!-- externally on GitHub. -->

# Requirements

- Neovim 0.10+.
- optional: [nvim-cmp](https://github.com/hrsh7th/nvim-cmp)
- optional: [blink.cmp](https://github.com/Saghen/blink.cmp)
- An API key for at least one of the supported AI providers
- ~~[plenary.nvim](https://github.com/nvim-lua/plenary.nvim)~~ Minuet now uses
  the builtin `vim.system` and no longer requires plenary.

# Installation

**Lazy.nvim**:

```lua
specs = {
    {
        'milanglacier/minuet-ai.nvim',
        config = function()
            require('minuet').setup {
                -- Your configuration options here
            }
        end,
    },
    -- optional, if you are using virtual-text frontend, nvim-cmp is not
    -- required.
    { 'hrsh7th/nvim-cmp' },
    -- optional, if you are using virtual-text frontend, blink is not required.
    { 'Saghen/blink.cmp' },
}
```

**Rocks.nvim**:

`Minuet` is available on luarocks.org. Simply run `Rocks install minuet-ai.nvim` to install it like any other luarocks package.

# Quick Start

## Virtual Text Setup

```lua
require('minuet').setup {
    virtualtext = {
        auto_trigger_ft = {},
        keymap = {
            -- accept whole completion
            accept = '<A-A>',
            -- accept one line
            accept_line = '<A-a>',
            -- accept n lines (prompts for number)
            -- e.g. "A-z 2 CR" will accept 2 lines
            accept_n_lines = '<A-z>',
            -- Cycle to prev completion item, or manually invoke completion
            prev = '<A-[>',
            -- Cycle to next completion item, or manually invoke completion
            next = '<A-]>',
            dismiss = '<A-e>',
        },
    },
}
```

## Nvim-cmp setup

<details>

```lua
require('cmp').setup {
    sources = {
        {
             -- Include minuet as a source to enable autocompletion
            { name = 'minuet' },
            -- and your other sources
        }
    },
    performance = {
        -- It is recommended to increase the timeout duration due to
        -- the typically slower response speed of LLMs compared to
        -- other completion sources. This is not needed when you only
        -- need manual completion.
        fetching_timeout = 2000,
    },
}


-- If you wish to invoke completion manually,
-- The following configuration binds `A-y` key
-- to invoke the configuration manually.
require('cmp').setup {
    mapping = {
        ["<A-y>"] = require('minuet').make_cmp_map()
        -- and your other keymappings
    },
}
```

</details>

## Blink-cmp Setup

<details>

```lua
require('blink-cmp').setup {
    keymap = {
        -- Manually invoke minuet completion.
        ['<A-y>'] = require('minuet').make_blink_map(),
    },
    sources = {
         -- Enable minuet for autocomplete
        default = { 'lsp', 'path', 'buffer', 'snippets', 'minuet' },
        -- For manual completion only, remove 'minuet' from default
        providers = {
            minuet = {
                name = 'minuet',
                module = 'minuet.blink',
                async = true,
                -- Should match minuet.config.request_timeout * 1000,
                -- since minuet.config.request_timeout is in seconds
                timeout_ms = 3000,
                score_offset = 50, -- Gives minuet higher priority among suggestions
            },
        },
    },
    -- Recommended to avoid unnecessary request
    completion = { trigger = { prefetch_on_insert = false } },
}
```

</details>

## In-Process LSP for Built-in Completion and Inline Completion

<details>

**Requirements:**

- Neovim version 0.11 or higher is necessary for built-in completion.
- Neovim version 0.12 or higher is necessary for `vim.lsp.inline_completion`.

**Note:**

`config.lsp.completion.enable` and `config.lsp.inline_completion.enable` are
setup-time options. Minuet decides which LSP capabilities to expose when
`require('minuet').setup()` runs, so changing either option later will not
enable the feature for an already-running Minuet LSP server.

If you might want to use one of these features later in the same session,
enable it during setup first, then control only its per-buffer auto-trigger
behavior at runtime.

### Completion

```lua
require('minuet').setup {
    lsp = {
        enabled_ft = { 'toml', 'lua', 'cpp' },
        completion = {
            -- Enables automatic completion triggering using `vim.lsp.completion.enable`
            enabled_auto_trigger_ft = { 'cpp', 'lua' },
        },
    }
}
```

The `completion.enabled_auto_trigger_ft` setting is relevant only for built-in
completion (`vim.lsp.completion`). `Mini.Completion` users can ignore this
option, as Mini.Completion uses **all** available LSPs for **auto-triggered**
completion.

For manually triggered completion, ensure `vim.bo.omnifunc` is set to
`v:lua.vim.lsp.omnifunc` and use `<C-x><C-o>` in Insert mode.

**Recommendation:**

For users of `blink-cmp` and `nvim-cmp`, it is recommended to use the native
source rather than through LSP for two main reasons:

1. `blink-cmp` and `nvim-cmp` offer better sorting and async management when
   Minuet is utilized as a separate source rather than alongside a regular LSP
   such as `clangd`.
2. With `blink-cmp` and `nvim-cmp` native sources, it's possible to configure
   Minuet for manual completion only, disabling automatic completion. However,
   when Minuet operates as an LSP server, it is impossible to determine whether
   completion is triggered automatically or manually.

   The LSP protocol specification defines three `triggerKind` values:
   `Invoked`, `TriggerCharacter`, and `TriggerForIncompleteCompletions`.
   However, none of these specifically differentiates between manual and
   automatic completion requests.

**Note**:

- An upstream issue ([tracked
  here](https://github.com/neovim/neovim/issues/32972)) may cause unexpected
  indentation behavior when accepting multi-line completions.

  Currently, Minuet offers the config option `config.lsp.completion.adjust_indentation`
  (enabled by default) as a temporary workaround. However, the author
  acknowledges that this solution is incomplete and may introduce additional edge
  cases when enabled.

  Therefore, consider the following practices when using built-in completion:
  - Ensure `config.add_single_line_entry = true` and only accept single-line completions.
  - Avoid using Minuet and built-in completion with languages where indentation
    affects semantics, such as Python.

- Users might call `vim.lsp.completion.enable {autotrigger = true}` during
  the `LspAttach` event when the client supports completion. However, this is
  not the desired behavior for Minuet. As an LLM completion source, Minuet can
  face significant rate limits during automatic triggering.

  Therefore, it's recommended to enable Minuet for automatic triggering using
  the `config.lsp.completion.enabled_auto_trigger_ft` setting.

  For users who uses `LspAttach` event, it is recommeded to verify that the
  server is not the Minuet server before enabling autotrigger. An example
  configuration is shown below:

```lua
vim.api.nvim_create_autocmd('LspAttach', {
    callback = function(args)
        local client_id = args.data.client_id
        local bufnr = args.buf
        local client = vim.lsp.get_client_by_id(client_id)
        if not client then
            return
        end

        if client.server_capabilities.completionProvider and client.name ~= 'minuet' then
            vim.lsp.completion.enable(true, client_id, bufnr, { autotrigger = true })
        end
    end,
    desc = 'Enable built-in auto completion',
})
```

### Inline completion

Minuet can also expose suggestions through Neovim's built-in
`vim.lsp.inline_completion` interface:

```lua
require('minuet').setup {
    lsp = {
        enabled_ft = { 'toml', 'lua', 'cpp' },
        -- It is recommended to disable completion when use inline_completion
        completion = { enable = false },
        inline_completion = {
            enable = true,
            enabled_auto_trigger_ft = { 'cpp', 'lua' },
        },
    },
}

vim.keymap.set('i', '<A-x>', function()
    vim.lsp.inline_completion.get()
end, { desc = 'accept' })
vim.keymap.set('i', '<A-c>', function()
    vim.lsp.inline_completion.select { count = 1 }
end, { desc = 'cycle to next' })
vim.keymap.set('i', '<A-v>', function()
    vim.lsp.inline_completion.select { count = -1 }
end, { desc = 'cycle to prev' })
```

If you prefer not to use inline completion at startup but still want the option
to enable it for specific buffers later, set
`config.lsp.inline_completion.enable = true` during setup and leave
`config.lsp.inline_completion.enabled_auto_trigger_ft` empty. You can then
enable it at runtime for the current buffer with: `:Minuet lsp
inline_completion enable_auto_trigger`.

**Recommendation:**

If you want inline suggestions, Minuet's own `virtualtext` frontend is still
the **recommended** choice. Neovim's built-in `inline_completion` support is a
useful baseline, but in practice it only covers automatic triggering. Minuet's
`virtualtext` frontend supports a much more comprehensive workflow: it supports
both manual invocation and automatic triggering, keeps suggestions in sync as
you continue typing, and lets you accept longer suggestions incrementally,
including accepting only part of a completion instead of the entire
suggestion at once.

When using LSP inline completion, avoid enabling Minuet `virtualtext` at the
same time.

</details>

## LLM Provider Examples

### Openrouter deepseek-v4-flash

<details>

```lua
require('minuet').setup {
    provider = 'openai_compatible',
    request_timeout = 2.5,
    throttle = 1500, -- Increase to reduce costs and avoid rate limits
    debounce = 600, -- Increase to reduce costs and avoid rate limits
    provider_options = {
        openai_compatible = {
            api_key = 'OPENROUTER_API_KEY',
            end_point = 'https://openrouter.ai/api/v1/chat/completions',
            model = 'deepseek/deepseek-v4-flash',
            name = 'Openrouter',
            optional = {
                max_tokens = 56,
                top_p = 0.9,
                provider = {
                     -- Prioritize throughput for faster completion
                    sort = 'throughput',
                },
                -- disable thinking to avoid first token latency
                reasoning_effort = 'none'
            },
        },
    },
}
```

</details>

### Opencode Go deepseek-v4-flash

<details>

```lua
require('minuet').setup {
    provider = 'openai_compatible',
    request_timeout = 2.5,
    throttle = 1500, -- Increase to reduce costs and avoid rate limits
    debounce = 600, -- Increase to reduce costs and avoid rate limits
    provider_options = {
        openai_compatible = {
            api_key = 'OPENCODE_GO_API_KEY',
            end_point = 'https://opencode.ai/zen/go/v1/chat/completions',
            model = 'deepseek-v4-flash',
            name = 'Opencode',
            optional = {
                max_tokens = 56,
                top_p = 0.9,
                -- disable thinking to avoid first token latency
                thinking = { type = 'disabled' },
            },
        },
    },
}
```

</details>

### Deepseek deepseek-v4-flash

<details>

```lua
require('minuet').setup {
    provider = 'openai_fim_compatible',
    provider_options = {
        openai_fim_compatible = {
            api_key = 'DEEPSEEK_API_KEY',
            name = 'deepseek',
            optional = {
                max_tokens = 256,
                top_p = 0.9,
            },
        },
    },
}
```

</details>

### Ollama Qwen-2.5-coder:7b

<details>

```lua
require('minuet').setup {
    provider = 'openai_fim_compatible',
    n_completions = 1, -- recommend for local model for resource saving
    -- I recommend beginning with a small context window size and incrementally
    -- expanding it, depending on your local computing power. A context window
    -- of 512, serves as an good starting point to estimate your computing
    -- power. Once you have a reliable estimate of your local computing power,
    -- you should adjust the context window to a larger value.
    context_window = 512,
    provider_options = {
        openai_fim_compatible = {
            -- For Windows users, TERM may not be present in environment variables.
            -- Consider using APPDATA instead.
            api_key = 'TERM',
            name = 'Ollama',
            end_point = 'http://localhost:11434/v1/completions',
            model = 'qwen2.5-coder:7b',
            optional = {
                max_tokens = 56,
                top_p = 0.9,
            },
        },
    },
}
```

</details>

### Llama.cpp Qwen-2.5-coder:1.5b

<details>

First, launch the `llama-server` with your chosen model.

Here's an example of a bash script to start the server if your system has less
than 8GB of VRAM:

```bash
llama-server \
    -hf ggml-org/Qwen2.5-Coder-1.5B-Q8_0-GGUF \
    --port 8012 -ngl 99 -fa -ub 1024 -b 1024 \
    --ctx-size 0 --cache-reuse 256
```

```lua
require('minuet').setup {
    provider = 'openai_fim_compatible',
    n_completions = 1, -- recommend for local model for resource saving
    -- I recommend beginning with a small context window size and incrementally
    -- expanding it, depending on your local computing power. A context window
    -- of 512, serves as an good starting point to estimate your computing
    -- power. Once you have a reliable estimate of your local computing power,
    -- you should adjust the context window to a larger value.
    context_window = 512,
    provider_options = {
        openai_fim_compatible = {
            -- For Windows users, TERM may not be present in environment variables.
            -- Consider using APPDATA instead.
            api_key = 'TERM',
            name = 'Llama.cpp',
            end_point = 'http://localhost:8012/v1/completions',
            -- The model is set by the llama-cpp server and cannot be altered
            -- post-launch.
            model = 'PLACEHOLDER',
            optional = {
                max_tokens = 56,
                top_p = 0.9,
            },
            -- Llama.cpp does not support the `suffix` option in FIM completion.
            -- Therefore, we must disable it and manually populate the special
            -- tokens required for FIM completion.
            template = {
                prompt = function(context_before_cursor, context_after_cursor, _)
                    return '<|fim_prefix|>'
                        .. context_before_cursor
                        .. '<|fim_suffix|>'
                        .. context_after_cursor
                        .. '<|fim_middle|>'
                end,
                suffix = false,
            },
        },
    },
}
```

**NOTE**: Special tokens such as `<|fim_prefix|>` vary across different models.
The example code provided uses the tokens specific to `Qwen-2.5-coder`. If you
intend to use a different model, ensure the `llama-cpp` template is updated to
reflect the corresponding special tokens for your chosen model.

For additional example bash scripts to run llama.cpp based on your local
computing power, please refer to [recipes.md](./recipes.md).

</details>

# Selecting a Provider or Model

The `gemini-2.0-flash` and `codestral` models offer high-quality output with
free and fast processing. The `deepseek-v4-flash` model, used with the
`openai_fim_compatible` provider, is an alternative for low-cost APIs and fast
inference. For local LLM inference, you can deploy either `qwen-2.5-coder` or
`deepseek-coder-v2` through Ollama using the `openai-fim-compatible` provider.

We **do not** recommend using thinking models, as this mode significantly
increases latency—even with the fastest models. However, if you choose to use
thinking models, please ensure that their thinking capabilities are disabled.
Refer to the following examples for guidance on how to disable the thinking
feature.

## Understanding Model Speed

For cloud-based providers,
[Openrouter](https://openrouter.ai/google/gemini-2.0-flash-001/providers)
offers a valuable resource for comparing the speed of both closed-source and
open-source models hosted by various cloud inference providers.

When assessing model speed, two key metrics are latency (time to first token)
and throughput (tokens per second). Latency is often a more critical factor
than throughput.

Ideally, one would aim for a latency of less than 1 second and a throughput
exceeding 100 tokens per second.

For local LLM,
[llama.cpp#4167](https://github.com/ggml-org/llama.cpp/discussions/4167)
provides valuable data on model speed for 7B models running on Apple M-series
chips. The two crucial metrics are `Q4_0 PP [t/s]`, which measures latency
(tokens per second to process the KV cache, equivalent to the time to generate
the first token), and `Q4_0 TG [t/s]`, which indicates the tokens per second
generation speed.

# Configuration

Minuet AI comes with the following defaults:

```lua
default_config = {
    -- Enable or disable auto-completion. Note that you still need to add
    -- Minuet to your cmp/blink sources. This option controls whether cmp/blink
    -- will attempt to invoke minuet when minuet is included in cmp/blink
    -- sources. This setting has no effect on manual completion; Minuet will
    -- always be enabled when invoked manually. You can use the command
    -- `Minuet cmp/blink toggle` to toggle this option.
    cmp = {
        enable_auto_complete = true,
    },
    blink = {
        enable_auto_complete = true,
    },
    -- Session-local request and suggestion metrics. Metrics remain in memory
    -- unless the optional JSONL logger is explicitly enabled.
    metrics = {
        enabled = true,
        max_tracked_cycles = 4096,
        max_latency_samples = 2048,
        jsonl = {
            enabled = false,
            -- nil uses stdpath('state')/minuet/metrics-<session>.jsonl
            path = nil,
            flush_interval = 1000,
            max_queue = 256,
            max_file_size = 10 * 1024 * 1024,
        },
    },
    -- LSP is recommended only for built-in completion. If you are using
    -- `cmp` or `blink`, utilizing LSP for code completion from Minuet is *not*
    -- recommended.
    lsp = {
        enabled_ft = {},
        -- Filetypes excluded from LSP activation. Useful when `enabled_ft` = { '*' }
        disabled_ft = {},
        completion = {
            enable = true,
            -- if true, warn the user that they should use the native source
            -- instead when the user is using blink or nvim-cmp.
            warn_on_blink_or_cmp = true,
            -- See README In-Process LSP section for more details on this option.
            adjust_indentation = true,
            -- Enables automatic completion triggering using `vim.lsp.completion.enable`
            enabled_auto_trigger_ft = {},
            -- Filetypes excluded from autotriggering. Useful when `enabled_auto_trigger_ft` = { '*' }
            disabled_auto_trigger_ft = {},
        },
        -- Minuet's own virtualtext frontend is recommended **over** lsp.inline_completion
        inline_completion = {
            enable = false,
            -- if true, warn when LSP inline completion is enabled while
            -- Minuet virtual text is also configured for use.
            warn_on_virtualtext = true,
            -- if true, warn when both LSP completion and inline completion
            -- are enabled. Enabling only one of them is recommended.
            warn_on_lsp_completion = true,
            -- Enables automatic inline completion using `vim.lsp.inline_completion.enable`
            -- for these filetypes.
            enabled_auto_trigger_ft = {},
            -- Filetypes excluded from inline completion autotriggering.
            disabled_auto_trigger_ft = {},
        },
    },
    virtualtext = {
        -- Specify the filetypes to enable automatic virtual text completion,
        -- e.g., { 'python', 'lua' }. Note that you can still invoke manual
        -- completion even if the filetype is not on your auto_trigger_ft list.
        auto_trigger_ft = {},
        -- specify file types where automatic virtual text completion should be
        -- disabled. This option is useful when auto-completion is enabled for
        -- all file types i.e., when auto_trigger_ft = { '*' }
        auto_trigger_ignore_ft = {},
        keymap = {
            accept = nil,
            accept_line = nil,
            accept_n_lines = nil,
            -- Cycle to next completion item, or manually invoke completion
            next = nil,
            -- Cycle to prev completion item, or manually invoke completion
            prev = nil,
            dismiss = nil,
        },
        -- Whether show virtual text suggestion when the completion menu
        -- (nvim-cmp or blink-cmp) is visible.
        show_on_completion_menu = false,
    },
    provider = 'codestral',
    -- the maximum total characters of the context before and after the cursor
    -- 16000 characters typically equate to approximately 4,000 tokens for
    -- LLMs.
    context_window = 16000,
    -- when the total characters exceed the context window, the ratio of
    -- context before cursor and after cursor, the larger the ratio the more
    -- context before cursor will be used. This option should be between 0 and
    -- 1, context_ratio = 0.75 means the ratio will be 3:1.
    context_ratio = 0.75,
    throttle = 1000, -- only send the request every x milliseconds, use 0 to disable throttle.
    -- debounce the request in x milliseconds, set to 0 to disable debounce
    debounce = 400,
    -- Control notification display for request status
    -- Notification options:
    -- false: Disable all notifications (use boolean false, not string "false")
    -- "debug": Display all notifications (comprehensive debugging)
    -- "verbose": Display most notifications
    -- "warn": Display warnings and errors only
    -- "error": Display errors only
    notify = 'warn',
    -- The request timeout, measured in seconds. When streaming is enabled
    -- (stream = true), setting a shorter request_timeout allows for faster
    -- retrieval of completion items, albeit potentially incomplete.
    -- Conversely, with streaming disabled (stream = false), a timeout
    -- occurring before the LLM returns results will yield no completion items.
    request_timeout = 3,
    -- Command used to make HTTP requests.
    curl_cmd = 'curl',
    -- Extra arguments passed to curl (list of strings, or a function returning a list of strings).
    curl_extra_args = {},
    -- If completion item has multiple lines, create another completion item
    -- only containing its first line. This option only has impact for cmp and
    -- blink. For virtualtext, no single line entry will be added.
    add_single_line_entry = true,
    -- The number of completion items encoded as part of the prompt for the
    -- chat LLM. For FIM model, this is the number of requests to send. It's
    -- important to note that when 'add_single_line_entry' is set to true, the
    -- actual number of returned items may exceed this value. Additionally, the
    -- LLM cannot guarantee the exact number of completion items specified, as
    -- this parameter serves only as a prompt guideline.
    n_completions = 3,
    --  Length of context after cursor used to filter completion text.
    --
    -- This setting helps prevent the language model from generating redundant
    -- text.  When filtering completions, the system compares the suffix of a
    -- completion candidate with the text immediately following the cursor.
    --
    -- If the length of the longest common substring between the end of the
    -- candidate and the beginning of the post-cursor context exceeds this
    -- value, that common portion is trimmed from the candidate.
    --
    -- For example, if the value is 15, and a completion candidate ends with a
    -- 20-character string that exactly matches the 20 characters following the
    -- cursor, the candidate will be truncated by those 20 characters before
    -- being delivered.

    -- The default is 0 for FIM model, and 15 for chat model
    after_cursor_filter_length = function() end,
    -- Similar to after_cursor_filter_length but trim the completion item from
    -- prefix instead of suffix.
    --
    -- Note: FIM completions do not strip surrounding whitespace by default.
    -- Their default filter lengths are 0 because FIM models emit intentional
    -- leading/trailing whitespace. Setting positive filter lengths keeps
    -- duplicate context filtering enabled for FIM completions.
    --
    -- The default is 0 for FIM model, and 2 for chat model
    before_cursor_filter_length = function() end,
    -- proxy port to use
    proxy = nil,
    -- **List** of functions to execute. If any function returns `false`, Minuet
    -- will not trigger auto-completion. Manual completion can still be invoked,
    -- even if these functions evaluate to `false`, when using `nvim-cmp`,
    -- `blink-cmp`, or virtual text (excluding LSP).
    -- When this list is empty (the default), it always evaluates to `true`.
    -- Note that this is called each time Minuet attempts to trigger
    -- auto-completion, so ensure the functions in this list are highly efficient.
    enable_predicates = {},
    provider_options = {
        -- see the documentation in each provider in the following part.
    },
    -- see the documentation in the `Prompt` section
    default_system = {
        template = '...',
        prompt = '...',
        guidelines = '...',
        n_completion_template = '...',
    },
    default_system_prefix_first = {
        template = '...',
        prompt = '...',
        guidelines = '...',
        n_completion_template = '...',
    },
    default_fim_template = {
        prompt = '...',
        suffix = '...',
    },
    default_few_shots = { '...' },
    default_chat_input = { '...' },
    default_few_shots_prefix_first = { '...' },
    default_chat_input_prefix_first = { '...' },
    -- Config options for `Minuet change_preset` command
    presets = {}
}
```

# API Keys

Minuet AI requires API keys to function. Set the following environment variables:

- `OPENAI_API_KEY` for OpenAI
- `GEMINI_API_KEY` for Gemini
- `ANTHROPIC_API_KEY` for Claude
- `CODESTRAL_API_KEY` for Codestral
- `DEEPSEEK_API_KEY` for DeepSeek
- Custom environment variable for OpenAI-compatible services (as specified in your configuration)

**Note:** Provide the name of the environment variable to Minuet, not the
actual value. For instance, pass `OPENAI_API_KEY` to Minuet, not the value
itself (e.g., `sk-xxxx`).

If using Ollama, you need to assign an arbitrary, non-null environment variable
as a placeholder for it to function.

Alternatively, you can provide a function that returns the API key. This
function should return the result instantly as it will be called for each
completion request.

```lua
require('minuet').setup {
    provider_options = {
        openai_compatible = {
            -- good
            api_key = 'FIREWORKS_API_KEY', -- will read the environment variable FIREWORKS_API_KEY
            -- good
            api_key = function() return 'sk-xxxx' end,
            -- bad
            api_key = 'sk-xxxx',
        }
    }
}
```

# Prompt

See [prompt](./prompt.md) for the default prompt used by `minuet` and
instructions on customization.

Note that `minuet` employs two distinct prompt systems:

1. A system designed for chat-based LLMs (OpenAI, OpenAI-Compatible, Claude,
   and Gemini)
2. A separate system designed for Codestral and OpenAI-FIM-compatible models

## Prefix-First vs. Suffix-First

When use chat-based LLMs, there are two ways for constructing the prompt:
placing the prefix (context before the cursor) before the suffix (context after
the cursor), or placing the suffix before the prefix.

By default, `minuet` uses the **prefix-first** style for the OpenAI, Gemini,
and OpenAI-Compatible (with `deepseek-v4-flash` as the default model)
providers, and the **suffix-first** style for Claude providers. It is
recommended that you experiment with both strategies to determine which yields
the best results, particularly if you are using an OpenAI-compatible provider
with various models.

Below is an example code snippet demonstrating how to switch between these two
prompt construction methods:

<details>

```lua
local mc = require 'minuet.config'

-- Prefix-first style
require('minuet').setup {
    provider_options = {
        openai_compatible = {
            system = mc.default_system_prefix_first,
            chat_input = mc.default_chat_input_prefix_first,
            few_shots = mc.default_few_shots_prefix_first,
        },
    },
}

-- Suffix-first style
require('minuet').setup {
    provider_options = {
        openai_compatible = {
            system = mc.default_system,
            few_shots = mc.default_few_shots,
            chat_input = mc.default_chat_input,
        },
    },
}
```

</details>

# Providers

You need to set the field `provider` in the config, the default provider is
`codestral`. For example:

```lua
require('minuet').setup {
    provider = 'gemini'
}
```

## OpenAI

<details>

the following is the default configuration for OpenAI:

```lua
provider_options = {
    openai = {
        model = 'gpt-5.6-luna',
        end_point = 'https://api.openai.com/v1/chat/completions',
        system = "see [Prompt] section for the default value",
        few_shots = "see [Prompt] section for the default value",
        chat_input = "See [Prompt Section for default value]",
        stream = true,
        api_key = 'OPENAI_API_KEY',
        optional = {
            -- pass any additional parameters you want to send to OpenAI request,
            -- e.g.
            -- stop = { 'end' },
            -- max_completion_tokens = 256,
            -- top_p = 0.9,
            -- reasoning_effort = 'none'
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
}
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lua
provider_options = {
	openai = {
		optional = {
			max_completion_tokens = 128,
			-- for thinking models
			reasoning_effort = 'none'
			-- reasoning_effort = "minimal",
			-- Set to "minimal" if your chosen model doesn't support "none"
		},
	},
}
```

Note: If you intend to use GPT-5 series models (e.g., `gpt-5-mini` or
`gpt-5.6-luna`), keep the following points in mind:

1. Use `max_completion_tokens` instead of `max_tokens`.
2. These models do not support `top_p` or `temperature` adjustments.
3. Disable thinking by setting `reasoning_effort` to `none`, or use `minimal`
   if your chosen model does not support `none`.

</details>

## Claude

<details>

the following is the default configuration for Claude:

```lua
provider_options = {
    claude = {
        max_tokens = 256,
        model = 'claude-haiku-4.5',
        system = "see [Prompt] section for the default value",
        few_shots = "see [Prompt] section for the default value",
        chat_input = "See [Prompt Section for default value]",
        stream = true,
        api_key = 'ANTHROPIC_API_KEY',
        end_point = 'https://api.anthropic.com/v1/messages',
        optional = {
            -- pass any additional parameters you want to send to claude request,
            -- e.g.
            -- stop_sequences = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
}
```

</details>

## Codestral

<details>

Codestral is a text completion model, not a chat model, so the system prompt
and few shot examples does not apply. Note that you should use the
`CODESTRAL_API_KEY`, not the `MISTRAL_API_KEY`, as they are using different
endpoint. To use the Mistral endpoint, simply modify the `end_point` and
`api_key` parameters in the configuration.

the following is the default configuration for Codestral:

```lua
provider_options = {
    codestral = {
        model = 'codestral-latest',
        end_point = 'https://codestral.mistral.ai/v1/fim/completions',
        api_key = 'CODESTRAL_API_KEY',
        stream = true,
        template = {
            prompt = "See [Prompt Section for default value]",
            suffix = "See [Prompt Section for default value]",
        },
        optional = {
            stop = nil, -- the identifier to stop the completion generation
            max_tokens = nil,
        },
    },
}
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lua
provider_options = {
    codestral = {
        optional = {
            max_tokens = 256,
            stop = { '\n\n' },
        },
    },
}
```

</details>

## Mercury Coder

Developed by Inception, Mercury Coder is described as a diffusion-based large
language model that accelerates code generation through iterative refinement
rather than autoregressive token prediction. According to the claim, this
approach is intended to deliver faster and more efficient code completions. To
begin, obtain an API key from the Inception Platform and configure it as the
`INCEPTION_API_KEY` environment variable.

<details>

You can access Mercury Coder via the OpenAI compatible FIM endpoint using the
following configuration:

```lua
provider_options = {
    openai_fim_compatible = {
        model = "mercury-coder",
        end_point = "https://api.inceptionlabs.ai/v1/fim/completions",
        api_key = "INCEPTION_API_KEY", -- environment variable name
        stream = true,
    },
}
```

</details>

## Gemini

You should register the account and use the service from Google AI Studio
instead of Google Cloud. You can get an API key via their
[Google API page](https://makersuite.google.com/app/apikey).

<details>

The following config is the default.

```lua
provider_options = {
    gemini = {
        model = 'gemini-2.0-flash',
        system = "see [Prompt] section for the default value",
        few_shots = "see [Prompt] section for the default value",
        chat_input = "See [Prompt Section for default value]",
        stream = true,
        api_key = 'GEMINI_API_KEY',
        end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
        optional = {},
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    },
}
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens. You can also adjust the safety
settings following the example:

```lua
provider_options = {
    gemini = {
        optional = {
            generationConfig = {
                maxOutputTokens = 256,
                thinkingConfig = {
                    -- Disable thinking for gemini 2.5 models
                    thinkingBudget = 0,
                    -- Disable thinking for gemini 3.x models
                    thinkingLevel = 'minimal',
                    -- Setting only one of the above options is sufficient.
                },
            },
            safetySettings = {
                {
                    -- HARM_CATEGORY_HATE_SPEECH,
                    -- HARM_CATEGORY_HARASSMENT
                    -- HARM_CATEGORY_SEXUALLY_EXPLICIT
                    category = 'HARM_CATEGORY_DANGEROUS_CONTENT',
                    -- BLOCK_NONE
                    threshold = 'BLOCK_ONLY_HIGH',
                },
            },
        },
    },
}
```

We recommend using `gemini-2.0-flash` over `gemini-2.5-flash`, as the 2.0
version offers significantly lower costs with comparable performance. The
primary improvement in version 2.5 lies in its extended thinking mode, which
provides minimal value for code completion scenarios. Furthermore, the thinking
mode substantially increases latency, so we recommend disabling it entirely.

</details>

## OpenAI-compatible

Use any providers compatible with OpenAI's chat completion API.

For example, you can set the `end_point` to
`http://localhost:11434/v1/chat/completions` to use `ollama`.

<details>

Note that not all openAI compatible services has streaming support, you should
change `stream=false` to disable streaming in case your services do not support
it.

The following config is the default.

```lua
provider_options = {
    openai_compatible = {
        model = 'deepseek/deepseek-v4-flash',
        system = "see [Prompt] section for the default value",
        few_shots = "see [Prompt] section for the default value",
        chat_input = "See [Prompt Section for default value]",
        stream = true,
        end_point = 'https://openrouter.ai/api/v1/chat/completions',
        api_key = 'OPENROUTER_API_KEY',
        name = 'Openrouter',
        optional = {
            stop = nil,
            max_tokens = nil,
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
    }
}
```

**Disabling thinking for reasoning models:**

| Provider             | Configuration                                                              |
| -------------------- | -------------------------------------------------------------------------- |
| **OpenRouter**       | `reasoning = { effort = 'none' }` (or `'minimal'`, depending on the model) |
| **DeepSeek API**     | `thinking = { type = 'disabled' }`                                         |
| **Various Provider** | `reasoning_effort = 'none'`                                                |

```lua
provider_options = {
    openai_compatible = {
        optional = {
            -- Disable thinking for reasoning models
            reasoning = { effort = 'none' }, -- or "minimal", depending on the model (OpenRouter)
            -- reasoning_effort = 'none', -- or "minimal", depending on the model (various providers)
            -- thinking = { type = 'disabled' } -- DeepSeek API
        },
    },
}
```

</details>

## OpenAI-FIM-compatible

Use any provider compatible with OpenAI's completion API. This request uses the
text `/completions` endpoint, **not** `/chat/completions` endpoint, so system
prompts and few-shot examples are not applicable.

For example, you can set the `end_point` to
`http://localhost:11434/v1/completions` to use `ollama`,
`http://localhost:8012/v1/completions` to use `llama.cpp`.

Cmdline completion is available for models supported by these providers:
`deepseek`, `ollama`, and `siliconflow`.

<details>

Refer to the [Completions
Legacy](https://platform.openai.com/docs/api-reference/completions) section of
the OpenAI documentation for details.

Please note that not all OpenAI-compatible services support streaming. If your
service does not support streaming, you should set `stream=false` to disable
it.

Additionally, for Ollama users, it is essential to verify whether the model's
template supports FIM completion. For example, qwen2.5-coder offers FIM
support, as suggested in its
[template](https://ollama.com/library/qwen2.5-coder/blobs/e94a8ecb9327).
However it may come as a surprise to some users that, `deepseek-coder` does not
support the FIM template, and you should use `deepseek-coder-v2` instead.

For example bash scripts to run llama.cpp based on your local
computing power, please refer to [recipes.md](./recipes.md). Note
that the model for `llama.cpp` must be determined when you launch the
`llama.cpp` server and cannot be changed thereafter.

```lua
provider_options = {
    openai_fim_compatible = {
        model = 'deepseek-v4-flash',
        end_point = 'https://api.deepseek.com/beta/completions',
        api_key = 'DEEPSEEK_API_KEY',
        name = 'Deepseek',
        stream = true,
        template = {
            prompt = "See [Prompt Section for default value]",
            suffix = "See [Prompt Section for default value]",
        },
        -- a list of functions to transform the endpoint, header, and request body
        transform = {},
        -- Custom function to extract LLM-generated text from JSON output
        get_text_fn = {}
        optional = {
            stop = nil,
            max_tokens = nil,
        },
    }
}
```

The following configuration is not the default, but recommended to prevent
request timeout from outputing too many tokens.

```lua
provider_options = {
    openai_fim_compatible = {
        optional = {
            max_tokens = 256,
            stop = { '\n\n' },
        },
    },
}
```

</details>

### Non-OpenAI-FIM-Compatible APIs

For providers like **DeepInfra FIM**
(`https://api.deepinfra.com/v1/inference/`), refer to
[recipes.md](./recipes.md) for advanced configuration instructions.

# Commands

## `Minuet change_provider`, `Minuet change_model`

The `change_provider` command allows you to change the provider after `Minuet`
has been setup.

Example usage: `Minuet change_provider claude`

The `change_model` command allows you to change both the provider and model in
one command. When called without arguments, it will open an interactive
selection menu using `vim.ui.select` to choose from available models. When
called with an argument, the format is `provider:model`.

Example usage:

- `Minuet change_model` - Opens interactive model selection
- `Minuet change_model gemini:gemini-1.5-pro-latest` - Directly sets the model

Note: For `openai_compatible` and `openai_fim_compatible` providers, the model
completions in cmdline are determined by the `name` field in your
configuration. For example, if you configured:

```lua
provider_options.openai_compatible.name = 'Fireworks'
```

When entering `Minuet change_model openai_compatible:` in the cmdline,
you'll see model completions specific to the Fireworks provider.

## `Minuet change_preset`

The `change_preset` command allows you to switch between config presets that
were defined during initial setup. Presets provide a convenient way to toggle
between different config sets. This is particularly useful when you need to:

- Switch between different cloud providers (such as Fireworks or Groq) for the
  `openai_compatible` provider
- Apply different throttle and debounce settings for different providers

When called, the command merges the selected preset with the current config
table to create an updated configuration.

Usage syntax: `Minuet change_preset preset_1`

Presets can be configured during the initial setup process.

<details>

```lua
require('minuet').setup {
    presets = {
        preset_1 = {
            -- Configuration for cloud-based requests with large context window
            context_window = 20000,
            request_timeout = 4,
            throttle = 3000,
            debounce = 1000,
            provider = 'openai_compatible',
            provider_options = {
                openai_compatible = {
                    model = 'llama-3.3-70b-versatile',
                    api_key = 'GROQ_API_KEY',
                    name = 'Groq'
                }
            }
        },
        preset_2 = {
            -- Configuration for local model with smaller context window
            provider = 'openai_fim_compatible',
            context_window = 2000,
            throttle = 400,
            debounce = 100,
            provider_options = {
                openai_fim_compatible = {
                    api_key = 'TERM',
                    name = 'Ollama',
                    end_point = 'http://localhost:11434/v1/completions',
                    model = 'qwen2.5-coder:7b',
                    optional = {
                        max_tokens = 256,
                        top_p = 0.9
                    }
                }
            }
        }
    }
}
```

</details>

## `Minuet blink`, `Minuet cmp`

Enable or disable autocompletion for `nvim-cmp` or `blink.cmp`. While Minuet
must be added to your cmp/blink sources, this command only controls whether
Minuet is triggered during autocompletion. The command does not affect manual
completion behavior - Minuet remains active and available when manually
invoked.

Example usage: `Minuet blink toggle`, `Minuet blink enable`, `Minuet blink disable`

## `Minuet virtualtext`

Enable or disable the automatic display of `virtual-text` completion in the
**current buffer**.

Example usage: `Minuet virtualtext toggle`, `Minuet virtualtext enable`,
`Minuet virtualtext disable`.

## `Minuet duet`

The Minuet duet command provides manual next-edit prediction controls:

- `:Minuet duet predict`: Request an NES prediction for the current editable
  region and show it as a preview.
- `:Minuet duet apply`: Apply the current duet prediction.
- `:Minuet duet dismiss`: Dismiss the current duet prediction preview.

## `Minuet stats`

`Minuet stats` shows request counts and latency, suggestion lifecycle counts,
and the visible suggestion acceptance rate for the current Neovim session.
Suggestion display and acceptance are tracked only for Minuet's virtual text
and Duet frontends; cmp, Blink, and LSP expose request metrics only.

## `Minuet report`

`Minuet report` aggregates Duet lifecycle JSONL across Neovim sessions. With no
path argument it reads the configured `metrics.jsonl.path`, or the standard
session-file glob when no fixed path is configured. Exact paths and glob
patterns may also be supplied:

```vim
:Minuet report
:Minuet report /path/to/minuet/metrics-*.jsonl
```

The report deduplicates lifecycle records, checks schema and cycle integrity,
and shows progress toward both the 100-visible early-review gate and the
500-visible release-review gate. It includes allowlisted filtered and reverted
counts, but never prints input paths or fields outside the metrics allowlist.
Reaching either count does not prove the data came from real editing;
provenance and safety must still be reviewed before tuning or release decisions.

## `Minuet lsp`

The Minuet LSP command provides commands for managing the in-process LSP server:

- `:Minuet lsp attach`: Attach the Minuet LSP server to the **current buffer**.
- `:Minuet lsp detach`: Detach the Minuet LSP server from the **current buffer**.
- `:Minuet lsp completion enable_auto_trigger`: Enable auto-triggered `vim.lsp.completion` for the **current buffer**.
- `:Minuet lsp completion disable_auto_trigger`: Disable auto-triggered `vim.lsp.completion` for the **current buffer**.
- `:Minuet lsp inline_completion enable_auto_trigger`: Enable `vim.lsp.inline_completion` auto-triggering for the **current buffer**.
- `:Minuet lsp inline_completion disable_auto_trigger`: Disable `vim.lsp.inline_completion` auto-triggering for the **current buffer**.

# Duet (Next Edit Prediction)

`Minuet duet` is Minuet's highly experimental next-edit prediction (NES)
feature.

Basic usage is manual. By default, Duet ranks candidate rows in the current
buffer from the cursor, recent edit hunks, Neovim's cached diagnostics, local
identifier matches, and references returned by already attached LSP clients.
LSP work is asynchronous and deadline-bounded; it never starts a language
server. Cross-buffer edit targets remain disabled by default. Bind the duet
commands to your preferred keymaps, then:

1. Trigger `:Minuet duet predict` to request a prediction for the current edit.
2. Review the preview rendered in the buffer. A remote edit initially shows a
   `Next edit: line N` hint and a `>>` sign at the target.
3. Apply it with `:Minuet duet apply` or discard it with
   `:Minuet duet dismiss`.

With the default `jump_requires_confirmation = true`, applying a remote edit is
a two-step action. The first apply validates the suggestion, moves the cursor,
and reveals the diff without changing the buffer. The second apply validates it
again and writes the edit. Local suggestions still apply in one step. The same
behavior is used by `require('minuet.tab')`; no mapping is installed by Minuet.
Diagnostic messages, paths, and candidate scores are not shown or written to
metrics.

To opt in to a single related-buffer target, set both `scope = 'workspace'`
and `candidates.related_buffers = true`. Only LSP references into safe,
modifiable, already loaded and listed buffers under the same workspace are
eligible. Duet never opens a referenced URI. A cross-buffer suggestion always
uses two applies: the first preserves unsaved origin changes, switches through
the normal Buffer/jumplist path, and reveals the diff; the second revalidates
both buffers and writes only the target. It does not save either buffer.

The provider context includes the current workspace-relative path, filetype,
bounded recently changed identifiers, bounded nearby diagnostic messages, and
the session-wide recent-edit history described below. That history may contain
bounded unified-diff snippets from other tracked buffers and workspaces. Full
source from another buffer is not included unless
`duet.context.related_files.enabled` is explicitly enabled; even then, only
safe, already loaded buffers matched by a literal relative import/require are
eligible. These values are not persisted by Minuet.

Example keymaps:

```lua
vim.keymap.set('n', '<leader>mp', '<cmd>Minuet duet predict<cr>', { desc = 'Minuet duet predict' })
vim.keymap.set('n', '<leader>ma', '<cmd>Minuet duet apply<cr>', { desc = 'Minuet duet apply' })
vim.keymap.set('n', '<leader>md', '<cmd>Minuet duet dismiss<cr>', { desc = 'Minuet duet dismiss' })
vim.keymap.set('i', '<A-z>', '<cmd>Minuet duet predict<cr>', { desc = 'Minuet duet predict' })
vim.keymap.set('i', '<A-a>', '<cmd>Minuet duet apply<cr>', { desc = 'Minuet duet apply' })
vim.keymap.set('i', '<A-x>', '<cmd>Minuet duet dismiss<cr>', { desc = 'Minuet duet dismiss' })
```

The recommended model at the moment is `gemini-3-flash-preview`.

```lua
require('minuet').setup {
    duet = {
        provider = 'gemini',
        provider_options = {
            gemini = {
                model = 'gemini-3-flash-preview',
                optional = {
                    generationConfig = {
                        thinkingConfig = {
                            -- Disable thinking is recommended
                            thinkingLevel = 'minimal',
                        },
                    },
                },
            },
            openai_compatible = {
                model = 'google/gemini-3.1-flash-lite',
                optional = {
                    -- Disable thinking is recommended.
                    reasoning_effort = 'none',
                    -- prioritize throughput for faster completion
                    provider = {
                        sort = 'throughput',
                    },
                },
            },
        },
    },
}
```

This feature is highly experimental:

- It only targets general-purpose LLMs rather than NES-specialized models, as I
  lack local GPU resources for testing.
- Comparable small models from competitors of Google—`claude-haiku-4.5` and
  `gpt-5.4-mini`—perform poorly.
- Automatic prediction is available, but remains opt-in while its quality and
  latency are evaluated on real editing sessions.

It is recommended to configure the thinking levels of the models; refer to the
[provider sections](#providers) for guidance on managing thinking settings for
each provider.

Avoid setting a small `max_tokens` or `max_completion_tokens` limit for duet
requests. Duet expects the model to return the complete rewritten editable
region, including the cursor marker; if the response is truncated, the parser
will reject it. Leave the limit unset when the provider allows that, or set it
large enough to cover the full rewritten region.

## Automatic Prediction and Tab

Automatic Duet prediction is disabled by default. Enabling it sends a request
after an eligible edit settles, so it can increase provider charges and network
traffic. The scheduler debounces edits, throttles requests, and suppresses
automatic requests while a Minuet Virtual Text or Duet suggestion is visible.

The following example opts in and uses DeepSeek's Chat Completions endpoint.
`DEEPSEEK_API_KEY` is the environment variable name, not the key value:

```lua
require('minuet').setup {
    duet = {
        provider = 'openai_compatible',
        auto_trigger = {
            enabled = true,
            debounce = 900,
            throttle = 1500,
            -- Optional declarative overrides. Unspecified fields inherit the
            -- global debounce/throttle; Minuet provides no language presets.
            filetype = {
                lua = { debounce = 700, throttle = 1200 },
                markdown = { debounce = 1600, throttle = 2500 },
            },
        },
        quality = {
            undo_window = 10000,
            max_pending_undo = 64,
            repeat_suppression = {
                enabled = true,
                ttl = 30000,
                max_entries = 128,
            },
        },
        provider_options = {
            openai_compatible = {
                model = 'deepseek-v4-flash',
                end_point = 'https://api.deepseek.com/chat/completions',
                api_key = 'DEEPSEEK_API_KEY',
                name = 'Deepseek',
                optional = {
                    thinking = { type = 'disabled' },
                },
            },
        },
    },
}
```

To collect a cross-session quality cohort, enable the allowlisted JSONL logger
with a new dedicated file. Do not mix test, smoke, or synthetic records into a
real-workflow cohort:

```lua
local quality_log = vim.fs.joinpath(vim.fn.stdpath 'state', 'minuet', 'cursor-tab-quality.jsonl')

require('minuet').setup {
    metrics = {
        jsonl = {
            enabled = true,
            path = quality_log,
        },
    },
    duet = {
        auto_trigger = {
            enabled = true,
        },
    },
}
```

Run `:Minuet report` periodically. A visible suggestion is counted once per
Duet cycle, and the report includes accepted, reverted, dismissed, stale,
filtered, unresolved, parse-failed, request-outcome, and P50/P95 latency totals.
The JSONL records contain only allowlisted enums, IDs, counters, and timings;
they do not contain source text, prompts, responses, paths, identifiers,
diagnostics, filetypes, headers, endpoints, or credentials. Files are created
with private permissions where supported, stay local, and are never uploaded.
Enabling JSONL alone does not trigger provider requests; automatic Duet remains
a separate opt-in.

Use a different exact path for every baseline or variant cohort. After closing
Neovim, delete the configured cohort with `vim.fn.delete(quality_log)` from a
trusted Neovim session, or remove that exact file with your normal file manager.
Do not mix test, smoke, benchmark, or synthetic records into it.

Minuet does not create a `<Tab>` mapping. To accept either a visible Duet or
Virtual Text suggestion and otherwise insert Tab, add an expression mapping:

```lua
vim.keymap.set('i', '<Tab>', function()
    return require('minuet.tab').accept_or_fallback()
end, { expr = true, replace_keycodes = true, desc = 'Minuet accept or Tab' })
```

Users with an existing completion, snippet, or indentation chain should keep
that behavior in the fallback function:

```lua
vim.keymap.set('i', '<Tab>', function()
    return require('minuet.tab').accept_or_fallback(function()
        -- Run your existing completion/snippet logic here and return its keys.
        return '<Tab>'
    end)
end, { expr = true, replace_keycodes = true, desc = 'Minuet accept or fallback' })
```

The single-suggestion controller covers only Minuet Virtual Text and Duet.
cmp, Blink, LSP completion, and LSP inline completion keep their own UI and Tab
behavior.

## Recent Edits

Duet silently records your recent edits in the background and includes them in
the prompt, providing the model with the signal needed to predict the next
edit: what you just changed. `recent_edits.enabled` controls when the recorder
runs:

- `'lazy'` (default): recording starts at your first duet prediction, so users
who only use inline completion runs no background overhead. Edits made before
the first prediction are not recorded, so the first prediction of a session has
an empty edit history.
- `true`: recording starts at plugin setup, so even the first prediction
carries the session's edit history.
- `false`: the recorder is disabled entirely.

The recorder keeps one bounded history for the current Neovim session. It is
shared across all eligible buffers and is not partitioned by workspace, current
working directory, or `duet.scope`; consequently, a Duet prompt can include
unified-diff snippets from another buffer or workspace visited since recording
started. `duet.scope` controls prediction target selection only. Use
`recent_edits.enable_predicates`, disable the recorder, or use separate Neovim
sessions when edits from different workspaces must remain isolated.

To prevent sensitive buffers from being tracked in the edit history, configure
`recent_edits.enable_predicates` with a list of functions, each receiving a
buffer number. A buffer is only tracked while all predicates return true. If a
buffer is rejected, it is never snapshotted to disk. The default rejects binary
buffers, dotenv files (`.env`, `.env.*`), `.netrc`, `.npmrc`, `.pypirc`, common
credential basenames, SSH private-key basenames, and `.pem`, `.key`, `.p12`, or
`.pfx` files. Because predicates run on every trackability check, ensure they
are highly efficient.

`auto_trigger.enable_predicates` has an independent copy of the same default
guard. It protects only automatic Duet requests. Manual Duet, Virtual Text,
cmp, Blink, and LSP requests still send the current context when explicitly
triggered, so users must avoid invoking them in sensitive buffers. Replacing
one predicate list does not replace the other, and neither list is a complete
secret detector.

Example:

```lua
recent_edits = {
    enable_predicates = {
        function(bufnr)
            local name = vim.api.nvim_buf_get_name(bufnr)
            return vim.fn.fnamemodify(name, ':t') ~= '.env'
        end,
    },
},
```

## TODO

- [x] Implement a proper diff mechanism to include recent edit changes in prompts.
- [ ] Add support for specialized NES models (Zeta, Sweep).
- [ ] Integrate with Inception's hosted API.

## Default Config

```lua
require('minuet').setup {
    duet = {
        provider = 'gemini', -- Provider used by `:Minuet duet predict`.
        request_timeout = 15, -- Timeout in seconds for a single duet request.
        scope = 'buffer', -- 'cursor', 'buffer', or 'workspace'; cross-buffer targets still require the separate flag below.
        jump_requires_confirmation = true, -- Require one action to focus a remote edit and a second action to apply it.
        candidates = {
            cursor = true, -- Include the current cursor as a candidate.
            recent_edits = true, -- Include current-buffer unified diff hunk rows from bounded recent edit history.
            diagnostics = true, -- Include rows from Neovim's diagnostic cache without making LSP requests.
            references = true, -- Query supported attached LSP clients for same-buffer references to recently changed identifiers.
            text = true, -- Include bounded same-buffer identifier matches without an LSP.
            related_buffers = false, -- With scope='workspace', allow safe loaded same-workspace LSP references as targets.
            max_candidates = 8, -- Maximum ranked candidates retained internally (clamped to 1..64).
        },
        lsp = {
            timeout = 120, -- Total asynchronous semantic deadline in milliseconds; 0 disables LSP requests.
            cache_ttl = 30000, -- Reuse semantic results only for the same buffer changedtick and config.
            max_cache_buffers = 32,
            max_identifiers = 8,
            max_symbol_queries = 4,
            max_symbols = 128,
            max_locations = 64,
            max_text_matches_per_identifier = 8,
        },
        context = {
            max_chars = 48000, -- Total bounded current request context; an oversized editable region is rejected.
            evidence_max_chars = 4800,
            diagnostic_radius = 20,
            max_diagnostics = 12,
            related_files = {
                enabled = false, -- Opt in before sending source from directly imported, already loaded buffers.
                max_chars = 12000,
                max_files = 3,
                per_file_max_chars = 4000,
            },
        },
        editable_region = {
            lines_before = 8, -- Number of editable lines included before the cursor.
            lines_after = 15, -- Number of editable lines included after the cursor.
            before_region_filter_length = 30, -- Trim duplicated text from the start of the model output when it repeats non-editable text before the region.
            after_region_filter_length = 30, -- Trim duplicated text from the end of the model output when it repeats non-editable text after the region.
        },
        non_editable_region = {
            context_window = 40000, -- Maximum characters of non-editable context included around the editable region.
            context_ratio = 0.75, -- Ratio of non-editable context before vs. after the editable region when truncation is needed.
        },
        auto_trigger = {
            enabled = false, -- Opt in to automatic Duet requests after eligible edits.
            debounce = 900, -- Milliseconds of idle time before an automatic prediction.
            throttle = 1500, -- Minimum milliseconds between automatic Duet request starts.
            on_insert_leave = true, -- Run a pending dirty generation after leaving Insert mode.
            after_accept = true, -- Schedule another prediction after accepting FIM or Duet.
            max_buffer_size = 1000000, -- Buffers larger than this (bytes) do not trigger automatically.
            enable_predicates = { ... }, -- Cheap per-buffer guards. Defaults reject binary and common credential paths; overriding replaces only this list.
            filetype = {}, -- Optional { [filetype] = { debounce = ms, throttle = ms } }; missing fields inherit global values.
        },
        quality = {
            undo_window = 10000, -- Count an accepted suggestion as reverted only when undo crosses it within this many milliseconds.
            max_pending_undo = 64, -- Global bound for accepted suggestions awaiting undo observation.
            repeat_suppression = {
                enabled = true, -- Suppress an identical edit fingerprint in the same unchanged context.
                ttl = 30000, -- Milliseconds before an in-memory fingerprint expires.
                max_entries = 128, -- Global bound for SHA-256 fingerprints; source text is not retained.
            },
        },
        max_edit_lines = 40, -- Reject a prediction whose diff changes more than this many lines.
        max_edit_chars = 12000, -- Reject a prediction whose proposed editable region exceeds this byte count.
        recent_edits = {
            enabled = 'lazy', -- 'lazy' starts the recorder on the first duet prediction, true starts it at plugin setup, false disables it entirely
            debounce = 1500, -- Milliseconds of typing pause before an edit burst is recorded as one event.
            max_events = 15, -- Maximum number of edit events kept across all buffers.
            max_total_chars = 8000, -- Total character budget of the formatted edit history sent in prompts.
            diff_context_lines = 3, -- Context lines around each hunk in the unified diff.
            max_buffer_size = 1000000, -- Buffers larger than this (bytes) are not tracked.
            max_event_chars = 2000, -- A single edit burst whose diff exceeds this is truncated to the leading whole hunks that fit (dropped if not even the first hunk fits).
            diff_program = 'diff', -- External diff program invoked as `PROG -U<n> OLD NEW`; must emit unified diffs and exit 0 (identical) / 1 (differences) / >= 2 (error).
            flush_timeout = 200, -- Max milliseconds a prediction waits for in-flight diffs before proceeding with slightly stale history.
            enable_predicates = { ... }, -- Per-buffer predicates called with a buffer number; defaults reject binary and common credential paths. This list is independent from auto_trigger.enable_predicates.
        },
        markers = {
            editable_region_start = '<editable_region>', -- Marker that wraps the start of the editable region in prompts and responses.
            editable_region_end = '</editable_region>', -- Marker that wraps the end of the editable region in prompts and responses.
            cursor_position = '<cursor_position/>', -- Marker the model must preserve exactly once to indicate the final cursor position.
        },
        preview = {
            cursor = '', -- Virtual marker shown at the predicted cursor location in the preview.
            jump_text = 'Next edit: line %d', -- Origin hint for a remote edit; must contain one integer placeholder.
            cross_jump_text = 'Next edit: %s:%d', -- Workspace-relative path and line hint for an opted-in cross-buffer edit.
            jump_sign = '>>', -- One- or two-cell target sign for a remote edit.
        },
        provider_options = {
            openai = {
                model = 'gpt-5.6-luna', -- Default OpenAI model for duet requests.
                api_key = 'OPENAI_API_KEY', -- Environment variable name, or a function that returns the API key.
                end_point = 'https://api.openai.com/v1/chat/completions', -- OpenAI chat completions endpoint.
                system = { ... }, -- Duet system prompt config; keep the default unless you need a custom rewrite prompt.
                few_shots = { ... }, -- Example user/assistant turns used to steer the rewrite.
                chat_input = { ... }, -- Template that serializes editable and non-editable buffer regions.
                optional = {}, -- Extra request body fields passed through to the OpenAI API.
                transform = {}, -- Optional endpoint/header/body transforms applied before sending the request.
            },
            claude = {
                model = 'claude-haiku-4-5',
                api_key = 'ANTHROPIC_API_KEY',
                end_point = 'https://api.anthropic.com/v1/messages',
                system = { ... },
                few_shots = { ... },
                chat_input = { ... },
                max_tokens = 8192,
                optional = {},
                transform = {},
            },
            gemini = {
                model = 'gemini-3-flash-preview', -- Recommended duet model at the moment.
                api_key = 'GEMINI_API_KEY',
                end_point = 'https://generativelanguage.googleapis.com/v1beta/models',
                system = { ... },
                few_shots = { ... },
                chat_input = { ... },
                optional = {},
                transform = {},
            },
            openai_compatible = {
                model = 'google/gemini-3.1-flash-lite',
                api_key = 'OPENROUTER_API_KEY',
                end_point = 'https://openrouter.ai/api/v1/chat/completions',
                name = 'Openrouter',
                system = { ... },
                few_shots = { ... },
                chat_input = { ... },
                optional = {},
                transform = {},
            },
        },
    },
}
```

# API

## Virtual Text

`minuet-ai.nvim` offers the following functions to customize your key mappings:

```lua
{
    -- accept whole completion
    require('minuet.virtualtext').action.accept,
    -- accept by line
    require('minuet.virtualtext').action.accept_line,
    -- accept n lines (prompts for number)
    require('minuet.virtualtext').action.accept_n_lines,
    require('minuet.virtualtext').action.next,
    require('minuet.virtualtext').action.prev,
    require('minuet.virtualtext').action.dismiss,
    -- whether the virtual text is visible in current buffer
    require('minuet.virtualtext').action.is_visible,
}
```

## Duet

The duet module provides functions to programmatically control duet prediction:

```lua
{
    require('minuet.duet').action.predict,
    require('minuet.duet').action.apply,
    require('minuet.duet').action.dismiss,
    -- Check if a duet preview is currently visible in the current buffer
    require('minuet.duet').action.is_visible,
}
```

Candidate discovery can also be inspected programmatically. It only returns
positions, numeric scores, and source enums for the current loaded, modifiable
buffer; diagnostic messages and recent diff bodies are not retained in the
returned metadata:

```lua
local candidates = require 'minuet.duet.candidates'

local ranked = candidates.collect(vim.api.nvim_get_current_buf())
local best = candidates.select(vim.api.nvim_get_current_buf())
```

## Unified Tab

The Tab module arbitrates only visible Minuet Virtual Text and Duet
suggestions. It never installs a mapping:

```lua
{
    -- Returns true when Minuet handled the current visible suggestion.
    require('minuet.tab').accept,
    -- Returns '' when handled; otherwise invokes/returns the supplied fallback.
    require('minuet.tab').accept_or_fallback,
}
```

`accept_or_fallback()` accepts a string or a function returning a string. With
no argument it returns `'<Tab>'` when Minuet has nothing to accept. See
[Automatic Prediction and Tab](#automatic-prediction-and-tab) for expression
mapping examples.

## Session Metrics

Use the metrics API to retrieve a deep-copied snapshot for the current Neovim
process:

```lua
local stats = require('minuet.metrics').get()

print(stats.channels.completion.requests.outcomes.success)
print(stats.channels.duet.cycles.preview_shown)
print(stats.channels.duet.visible_acceptance_rate)
```

The snapshot contains aggregate counts and bounded P50/P95/max latency data. A
zero preview denominator produces `nil`, rather than a misleading zero percent
acceptance rate. It never includes source text, prompts, responses, paths,
endpoints, headers, or credentials.

The optional JSONL logger uses an allowlist of scalar lifecycle fields, a
bounded asynchronous queue, private directory/file permissions where supported,
and is disabled by default. It writes only to the configured local path and
never uploads metrics.

## Offline Quality Report

The report API reads allowlisted JSONL records without changing session
metrics or contacting a provider:

```lua
local quality = require 'minuet.metrics_report'
local report = quality.analyze() -- Optional string or list of paths/globs.
local message = quality.format(report)

quality.notify() -- Analyze and show the same privacy-preserving summary.

local comparison = quality.compare('/exact/baseline.jsonl', '/exact/variant.jsonl')
print(comparison.delta.acceptance_rate)
```

`report.gate.ready_for_review` requires at least 100 unique visible Duet cycles
and clean structural integrity checks. It is deliberately named "ready for
review": the caller must still confirm that all inputs came from real editing
sessions. `report.release_gate.ready_for_release_review` additionally requires
500 visible cycles, Next Edit P50/P95 under 1500/4000 ms, acceptance of at least
25%, accepted-undo below 10%, parse failure below 2%, and clean integrity. It
still requires manual provenance, FIM latency, stale-application, wrong-buffer,
and safety review. The returned aggregate contains no source, prompt, response,
input path, endpoint, header, or credential fields.

## Lualine

Minuet provides a Lualine component that displays the current status of Minuet requests. This component shows:

- The name of the active provider and model
- The current request count (e.g., "1/3")
- An animated spinner while processing

To use the Minuet Lualine component, add it to your Lualine configuration:

<details>

```lua
require('lualine').setup {
    sections = {
        lualine_x = {
            {
                require 'minuet.lualine',
                -- the follwing is the default configuration
                -- the name displayed in the lualine. Set to "provider", "model" or "both"
                -- display_name = 'both',
                -- separator between provider and model name for option "both"
                -- provider_model_separator = ':',
                -- whether show display_name when no completion requests are active
                -- display_on_idle = false,
            },
            'encoding',
            'fileformat',
            'filetype',
        },
    },
}
```

</details>

## Minuet Event

### Standard Completion Events

- **MinuetRequestStartedPre**: Triggered before a completion request is
  initiated. This allows for pre-request operations, such as logging or updating
  the user interface.
- **MinuetRequestStarted**: Triggered immediately after the completion request
  is dispatched, signaling that the request is in progress.
- **MinuetRequestFinished**: Triggered upon completion of the request.

### Duet Events

- **MinuetDuetRequestStartedPre**: Triggered before a duet request is initiated.
- **MinuetDuetRequestStarted**: Triggered immediately after the duet request
  is dispatched.
- **MinuetDuetRequestFinished**: Triggered upon completion of the duet request.

### Suggestion Lifecycle

`MinuetSuggestionLifecycle` is emitted for UI lifecycle changes controlled by
Minuet. Its `kind` is one of `preview_shown`, `accepted`, `dismissed`, `stale`,
or `parse_failed`. The event currently covers only the virtual text and Duet
frontends.

The payload is allowlisted and includes `schema_version`, `kind`, `channel`,
`cycle_id`, `provider_id`, `frontend`, `timestamp`, `elapsed_ms`, and an optional
classified `reason`. It does not contain suggestion or provider response text.

### Event Data

Each event includes a `data` field containing the following properties:

- `provider`: A string indicating the provider type (e.g.,
  'openai_compatible').
- `name`: A string specifying the provider's name (e.g., 'OpenAI', 'Groq',
  'Ollama').
- `model`: A string containing the model name (e.g., 'gemini-2.0-flash').
- `n_requests`: The number of requests encompassed in this completion cycle.
- `request_idx` (optional): The index of the current request, applicable when
  providers make multiple requests.
- `timestamp`: A Unix timestamp representing the start of the request cycle
  (corresponding to the `MinuetRequestStartedPre` event).
- `schema_version`: The event schema version, currently `1`.
- `channel`: Either `completion` or `duet`.
- `cycle_id`: The strictly increasing ID of the frontend's logical provider
  call.
- `request_id` (started/finished only): The strictly increasing transport
  request ID.
- `provider_id`: The configured provider key.
- `frontend`: The Minuet frontend that created the cycle, when known.
- `duration_ms` (finished only): Monotonic transport duration for a successfully
  spawned request.
- `status` (finished only): One of `success`, `partial`, `timeout`, `cancelled`,
  `transport_error`, `invalid_response`, `empty_response`, or `spawn_error`.
- `reason` (finished only): An optional fixed classification. Raw errors and
  provider responses are never included.

# FAQ

## Customize `cmp` ui for source icon and kind icon

You can configure the icons of completion items returned by `minuet` by using
the following snippet (referenced from [cmp's
wiki](https://github.com/hrsh7th/nvim-cmp/wiki/Menu-Appearance#basic-customisations)):

<details>

```lua
local kind_icons = {
    Number = '󰎠',
    Array = '',
    Variable = '',
    -- and other icons
    -- LLM Provider icons
    claude = '󰋦',
    openai = '󱢆',
    codestral = '󱎥',
    gemini = '',
    Groq = '',
    Openrouter = '󱂇',
    Ollama = '󰳆',
    ['Llama.cpp'] = '󰳆',
    Deepseek = ''
    -- FALLBACK
    fallback = '',
}

local source_icons = {
    minuet = '󱗻',
    nvim_lsp = '',
    lsp = '',
    buffer = '',
    luasnip = '',
    snippets = '',
    path = '',
    git = '',
    tags = '',
    -- FALLBACK
    fallback = '󰜚',
}

local cmp = require 'cmp'
cmp.setup {
    formatting = {
        format = function(entry, vim_item)
            -- Kind icons
            -- This concatenates the icons with the name of the item kind
            vim_item.kind = string.format('%s %s', kind_icons[vim_item.kind] or kind_icons.fallback, vim_item.kind)
            -- Source
            vim_item.menu = source_icons[entry.source.name] or source_icons.fallback
            return vim_item
        end,
    },
}
```

</details>

## Customize `blink` ui for source icon and kind icon

You can configure the icons of completion items returned by `minuet` by the following snippet:

<details>

To customize the kind icons:

```lua
local kind_icons = {
    -- LLM Provider icons
    claude = '󰋦',
    openai = '󱢆',
    codestral = '󱎥',
    gemini = '',
    Groq = '',
    Openrouter = '󱂇',
    Ollama = '󰳆',
    ['Llama.cpp'] = '󰳆',
    Deepseek = ''
}

require('blink-cmp').setup {
    appearance = {
        use_nvim_cmp_as_default = true,
        nerd_font_variant = 'normal',
        kind_icons = kind_icons
    },
}

```

To customize the source icons:

```lua
local source_icons = {
    minuet = '󱗻',
    orgmode = '',
    otter = '󰼁',
    nvim_lsp = '',
    lsp = '',
    buffer = '',
    luasnip = '',
    snippets = '',
    path = '',
    git = '',
    tags = '',
    cmdline = '󰘳',
    latex_symbols = '',
    cmp_nvim_r = '󰟔',
    codeium = '󰩂',
    -- FALLBACK
    fallback = '󰜚',
}

require('blink-cmp').setup {
    appearance = {
        use_nvim_cmp_as_default = true,
        nerd_font_variant = 'normal',
        kind_icons = kind_icons
    },
    completion = {
        menu = {
            draw = {
                columns = {
                    { 'label', 'label_description', gap = 1 },
                    { 'kind_icon', 'kind' },
                    { 'source_icon' },
                },
                components = {
                    source_icon = {
                        -- don't truncate source_icon
                        ellipsis = false,
                        text = function(ctx)
                            return source_icons[ctx.source_name:lower()] or source_icons.fallback
                        end,
                        highlight = 'BlinkCmpSource',
                    },
                },
            },
        },
    }
}
```

</details>

## Significant Input Delay When Moving to a New Line with `nvim-cmp`

When using Minuet with auto-complete enabled, you may occasionally experience a
noticeable delay when pressing `<CR>` to move to the next line. This occurs
because Minuet triggers autocompletion at the start of a new line, while cmp
blocks the `<CR>` key, awaiting Minuet's response.

To address this issue, consider the following solutions:

1. Unbind the `<CR>` key from your cmp keymap.
2. Utilize cmp's internal API to avoid blocking calls, though be aware that
   this API may change without prior notice.

Here's an example of the second approach using Lua:

```lua
local cmp = require 'cmp'
opts.mapping = {
    ['<CR>'] = cmp.mapping(function(fallback)
        -- use the internal non-blocking call to check if cmp is visible
        if cmp.core.view:visible() then
            cmp.confirm { select = true }
        else
            fallback()
        end
    end),
}
```

## Integration with `lazyvim`

<details>

**With nvim-cmp**:

```lua
{
    'milanglacier/minuet-ai.nvim',
    config = function()
        require('minuet').setup {
            -- Your configuration options here
        }
    end
},
{
    'nvim-cmp',
    optional = true,
    opts = function(_, opts)
        -- if you wish to use autocomplete
        table.insert(opts.sources, 1, {
            name = 'minuet',
            group_index = 1,
            priority = 100,
        })

        opts.performance = {
            -- It is recommended to increase the timeout duration due to
            -- the typically slower response speed of LLMs compared to
            -- other completion sources. This is not needed when you only
            -- need manual completion.
            fetching_timeout = 2000,
        }

        opts.mapping = vim.tbl_deep_extend('force', opts.mapping or {}, {
            -- if you wish to use manual complete
            ['<A-y>'] = require('minuet').make_cmp_map(),
        })
    end,
}
```

**With blink-cmp**:

```lua
-- set the following line in your config/options.lua
vim.g.lazyvim_blink_main = true

{
    'milanglacier/minuet-ai.nvim',
    config = function()
        require('minuet').setup {
            -- Your configuration options here
        }
    end,
},
{
    'saghen/blink.cmp',
    optional = true,
    opts = {
        keymap = {
            ['<A-y>'] = {
                function(cmp)
                    cmp.show { providers = { 'minuet' } }
                end,
            },
        },
        sources = {
            -- if you want to use auto-complete
            default =  { 'minuet' },
            providers = {
                minuet = {
                    name = 'minuet',
                    module = 'minuet.blink',
                    score_offset = 100,
                },
            },
        },
    },
}
```

</details>

# Enhancement

## RAG (Experimental)

You can enhance the content sent to the LLM for code completion by leveraging
RAG support through the [VectorCode](https://github.com/Davidyz/VectorCode)
package.

VectorCode contains two main components. The first is a standalone CLI program
written in Python, available for installation via PyPI. This program is
responsible for creating the vector database and processing RAG queries. The
second component is a Neovim plugin that provides utility functions to send
queries and manage buffer-related RAG information within Neovim.

We offer two example recipes demonstrating VectorCode integration: one for
chat-based LLMs (Gemini) and another for the FIM model (Qwen-2.5-Coder),
available in [recipes.md](./recipes.md).

For detailed instructions on setting up and using VectorCode, please refer to the
[official VectorCode
documentation](https://github.com/Davidyz/VectorCode/tree/main/docs/neovim).

# Troubleshooting

If your setup failed, there are two most likely reasons:

1. You may set the API key incorrectly. Checkout the [API Key](#api-keys)
   section to see how to correctly specify the API key.
2. You are using a model or a context window that is too large, causing
   completion items to timeout before returning any tokens. This is
   particularly common with local LLM. It is recommended to start with the
   following settings to have a better understanding of your provider's inference
   speed.
   - Begin by testing with manual completions.
   - Use a smaller context window (e.g., `config.context_window = 768`)
   - Use a smaller model
   - Set a longer request timeout (e.g., `config.request_timeout = 5`)

To diagnose issues, set `config.notify = debug` and examine the output.

For Duet and Cursor Tab specifically:

- No preview can mean the response was a no-op, whitespace-only, oversized, or
  a repeated fingerprint. It can also mean the Buffer changed before the
  response arrived. Check `:Minuet stats` or the aggregate `:Minuet report`;
  neither command exposes response text.
- LSP reference lookup is bounded by `duet.lsp.timeout`. A timeout falls back to
  other enabled candidate sources and does not make the current Buffer unsafe.
- A stale count means context, ownership, or a Buffer anchor changed. Stale
  suggestions are fenced and are not applied.
- Cross-buffer targets require both `duet.scope = 'workspace'` and
  `duet.candidates.related_buffers = true`. The target must already be loaded,
  listed, modifiable, LSP-referenced, and inside the same workspace.
- If JSONL is unwritable or reaches `metrics.jsonl.max_file_size`, collection is
  disabled for that session without interrupting editing. Use a writable exact
  path with space available, then restart Neovim; do not merge partial logs
  until their integrity passes `:Minuet report`.

Automatic Duet and cross-buffer edits remain disabled by default. Keep them
opt-in until a real 500-visible cohort and the manual provenance and safety
review are complete.

# Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

# Acknowledgement

- [cmp-ai](https://github.com/tzachar/cmp-ai): Reference for the integration with `nvim-cmp`.
- [continue.dev](https://www.continue.dev): not a neovim plugin, but I find a lot LLM models from here.
- [copilot.lua](https://github.com/zbirenbaum/copilot.lua): Reference for the virtual text frontend.
- [llama.vim](https://github.com/ggml-org/llama.vim): Reference for CLI parameters used to launch the llama-cpp server.
- [crates.nvim](https://github.com/saecki/crates.nvim): Reference for in-process LSP implemtation to provide completion.
