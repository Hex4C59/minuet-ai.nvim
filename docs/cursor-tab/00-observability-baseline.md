# Cursor Tab 第一实施步骤：建立可测基线（Phase 0）

> 状态：Phase 0 代码、自动验收、benchmark 与真实 DeepSeek smoke 均已完成
>
> 对应路线：[`cursor-tab-roadmap.md`](../cursor-tab-roadmap.md) 的 Phase 0
>
> 本文性质：实施规格。开始编码前冻结统计口径，完成后在文末补充实际结果与偏差。

## 1. 为什么先做这一步

Cursor Tab 改造后续会引入自动触发、请求取消、FIM 与 Duet 仲裁、连续预测和跨位置跳转。如果没有稳定的请求 ID、生命周期事件和会话指标，就无法回答以下问题：

1. 一次用户触发实际发出了多少个请求。
2. 建议是否真正展示给用户，而不只是从 provider 返回。
3. 用户是否接受、主动 dismiss，或因为 Buffer 变化而使建议过期。
4. 新请求到来后，旧请求是否仍然更新了 UI。
5. 调整 debounce、prompt 或候选策略后，延迟和接受率究竟变好还是变差。

因此，第 0 步只建立观测能力，不提前实现 scheduler、统一 Tab、候选位置发现或跨 Buffer 编辑。

本步骤的核心原则是：

```text
先定义统计实体和事件语义
  -> 再接入现有 FIM/Duet 控制流
  -> 最后才根据数据改变产品行为
```

## 2. 当前基线

### 2.1 已有能力

| 能力 | 当前位置 | 现状 |
|---|---|---|
| 普通 completion 请求事件 | `lua/minuet/backends/*.lua` | 已有 `StartedPre`、`Started`、`Finished` |
| Duet 请求事件 | `lua/minuet/duet/backends/*.lua` | 已有对应的三类事件 |
| FIM virtual text 展示 | `lua/minuet/virtualtext.lua` | 能判断 extmark 是否实际创建 |
| FIM virtual text 接受和 dismiss | `lua/minuet/virtualtext.lua` | 有明确 action，但没有生命周期事件 |
| Duet preview、apply 和 dismiss | `lua/minuet/duet/init.lua` | 有明确控制流，但没有生命周期事件 |
| Duet 过期保护 | `lua/minuet/duet/init.lua` | 已有 `request_seq` 和 `changedtick` 检查 |
| 事件分发 | `lua/minuet/utils.lua` | 通过 `User` autocmd 分发 |
| 命令入口 | `lua/minuet/init.lua` | 可增加 `:Minuet stats` |
| 测试入口 | `tests/run.lua`、`Makefile` | 可运行 `make test`、`make format-check`、`make benchmark` |

### 2.2 当前事件不能直接用于准确统计

现有事件描述的是 curl 进程，而不是完整的建议生命周期，主要问题如下：

1. 事件没有严格唯一的 `cycle_id` 和 `request_id`。
2. `timestamp` 使用秒级 `os.time()`，不能作为异步关联 ID。
3. `Finished` 当前在响应解析前触发，无法表达 timeout、无文本或解析失败。
4. 一次 FIM completion cycle 会发出 `n_completions` 个并行请求。
5. FIM 每个子请求完成后都会携带累计结果再次调用 frontend callback。
6. 被取消的旧进程仍可能触发退出回调，晚到事件可能混入新 cycle。
7. virtual text 会因为重复 callback、CursorHold 或候选切换多次 render。
8. Duet 的多条 stale 路径目前都只是清理状态，没有原因和去重信息。

因此不能使用以下错误口径：

```text
provider callback 次数 == 请求数                 # 错误
provider 返回候选 == 用户看到建议                # 错误
update_preview() 调用次数 == preview 展示数       # 错误
进入 accept() == Buffer 已成功修改                # 错误
```

### 2.3 可观测范围限制

第一版只能准确记录 Minuet 自己控制的 UI 生命周期：

| Frontend | 请求统计 | preview shown | accepted | dismissed/stale |
|---|---:|---:|---:|---:|
| virtual text | 是 | 是 | 是 | 是 |
| Duet | 是 | 是 | 是 | 是 |
| nvim-cmp | 是 | 否 | 否 | 否 |
| Blink | 是 | 否 | 否 | 否 |
| LSP completion | 是 | 否 | 否 | 否 |
| LSP inline completion | 是 | 否 | 否 | 否 |

cmp、Blink 和 LSP 的候选展示、选择、确认及关闭由宿主前端控制。除非后续接入各前端可靠的确认事件，否则不得将“候选交给 callback”记录成 `preview_shown` 或 `accepted`。

## 3. 本步骤目标

完成后应具备以下能力：

1. 为每个逻辑 completion/Duet cycle 分配进程内唯一 ID。
2. 为每个实际 transport request 分配唯一 ID，并关联所属 cycle。
3. 区分 cycle、实际请求、可用结果和实际可见 preview。
4. 记录 request started/finished、preview shown、accepted、dismissed、stale 和 parse failed。
5. 提供默认开启、仅驻留内存的会话统计。
6. 提供 `require('minuet.metrics').get()` 只读快照。
7. 提供 `:Minuet stats` 会话摘要。
8. 提供默认关闭的脱敏 JSONL 本地日志。
9. 补齐 DeepSeek FIM 和 Chat endpoint 的手动 smoke test。
10. 建立当前功能的人工回归清单。
11. 不改变现有请求触发时机、建议内容、preview 样式和按键行为。

## 4. 明确不做

本步骤不包含：

- 自动触发 Duet。
- FIM 与 Duet 的跨通道取消或优先级调度。
- 统一 suggestion controller。
- 统一 Tab API。
- no-op、纯空白或超大建议过滤。
- 候选位置发现、LSP context 或跨 Buffer 编辑。
- cmp、Blink、LSP frontend 的接受率推测。
- 源码、prompt、response 或 recent edits 的内容采样。
- 上传遥测或任何新增网络请求。
- 接受后立即撤销率；该指标留到有统一 controller 后实现。
- 修复所有当前 UI 竞态；本步骤先准确观测，行为修复进入 Phase 1。

当前 Duet 的 cursor-only/no-op preview 仍按现有行为展示，并计为一次 `preview_shown`。过滤该类建议属于 Phase 1，不能在本步骤顺手改变。

## 5. 统计实体与口径

### 5.1 Session

一次 Neovim 进程内的 Minuet 运行期为一个 session。

- `session_id` 只用于当前进程及可选 JSONL 关联。
- session ID 不跨进程复用，不包含主机名、用户名或路径。
- 内存统计在进程退出后丢失。
- 本步骤不自动恢复或合并历史 session。

### 5.2 Cycle

一次 frontend 对 provider 的逻辑调用为一个 cycle。

示例：

```text
virtual text 触发一次 FIM，n_completions = 3
  -> 1 个 completion cycle
  -> 3 个 transport requests
  -> 最多 3 次累计 frontend callbacks
  -> 最多记 1 次该 cycle 的 preview_shown
```

Duet 的一次 `predict()` 对应一个 Duet cycle，当前通常只有一个 transport request。

`cycle_id` 必须使用进程内严格递增整数，不能使用 `os.time()` 或 `uv.now()` 充当唯一 ID。

### 5.3 Transport request

一次 `vim.system()` 启动的 curl 进程为一个 transport request。

每个 request 必须属于且只属于一个 cycle，并有自己的：

- `request_id`
- `request_idx`
- start monotonic time
- finish monotonic time
- terminal status

请求终态定义如下：

| Status | 定义 |
|---|---|
| `success` | 进程正常结束并解析出非空文本 |
| `partial` | 流式请求超时，但超时前已获得可用文本 |
| `timeout` | curl timeout 且没有可用文本 |
| `cancelled` | Minuet 明确终止了旧请求 |
| `transport_error` | 非 timeout、非主动取消的 transport 失败 |
| `invalid_response` | JSON 或 provider extractor 无法解析响应 |
| `empty_response` | 响应可解析，但没有可用文本 |
| `spawn_error` | `vim.system()` 未成功启动进程 |

`Finished` 必须在 outcome 分类完成后恰好触发一次。`spawn_error` 可以没有对应的 `Started`，但仍属于 cycle 的一次 request attempt。

### 5.4 Usable result

当 cycle 第一次产生可交给 frontend 的非空候选或 Duet 文本时，记录一次 `with_result`。

- FIM 后续累计 callback 不重复计数。
- `with_result` 不代表建议实际展示。
- Duet marker 尚未解析成功时，只能算 transport result，不能算 preview。

### 5.5 Preview shown

`preview_shown` 定义为：一个 cycle 第一次成功创建用户可见的 Minuet extmark。

以下情况不计数：

- provider 只返回了候选。
- completion menu 抑制了 virtual text。
- 同一建议因 CursorHold 再次 render。
- FIM 后续子请求返回后重新 render 累计候选。
- 用户使用 next/prev 切换同一个 cycle 内的候选。
- cmp、Blink 或 LSP 仅收到 completion items。

### 5.6 Accepted

`accepted` 定义为：建议对应的 Buffer 修改成功完成后，该 cycle 第一次被用户接受。

- 必须在 `nvim_buf_set_text()` 或 `nvim_buf_set_lines()` 成功后记录。
- 仅调用 action、但写入失败时不能记录。
- virtual text 分行接受时，第一次成功写入即把该 cycle 记为 accepted。
- 同一 cycle 后续继续接受剩余行，不重复增加 cycle-level accepted。
- 本步骤可额外保留内部 action 计数，但不得混入 cycle-level 接受率。

统计中同时保留 `accepted_visible`：只有同一个 cycle 既发生过 `preview_shown`，又发生过 `accepted` 时才增加。可见建议接受率使用该交集，不能直接用全部 accepted；否则用户在 preview 被 completion menu 抑制时仍通过 action 接受建议，可能使接受率超过 100%。

### 5.7 Dismissed

`dismissed` 只表示用户显式调用 Minuet 的 dismiss action，且当时存在 pending 或 visible cycle。

- 无建议时调用 dismiss 不计数。
- `InsertLeave`、`BufLeave` 和自动 cleanup 不算用户 dismiss。
- 同一 cycle 重复 dismiss 最多计一次。

### 5.8 Stale

`stale` 表示一个非空结果或已显示建议因上下文不再兼容而被丢弃。

允许的 reason 是固定枚举：

| Reason | 场景 |
|---|---|
| `superseded` | 新 cycle 使旧 cycle 失效 |
| `buffer_changed` | 请求后 Buffer `changedtick` 变化 |
| `context_changed` | virtual text 所属输入上下文不再匹配 |
| `buffer_unloaded` | 目标 Buffer 已卸载或失效 |
| `apply_validation` | 接受前验证发现建议已过期 |

主动 dismiss 不算 stale。被主动取消且从未产出非空结果的 transport request 只记 `cancelled`，不额外增加 suggestion stale。

### 5.9 Parse failed

解析失败分两层记录：

| 层级 | 记录方式 | 示例 |
|---|---|---|
| transport response | request terminal status | `invalid_response`、`empty_response` |
| suggestion protocol | cycle-level `parse_failed` | Duet marker 数量错误、editable region 无法解析 |

一个 FIM cycle 中某个子请求解析失败、另一个子请求成功时，请求 outcome 分别计数；cycle 仍可正常产生 `with_result` 和 preview。

## 6. 生命周期关系

统计层不在 Phase 0 强制引入完整 suggestion 状态机，但必须支持以下关系：

```text
cycle_started
  -> request_started x N
  -> request_finished x N
  -> with_result?
  -> preview_shown?
  -> accepted? | dismissed? | stale? | parse_failed?
```

约束：

1. 同一个 lifecycle kind 对同一 cycle 最多计一次。
2. 同一 request 只能有一个 terminal status。
3. 一个 cycle 可以有多个 request outcome。
4. Phase 0 不强制 `accepted`、`dismissed` 和 `stale` 互斥，以便如实暴露现有竞态。
5. 指标模块最多保留最近 `max_tracked_cycles` 个 cycle 的去重状态，不能随 session 时长无限增长。
6. cycle/request ID 只用于关联，不能根据 ID 推导 Buffer、路径或源码。

第 4 条是有意保留的基线行为。例如当前 virtual text dismiss 后，尚未结束的 FIM 子请求可能再次回调。Phase 0 应保证数据不重复，但不借指标改造偷偷引入新的 controller 语义。该竞态在 Phase 1 修复。

cycle ID 严格递增，因此有界淘汰使用 ID 水位线：创建新 cycle 后，只保留最新窗口内的状态；对已经低于淘汰水位线的晚到事件直接忽略，并累计到 `dropped_late_events`。这意味着一个异常挂起、且晚于 4096 个新 cycle 才返回的请求不会再进入统计。相比无限持有状态或污染新 cycle，这个退化更安全且可观测。

## 7. 事件契约

### 7.1 保留现有 request 事件

以下公开 `User` autocmd 事件名保持不变：

```text
MinuetRequestStartedPre
MinuetRequestStarted
MinuetRequestFinished
MinuetDuetRequestStartedPre
MinuetDuetRequestStarted
MinuetDuetRequestFinished
```

现有字段 `provider`、`name`、`model`、`n_requests`、`request_idx` 和 `timestamp` 不删除，避免破坏 README 已公开的事件 API。

新增字段：

```lua
---@class minuet.RequestEventData
---@field schema_version 1
---@field channel 'completion'|'duet'
---@field cycle_id integer
---@field request_id integer?       -- Started/Finished 存在
---@field provider_id string        -- 实际配置中的 provider key
---@field provider string           -- 保留旧字段语义
---@field name string?
---@field model string
---@field frontend string?
---@field n_requests integer
---@field request_idx integer?
---@field timestamp integer         -- cycle 开始时的 Unix 秒，兼容旧字段
---@field duration_ms number?       -- 仅 Finished
---@field status string?            -- 仅 Finished
---@field reason string?            -- 固定枚举，不允许 raw error
```

`StartedPre` 每个 cycle 一次，`Started` 每个成功 spawn 的 request 一次，`Finished` 每个 request attempt 一次。

### 7.2 新增 suggestion lifecycle 事件

新增一个统一事件，避免为每种状态创建一组平行 autocmd 名：

```text
MinuetSuggestionLifecycle
```

事件数据：

```lua
---@class minuet.SuggestionLifecycleEventData
---@field schema_version 1
---@field kind 'preview_shown'|'accepted'|'dismissed'|'stale'|'parse_failed'
---@field channel 'completion'|'duet'
---@field cycle_id integer
---@field provider_id string
---@field frontend 'virtualtext'|'duet'
---@field timestamp integer
---@field elapsed_ms number
---@field reason string?
```

事件 payload 只能由字段白名单构造，禁止把任意内部 table 直接透传给 `nvim_exec_autocmds()`。

### 7.3 事件与内部指标的顺序

每次状态变化应按以下顺序执行：

```text
更新内部统计
  -> 将脱敏记录加入可选 JSONL 队列
  -> 分发公开 User autocmd
```

内部 metrics 不通过监听公开 autocmd 来反向计数，避免重复注册或用户 handler 重入导致双计数。

用户 autocmd 抛错不得回滚已经记录的内部状态，也不得中断 provider callback 或 Buffer apply。公开事件分发错误只允许通知一次。

## 8. 会话统计 API

### 8.1 Lua API

新增：

```lua
local stats = require('minuet.metrics').get()
```

`get()` 必须返回深拷贝后的聚合快照，不暴露可修改的内部 table，也不返回源码、路径或原始 latency 数组。

建议返回结构：

```lua
{
    schema_version = 1,
    enabled = true,
    session = {
        started_at = 0,
        elapsed_ms = 0,
    },
    channels = {
        completion = {
            cycles = {
                started = 0,
                with_result = 0,
                preview_shown = 0,
                accepted = 0,
                accepted_visible = 0,
                dismissed = 0,
                stale = 0,
                parse_failed = 0,
            },
            requests = {
                attempted = 0,
                started = 0,
                finished = 0,
                outcomes = {
                    success = 0,
                    partial = 0,
                    timeout = 0,
                    cancelled = 0,
                    transport_error = 0,
                    invalid_response = 0,
                    empty_response = 0,
                    spawn_error = 0,
                },
            },
            latency_ms = {
                request = { samples = 0, retained = 0, p50 = nil, p95 = nil, max = nil },
                first_preview = { samples = 0, retained = 0, p50 = nil, p95 = nil, max = nil },
            },
            visible_acceptance_rate = nil,
        },
        duet = {
            -- 与 completion 使用相同结构
        },
    },
    dropped_late_events = 0,
    dropped_log_records = 0,
}
```

`visible_acceptance_rate` 使用 `accepted_visible / preview_shown`，分母为零时返回 `nil`，不能返回误导性的 `0%`。

### 8.2 Latency 存储

使用 `vim.uv.hrtime()` 测量单调时间，不能使用 wall clock 计算耗时。request latency 只统计成功 spawn 且最终收到退出回调的 request；`spawn_error` 不进入 latency 分布。first-preview latency 从 frontend 创建 cycle 到首次实际 extmark 可见。

内存中每种 latency 最多保留最近 `max_latency_samples` 个样本，默认建议为 `2048`。同时保留累计 `samples`，让调用方知道 P50/P95 是否基于截断后的近期窗口。

### 8.3 命令

新增：

```vim
:Minuet stats
```

输出至少包含：

- completion 和 Duet 的 cycle/request 数。
- request P50/P95。
- preview shown、accepted、dismissed、stale 和 parse failed。
- visible acceptance rate。
- UI 指标覆盖范围提示：当前仅 virtual text 与 Duet 可准确跟踪。

命令输出不得包含 Buffer 名、文件路径、模型响应、prompt 或 API endpoint。

## 9. 配置草案

在根配置增加跨 FIM/Duet 共用的 `metrics`，不要放入 `duet` 子配置：

```lua
require('minuet').setup {
    metrics = {
        enabled = true,
        max_tracked_cycles = 4096,
        max_latency_samples = 2048,
        jsonl = {
            enabled = false,
            path = nil,
            flush_interval = 1000,
            max_queue = 256,
            max_file_size = 10 * 1024 * 1024,
        },
    },
}
```

语义：

| 配置 | 默认值 | 说明 |
|---|---:|---|
| `metrics.enabled` | `true` | 启用内存聚合；设为 false 时仍保留 ID 和公开事件兼容性，但关闭聚合与 JSONL |
| `max_tracked_cycles` | `4096` | 用于 lifecycle 去重的最近 cycle 窗口；更早的晚到事件被忽略 |
| `max_latency_samples` | `2048` | 每种 latency 的有界近期样本数 |
| `jsonl.enabled` | `false` | 是否写本地调试日志 |
| `jsonl.path` | `nil` | `nil` 时使用 `stdpath('state')/minuet/` 下的 session 文件 |
| `jsonl.flush_interval` | `1000` | 批量写入间隔，单位毫秒 |
| `jsonl.max_queue` | `256` | 内存待写队列上限 |
| `jsonl.max_file_size` | `10 MiB` | 达到上限后停止写入并只通知一次 |

当 `jsonl.enabled = false` 时，不创建 timer、目录、文件或编码队列，事件热路径只更新有界内存状态。`metrics.enabled = false` 时强制视为 JSONL 关闭，`:Minuet stats` 返回带 `enabled = false` 的空快照。

## 10. JSONL 隐私契约

### 10.1 默认行为

- 默认关闭。
- 只写本机，不上传。
- 每个 session 使用独立 ID。
- 目录尽力设置为 `0700`，文件尽力设置为 `0600`。
- 写入失败只关闭 logger 并通知一次，不得影响 completion 或 Duet。
- 使用有界队列和批量异步写入，不能在输入 autocmd 同步路径阻塞磁盘 I/O。

### 10.2 允许字段

JSONL 每行只能包含以下标量白名单中的字段：

```text
schema_version
session_id
event
timestamp
channel
frontend
provider_id
cycle_id
request_id
n_requests
request_idx
status
reason
duration_ms
elapsed_ms
```

不同 event 使用其中必要的子集。

JSONL 有意不写 `name` 和 `model`。公开 request event 为兼容现有 API 仍保留这两个字段，但它们是用户可配置字符串，不适合作为严格脱敏日志的白名单值。provider 维度只记录固定配置 key `provider_id`。

写入 JSONL 前必须将 `provider_id` 映射到内置 provider 枚举；未知值统一记为 `custom`。`frontend`、`event`、`status` 和 `reason` 同样只接受 schema 中的枚举值。队列满时丢弃新日志 record、增加 `dropped_log_records`，并至多通知一次，不能反向阻塞编辑。

### 10.3 禁止字段

以下数据禁止进入内存事件 payload 和 JSONL：

- prompt、context、源码、completion、Duet response。
- editable region、original text、proposed text、recent edits diff。
- Buffer 名、绝对路径、workspace path、URI。
- endpoint、headers、request body、curl args、stderr 和 raw error。
- API key、API key 环境变量的值及 transform 后的认证字段。
- 建议文本 hash 或源码 hash；hash 仍可能被关联或字典攻击。
- 任意通过 `vim.inspect()` 得到的 provider response。

`reason` 必须是代码中定义的枚举，不允许将 exception message 或 parser 原始错误直接赋给它。

### 10.4 当前已知隐私边界

现有 transport 会把完整 request body 写入临时文件，并把认证 header 交给 curl。该文件不是 metrics 日志，但其中包含 prompt 和源码。本步骤不重写 HTTP transport，不过应验证所有正常、timeout、spawn error 和取消路径都会清理临时文件，并尽力使用仅当前用户可读权限。

现有 `duet.recent_edits.enable_predicates` 默认只保护 recent-edit recorder 中的 `.env` 文件，并不会阻止用户在 `.env` Buffer 中主动触发普通 completion 或 Duet。smoke test 必须使用无敏感信息的临时文件，不能把 recorder guard 描述成全局 secret guard。

## 11. 代码改动设计

### 11.1 新增 `lua/minuet/metrics.lua`

该模块负责一个真实职责：生命周期 ID、会话聚合、公开事件和可选安全日志。

内部接口建议为：

```lua
---@class minuet.MetricsCycleMeta
---@field channel 'completion'|'duet'
---@field frontend string?
---@field provider_id string
---@field provider? string
---@field name string?
---@field model? string
---@field n_requests? integer

---@class minuet.MetricsRequestResult
---@field status string
---@field reason string?

local metrics = require 'minuet.metrics'

local cycle_id = metrics.begin_cycle(meta)
metrics.configure_cycle(cycle_id, provider_meta)
local request_id = metrics.request_attempted(cycle_id, request_idx)
metrics.request_started(request_id)
metrics.request_finished(request_id, result)
metrics.cycle_has_result(cycle_id)
metrics.suggestion_event(cycle_id, 'preview_shown')
local snapshot = metrics.get()
```

要求：

- 除创建 cycle/request ID 外，所有按 ID 更新的 record 操作幂等。
- cycle/request ID 严格递增。
- 只保存聚合值、有界 latency、最近 `max_tracked_cycles` 个 cycle 的去重状态和仍在该窗口内的 request 状态。
- 不持有 context、response、suggestion 或 Buffer 内容引用。
- JSONL writer 只消费已经按白名单构造的 record。
- 对外稳定 API 只有 `get()`；其余接口视为插件内部接口。

必须在调用 `vim.system()` 前执行 `request_attempted()`，这样 spawn 失败也有稳定的 `request_id`；只有 spawn 成功后才执行 `request_started()`。request terminal status 的优先级固定为：`spawn_error`，主动取消，timeout/transport error，response decode outcome。这样同一 attempt 不会同时被算成 cancelled 和 transport error。

不要在本步骤新增 `duet/feedback.lua`。指标横跨 completion 与 Duet，放在根模块可以避免两套实现；Phase 5 如果需要更丰富的 Duet feedback，再基于同一事件层扩展。

### 11.2 Provider 调用关联 cycle

cycle 表示 frontend 的一次逻辑调用，因此必须由 frontend 在调用 provider 前同步创建，而不是等到第一个异步 callback 才创建：

```lua
local cycle_id = metrics.begin_cycle {
    channel = 'completion',
    frontend = 'virtualtext',
    provider_id = config.provider,
}

provider.complete(context, callback, {
    cycle_id = cycle_id,
    frontend = 'virtualtext',
})
```

这样 pending 状态可以立即关联 cycle，用户在响应到达前 dismiss、切换 Buffer 或触发新请求时也能记录到正确实体。Duet 在 `predict()` 中采用同一方式。

backend 在同步构造请求时补齐 `provider`、`name`、`model` 和 `n_requests`，并通过 metrics 发出兼容的 `StartedPre`。frontend callback 直接通过 Lua 闭包使用同步创建的 `cycle_id`，不修改 callback 参数：

```lua
provider.complete(context, function(items)
    if items and next(items) then
        metrics.cycle_has_result(cycle_id)
    end
    -- existing frontend handling
end, {
    cycle_id = cycle_id,
    frontend = 'virtualtext',
})
```

Lua 会忽略自定义 backend 未声明的第三个参数，因此该扩展不会强制破坏现有简单 backend；内置 backend 必须全部接入。FIM 的每次累计 callback 由同一个闭包处理，自然关联同一个 `cycle_id`。对于忽略第三个参数的自定义 backend，frontend 仍能记录 UI 生命周期；只有该 backend 自己负责的 transport 细节不可观测。

内置 backend 也必须兼容没有 `cycle_id` 的直接调用：此时自行创建 frontend 未知的 fallback cycle。`lua/minuet/backends/*` 不是 README 承诺的稳定公共 API，但该 fallback 能保持内部测试和第三方实验 backend wrapper 的行为可诊断。

### 11.3 所有 frontend 创建 cycle

以下入口在实际调用 provider 前创建 cycle，并把 ID 传入 backend：

| 文件 | `frontend` 值 |
|---|---|
| `lua/minuet/virtualtext.lua` | `virtualtext` |
| `lua/minuet/cmp.lua` | `cmp` |
| `lua/minuet/blink.lua` | `blink` |
| `lua/minuet/lsp.lua` completion handler | `lsp_completion` |
| `lua/minuet/lsp.lua` inline handler | `lsp_inline_completion` |
| `lua/minuet/duet/init.lua` | `duet` |

cmp、Blink 和 LSP callback 可以记录 `with_result`，但仍不得记录 UI lifecycle。若 frontend 在真正调用 provider 之前就因为 predicate、debounce 或 context validation 返回，则不创建 cycle。

### 11.4 Completion transport 接入点

涉及：

- `lua/minuet/backends/common.lua`
- `lua/minuet/backends/openai_base.lua`
- `lua/minuet/backends/openai.lua`
- `lua/minuet/backends/openai_compatible.lua`
- `lua/minuet/backends/openai_fim_compatible.lua`
- `lua/minuet/backends/codestral.lua`
- `lua/minuet/backends/gemini.lua`
- `lua/minuet/backends/claude.lua`

要求：

1. 复用 frontend 传入的 cycle，禁止为同一次逻辑 complete 重复创建；只有直接调用 backend 且未传 ID 时才创建 fallback cycle。
2. FIM 的每个并行 curl 创建一个 request。
3. `terminate_all_jobs()` 标记哪些 job 是 Minuet 主动取消的。
4. job 退出后先解析 outcome，再触发 `Finished`。
5. decoder 返回结构化失败原因，不把 raw response 作为 reason。
6. frontend callback 的闭包始终关联原 cycle ID。
7. 保留现有公开事件字段和大体顺序。

### 11.5 Duet transport 接入点

涉及：

- `lua/minuet/duet/backends/common.lua`
- `lua/minuet/duet/backends/openai_base.lua`
- `lua/minuet/duet/backends/openai.lua`
- `lua/minuet/duet/backends/openai_compatible.lua`
- `lua/minuet/duet/backends/gemini.lua`
- `lua/minuet/duet/backends/claude.lua`

Duet transport outcome 与 marker parse 必须分开：

```text
HTTP 文本成功返回
  -> request status = success
  -> parse markers
     -> 成功：可能显示 preview
     -> 失败：cycle parse_failed
```

### 11.6 Virtual text 接入点

`lua/minuet/virtualtext.lua` 的 per-buffer context 增加当前 `cycle_id`，并在以下位置记录：

| 位置 | 事件 |
|---|---|
| provider callback 接收到非空候选 | `with_result`，每 cycle 一次 |
| `nvim_buf_set_extmark()` 成功后 | `preview_shown`，每 cycle 一次 |
| stale callback 被忽略 | `stale`，仅在携带非空结果且未被显式 dismiss 时记录 |
| scheduled `nvim_buf_set_text()` 成功后 | `accepted`；cursor 移动失败不回滚已发生的接受 |
| 显式 `action.dismiss()` 且有 pending/visible cycle | `dismissed` |
| 输入偏离现有建议并清理 | `stale: context_changed` |

实现时必须捕获请求发起时的 `bufnr`，不能在晚到 callback 中使用无参数 `get_ctx()` 读取当前 Buffer。该调整用于确保指标和 UI 归属正确，也应补充 Buffer 切换竞态测试。

`shown_choices` 仍可用于候选展示逻辑，但不能作为 cycle-level preview 去重的唯一依据，因为 FIM 累计 callback 当前会重置它。

### 11.7 Duet 接入点

`lua/minuet/duet/init.lua` 的 state 增加 `cycle_id`，并在以下位置记录：

| 位置 | 事件 |
|---|---|
| backend 返回非空文本 | `with_result` |
| request sequence 不匹配 | 仅非空结果且未显式 dismiss 时记录 `stale: superseded` |
| response 到达时 changedtick 不匹配 | `stale: buffer_changed` |
| marker parser 失败 | `parse_failed` |
| `preview.render()` 后确有 extmark | `preview_shown` |
| `nvim_buf_set_lines()` 成功 | `accepted`；cursor 移动失败不回滚已发生的接受 |
| apply 前 changedtick 不匹配 | `stale: apply_validation` |
| 显式 dismiss 且有 pending/visible cycle | `dismissed` |
| TextChanged 清理 visible state | `stale: buffer_changed`；pending 只标记失效，非空结果晚到时再记 stale |
| BufWipeout 清理 visible state | `stale: buffer_unloaded`；pending 采用同一晚到规则 |

事件不能只根据函数被调用就记录，必须根据实际 state 判断。

### 11.8 命令、配置和 lualine

`lua/minuet/config.lua` 增加根级 `metrics` 默认配置。

`lua/minuet/init.lua`：

- setup metrics。
- 增加 `stats` 命令补全。
- dispatch `:Minuet stats`。

`lua/minuet/lualine.lua` 使用新增 `cycle_id` 关联事件，忽略旧 cycle 晚到的 `Finished`，避免旧请求推进新请求的完成计数。旧事件缺少 ID 时保留当前 fallback 行为。

### 11.9 错误通知脱敏

以下位置当前可能把完整 provider response 放入通知，接入日志前必须改成分类消息：

- `lua/minuet/utils.lua` 的 stream/no-stream decode。
- `lua/minuet/duet/utils.lua` 的 marker parse error。
- `lua/minuet/duet/init.lua` 的 parse warning。

允许的通知示例：

```text
Minuet provider response is not valid JSON.
Minuet provider returned no completion text.
Minuet duet response has invalid editable-region markers.
```

通知可包含 provider name 和固定错误类别，不得包含 response、JSON、源码片段、headers 或 key。

### 11.10 临时请求文件硬化

`lua/minuet/utils.lua` 和 Duet 共用的 request temp-file 路径必须一并处理：

1. 在成功 JSON encode 后再创建文件，或保证 encode 失败时关闭并删除已创建文件。
2. 创建后尽力将权限设置为 `0600`。
3. 正常完成、timeout、主动取消和 spawn error 都清理文件。
4. 清理操作幂等，FIM 多 request 共用一个 data file 时只在最后一个 request 终结后删除。
5. 临时文件名和 raw error 不进入 JSONL。

当前 FIM 的并行 requests 共享同一个 request body 文件，因此不能沿用“任意一个子请求结束立即删除”的简单策略；需要按 cycle 的未完成 request 数计数，或让每个 request 使用独立 temp file。优先采用计数方式，避免重复序列化同一请求体。

## 12. 实施顺序与提交边界

建议将本步骤拆成以下小提交，而不是一个巨大提交：

1. `test: define metrics and lifecycle contract`
2. `feat: add session metrics and request correlation`
3. `feat: record virtual text and duet lifecycle`
4. `feat: add safe local metrics log and stats command`
5. `docs: add metrics, smoke test, and regression guide`

每个提交都应保持测试通过。不要为了目录整齐提前拆分 Duet apply、scheduler 或 controller。

## 13. 自动测试计划

### 13.1 新增 `tests/metrics_spec.lua`

至少覆盖：

1. ID 严格递增且同一秒内不冲突。
2. 一个 FIM cycle、三个 requests 的计数正确分离。
3. 重复 `Finished` 不重复计数。
4. 旧 request 在新 cycle 后结束时不串账。
5. 每种 request terminal status 正确聚合。
6. 同一 cycle 重复 render 只计一次 preview。
7. partial accept 只计一次 cycle accepted。
8. `get()` 返回深拷贝。
9. latency 样本有界，`samples` 与 `retained` 正确。
10. JSONL 关闭时不创建 timer、目录或文件。
11. JSONL 每行可独立 `vim.json.decode()`。
12. JSONL 写失败不影响 record 调用。
13. fake API key、源码、prompt、response 和路径 sentinel 不出现在日志。
14. setup 重复调用不重复注册状态或 autocmd。

### 13.2 新增 `tests/virtualtext_spec.lua`

至少覆盖：

1. FIM 多次累计 callback 不重复计算 cycle 或 preview。
2. completion menu 抑制 preview 时不计 `preview_shown`。
3. CursorHold、next/prev 和重复 render 不重复计数。
4. 用户输入匹配建议前缀时不算 dismiss/stale。
5. 用户输入偏离建议时记录 `context_changed`。
6. 完整接受在实际写入后记录 accepted。
7. 分行接受只记录一次 cycle accepted。
8. 无建议时 accept/dismiss 不增加指标。
9. 新 cycle 到来后旧非空 callback 记录 stale 且不更新错误 Buffer。
10. 请求期间切换 Buffer 时 callback 仍关联原始 Buffer 和 cycle。

### 13.3 扩展 `tests/duet_init_spec.lua`

至少覆盖：

1. preview shown 恰好一次。
2. apply 成功后 accepted 恰好一次。
3. 显式 dismiss 恰好一次。
4. response-time changedtick stale。
5. TextChanged 清理 visible preview 时 stale。
6. apply-time stale。
7. 新 predict 后旧 callback 不产生 preview。
8. malformed marker 只产生分类 parse failure，事件不含模型输出。
9. cursor-only/no-op 维持当前行为并被计为 shown。

### 13.4 扩展 transport 和 utils 测试

在 `tests/duet_transport_spec.lua` 和 `tests/utils_spec.lua` 覆盖：

- 正常响应。
- marker 被拆分到多个 SSE chunk。
- timeout 有 partial text 和无 text 两种情况。
- malformed JSON、空响应和 extractor error。
- spawn error。
- 主动取消后晚到 callback。
- fake API key 和 raw response 不进入 event/log。

### 13.5 命令测试

新增最小的真实 root module 测试，覆盖：

- `:Minuet stats` 可 dispatch。
- command completion 包含 `stats`。
- 输出分母为零时不显示虚假的 `0%` 接受率。
- 输出不包含敏感 sentinel。

现有多数测试通过 stub `package.loaded['minuet']`，该命令测试必须真正加载 `lua/minuet/init.lua`，否则无法覆盖 user command wiring。

## 14. 性能要求

需要给 `make benchmark` 增加 metrics 热路径检查，至少验证：

1. JSONL 关闭时没有文件系统调用。
2. 连续记录大量事件后，cycle 去重状态和 latency 样本不会无限增长。
3. 事件记录不执行 prompt stringify、源码 hash 或 Buffer 全文读取。
4. JSONL 写入使用有界队列和异步批处理。
5. metrics 模块在 idle 时没有活跃 timer；只有 JSONL 开启且队列非空时才允许短期 flush timer。

本步骤不先规定武断的微秒阈值。首次 benchmark 结果应写入本文实施记录，作为 Phase 1 热路径优化的基线。

## 15. DeepSeek 手动 Smoke Test

### 15.1 配置

以下配置与 2026-08-03 的真实双通道验证一致：

```lua
require('minuet').setup {
    provider = 'openai_fim_compatible',
    n_completions = 1,
    provider_options = {
        openai_fim_compatible = {
            model = 'deepseek-v4-flash',
            end_point = 'https://api.deepseek.com/beta/completions',
            api_key = 'DEEPSEEK_API_KEY',
            name = 'Deepseek',
            stream = true,
            optional = {
                max_tokens = 64,
                temperature = 0,
            },
        },
    },
    duet = {
        provider = 'openai_compatible',
        provider_options = {
            openai_compatible = {
                model = 'deepseek-v4-flash',
                end_point = 'https://api.deepseek.com/chat/completions',
                api_key = 'DEEPSEEK_API_KEY',
                name = 'Deepseek',
                stream = true,
                optional = {
                    max_tokens = 512,
                    temperature = 0,
                    thinking = { type = 'disabled' },
                },
            },
        },
    },
}
```

真实请求前，在 shell 环境设置 `DEEPSEEK_API_KEY`。不要把 key 直接写进配置、测试 fixture、命令历史或本文验证记录。仓库提供的手动入口不会被 `make test` 或 CI 自动执行：

```sh
read -rsp 'DeepSeek API key: ' DEEPSEEK_API_KEY
export DEEPSEEK_API_KEY
make smoke-deepseek
unset DEEPSEEK_API_KEY
```

`tests/deepseek_smoke.lua` 只使用临时、无真实源码的 Buffer；执行结束后删除临时请求文件和 JSONL。脚本不打印模型返回内容或 raw error，只输出分类计数和聚合延迟。

### 15.2 FIM 检查

1. 新建不包含真实项目源码和凭据的临时 Lua 文件。
2. 输入一个未完成的小函数并停在插入位置。
3. 调用 `require('minuet.virtualtext').action.next()`。
4. 确认有 virtual text 时，分别测试 accept 和 dismiss。
5. 执行 `:Minuet stats`。
6. 确认一个手动触发对应一个 completion cycle 和一个 request。
7. 确认实际显示后 `preview_shown` 增加，实际接受后 `accepted` 增加。

### 15.3 Duet 检查

1. 在同一无敏感内容的临时文件中完成一次局部修改。
2. 执行 `:Minuet duet predict`。
3. 确认返回内容通过 marker parser 并显示 diff/cursor preview。
4. 一次使用 `:Minuet duet dismiss`，另一次使用 `:Minuet duet apply`。
5. 再发起一次预测，并在响应前修改 Buffer，确认结果 stale 且不显示。
6. 执行 `:Minuet stats`，核对 shown、accepted、dismissed 和 stale。

### 15.4 安全日志检查

1. 仅在临时环境开启 JSONL。
2. 在测试代码中放入易识别但不是真实凭据的 sentinel。
3. 完成 FIM、Duet、timeout 和 malformed response 测试。
4. 检查 JSONL 中不存在 sentinel、源码、prompt、路径或 fake key。
5. 检查每行都能独立解析为 JSON。
6. 检查关闭 JSONL 后不会继续写入。

### 15.5 API 验证记录

2026-08-03 使用真实 DeepSeek API 完成一次本机验证，记录如下：

| 日期 | 通道 | Endpoint | Model | 结果 | P50/P95 | 备注 |
|---|---|---|---|---|---|---|
| 2026-08-03 | FIM | `/beta/completions` | `deepseek-v4-flash` | 通过 | 921.65 / 1122.15 ms | 2 次 streaming 请求；preview 2、accept 1、dismiss 1 |
| 2026-08-03 | Duet | `/chat/completions` | `deepseek-v4-flash` | 通过 | 1103.07 / 1128.18 ms | 3 次 streaming 请求；marker parse、apply、dismiss、stale 均通过 |

以上 P50/P95 仅来自单次 smoke 的 2/3 个请求，用于证明指标链路与接口可用，不作为性能基线或服务质量结论。执行时 [DeepSeek 官方 FIM 文档](https://api-docs.deepseek.com/guides/fim_completion/) 和 [completion schema](https://api-docs.deepseek.com/api/create-completion) 以 `deepseek-v4-pro` 展示 FIM，但仓库默认的 `deepseek-v4-flash` 已先通过额外的最小 completion 探针，再由本 smoke 验证 streaming 与完整前端生命周期；兼容性结论来自真实响应，不由配置或 schema 外推。

如果服务端拒绝 model、stream 或 optional 字段，应记录分类错误和最终可用配置，不得记录服务端 raw response 或 key。

## 16. 人工回归清单

在进入 Phase 1 前至少执行以下场景：

| # | 场景 | 预期行为 | 重点指标 |
|---:|---|---|---|
| 1 | virtual text 当前行插入 | 显示并完整接受 | shown、accepted |
| 2 | virtual text 多行插入 | 分行接受后继续显示剩余内容 | accepted 每 cycle 一次 |
| 3 | virtual text 多候选 | next/prev 不重复 impression | shown 不重复 |
| 4 | virtual text 显式 dismiss | preview 消失 | dismissed |
| 5 | 输入匹配建议前缀 | 剩余建议继续显示 | 不算 stale |
| 6 | 输入偏离建议 | preview 清理 | context_changed |
| 7 | 新请求覆盖旧请求 | 旧结果不污染新 cycle | cancelled/stale 关联正确 |
| 8 | completion menu 可见 | virtual text 被抑制 | 不算 shown |
| 9 | Duet 插入 | diff 可见且可 apply | shown、accepted |
| 10 | Duet 替换 | 原区域被正确替换 | shown、accepted |
| 11 | Duet 删除 | 删除 preview 可见 | shown、accepted |
| 12 | Duet cursor-only/no-op | 保持当前基线行为 | shown，暂不过滤 |
| 13 | Duet 请求中继续编辑 | 晚到结果被丢弃 | stale |
| 14 | Duet preview 后编辑再 apply | apply 被拒绝 | apply_validation |
| 15 | Duet 显式 dismiss | 不修改 Buffer | dismissed |
| 16 | timeout/空响应 | 不显示建议 | request outcome |
| 17 | malformed marker | 不显示且不泄露内容 | parse_failed |
| 18 | `:Minuet stats` | 数值与操作一致 | 聚合正确 |
| 19 | JSONL 隐私 sentinel | 日志不含内容 | allowlist |
| 20 | `.env` 边界 | recent edits 默认排除，但主动 completion 仍须谨慎 | 文档描述准确 |

## 17. 验收标准

### 17.1 正确性

- 一个 FIM cycle 与多个 transport requests 能正确区分。
- 新旧 cycle 的 request、callback 和 lualine 状态不会串账。
- 一个 cycle 的重复 render 不会重复增加 preview shown。
- accepted 只在 Buffer 实际修改成功后记录。
- stale、dismissed 和 parse failed 有稳定、可测试的分类原因。
- `:Minuet stats` 能显示 completion/Duet 请求延迟、展示数、接受数和过期数。
- 所有现有测试通过。

### 17.2 隐私

- metrics 和公开事件中没有源码、prompt、response、路径或凭据。
- JSONL 默认关闭。
- JSONL 只使用字段白名单。
- raw provider response 不再进入相关错误通知。
- fake key 和 sentinel 扫描测试通过。

### 17.3 性能

- JSONL 关闭时无新增磁盘 I/O 和后台 timer。
- 内存中的 latency 和去重状态有明确上限。
- 任何 metrics/logging 操作都不在输入事件同步路径执行慢 I/O。
- benchmark 结果已记录，可作为 Phase 1 基线。

### 17.4 行为边界

- 不新增自动 Duet 请求。
- 不覆盖用户 `<Tab>`。
- 不改变 provider prompt、候选内容或 preview 样式。
- 不声称 cmp、Blink 或 LSP 的接受率已经可观测。
- metrics/logger 故障不影响编辑、请求 callback 或 apply。

## 18. 验证命令

实现完成后执行：

```sh
make test
make format-check
make benchmark
# 仅手动执行；需要已导出的 DEEPSEEK_API_KEY
make smoke-deepseek
```

真实 DeepSeek smoke test 不能加入自动测试，也不能依赖 CI 中存在 API key。

## 19. 退出条件

只有同时满足以下条件，才开始编写并实施 Phase 1 文档：

1. 本文所有自动验收项通过。
2. DeepSeek FIM 和 Chat endpoint 至少完成一次真实 smoke test，或明确记录外部阻塞原因。
3. 人工回归清单已执行并记录结果。
4. 已确认 JSONL 不含源码、prompt、路径和凭据。
5. 当前行为的基线 benchmark 已记录。
6. metrics 口径在实施中没有未解决歧义。

Phase 1 完成后再收集至少 100 次真实建议，用于决定 Phase 2 的候选评分，不应在本步骤提前实现复杂候选系统。

## 20. 实施记录

本节在代码完成后更新，不另建“完成报告”文档。

| 项目 | 结果 |
|---|---|
| 实施状态 | Phase 0 代码、公开 API、自动测试、benchmark 与真实 DeepSeek smoke 已完成 |
| 完成日期 | 2026-08-03 |
| 相关 commits | 尚未提交；结果位于当前工作区 |
| `make test` | 通过，102 个测试 |
| `make format-check` | 通过，StyLua 2.5.2 |
| `make benchmark` | 通过；metrics 热路径与现有 Duet edits 基线均已记录 |
| DeepSeek FIM smoke | 通过；`deepseek-v4-flash`，2 次 streaming 请求，preview/accept/dismiss 与指标链路正常 |
| DeepSeek Duet smoke | 通过；`deepseek-v4-flash`，3 次 streaming 请求，marker/apply/dismiss/stale 与指标链路正常 |
| 与本文偏差 | 增加内部只读 `cycle_has_pending_requests()`，用于区分自定义 backend callback 与仍在运行的内置 transport；不属于稳定公开 API |
| 遗留问题 | 保留 Phase 0 已知竞态：显式 dismiss 后晚到 callback 仍可能重新 render；完整手动输入后可能保留空 extmark，均留待统一 controller 阶段处理 |

### 20.1 自动验收结果

- FIM transport 集成测试验证一个 cycle、三个并行 request、唯一 request ID、累计 callback 和共享临时文件最终清理。
- Virtual Text 覆盖重复 callback/render、completion menu 抑制、输入前缀匹配、上下文偏离、完整/分行接受、pending dismiss、新旧 cycle 和跨 Buffer callback。
- Duet 覆盖 shown、apply、dismiss、response-time/TextChanged/apply-time stale、superseded callback、malformed marker 隐私和 cursor-only preview。
- decoder 覆盖 success、partial、timeout、transport error、malformed JSON、extractor error 和 empty response；transport 另覆盖 spawn error 与主动取消晚到退出回调。
- JSONL 验证默认关闭无文件、`0700`/`0600` 权限、字段白名单、sentinel 扫描、有界队列、写失败降级及逐行 JSON decode。
- 手动 `make smoke-deepseek` 使用真实 FIM/Chat endpoint 验证 39 条 JSONL 和 24 个 lifecycle payload 均不含 API key、源码 sentinel、fake key 或临时 Buffer 路径；关闭 logger 后文件不再变化。
- 真实 root module 测试验证 `:Minuet stats` dispatch、命令补全、零分母 `n/a` 和敏感配置不进入输出。
- 人工回归清单对应的状态路径已通过无头 Neovim 等价操作覆盖；当前执行环境未进行交互式视觉检查。

### 20.2 2026-08-03 基线 Benchmark

当前机器的一次 `make benchmark` 结果如下。该数据只作为后续同机比较基线，不设跨机器绝对阈值。

| 项目 | 结果 |
|---|---:|
| metrics 10,000 cycles / 70,000 updates | 88.79 ms |
| metrics 平均每 cycle | 8.88 us |
| metrics 平均每 update | 1.27 us |
| 有界状态饱和后的 Lua heap 增量 | 26.66 KB |
| request latency 保留窗口 | 64 / 10,512 samples |
| JSONL 关闭时 filesystem/timer/encode/Buffer read | 0 / 0 / 0 / 0 |
| JSONL 32 次 enqueue、队列上限 8 | 0.27 ms，丢弃 24 条 |
| Duet 2,000 行 sparse/full flush | 1.54 / 3.14 ms |
| Duet 10,000 行 sparse/full flush | 3.51 / 14.01 ms |
| Duet 18,000 行 sparse/full flush | 5.12 / 26.32 ms |
| TextChangedI recorder callback | 1.10 us/event |
| recent-edits tracking state | 1.59 KB/buffer |

### 20.3 真实 DeepSeek Smoke 记录

2026-08-03 通过隐藏的进程输入临时注入用户提供的凭据，未把凭据写入仓库、配置、命令历史、JSONL、测试输出或本文。`make smoke-deepseek` 对 `/beta/completions` 发出 2 次 FIM 请求，对 `/chat/completions` 发出 3 次 Duet 请求；所有 transport outcome 均为 `success`。FIM 完成 preview、accept、dismiss，Duet 完成 marker parse、preview、apply、dismiss，以及响应到达前修改 Buffer 的 stale 丢弃。测试结束后已清除进程环境变量并删除临时目录。
