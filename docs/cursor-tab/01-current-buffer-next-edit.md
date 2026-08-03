# Cursor Tab 第二实施步骤：当前 Buffer 连续 Next Edit（Phase 1）

> 状态：已完成（代码、自动验收、人工 TUI 回归与真实 continuous smoke 全部通过；Phase 2 仍受 100 条真实 visible 数据门禁约束）
>
> 前置条件：[`00-observability-baseline.md`](00-observability-baseline.md) 已完成自动验收、benchmark 与真实 DeepSeek smoke
>
> 范围：仅当前 Buffer、仅光标附近 editable region、一次最多一个可见建议

## 1. 为什么现在做这一步

Phase 0 已经把现有 FIM 与 Duet 的请求、结果、预览、接受、dismiss、stale 和 parse failure 变成了可测量行为，并完成以下基线验证：

- 自动测试共 102 项通过。
- JSONL 默认关闭，启用时只写字段白名单，不包含源码、prompt、路径或凭据。
- DeepSeek FIM 与 Chat streaming endpoint 已通过真实请求。
- 当前机器的真实 smoke 中，FIM P50/P95 为 921.65/1122.15 ms，Duet P50/P95 为 1103.07/1128.18 ms。
- 当前实现的晚到 callback、跨 Buffer callback、changedtick stale 和 marker parse failure 已有回归测试。

这些结果说明当前 transport、prompt 协议和 preview 足以支撑下一步。Phase 1 不再增加观测基础设施，而是把只能手动触发的实验性 Duet 变成一个可选择启用、不会打断输入、可以连续接受的当前 Buffer Next Edit 工作流。

本阶段必须同时修复 Phase 0 留下的两个 controller 边界：

1. 显式 dismiss 后，晚到 callback 不能重新显示建议。
2. Virtual Text 建议被完整输入或清理后，不能留下仍被仲裁器视为可见的空状态。

## 2. 本阶段目标

完成后，用户在显式开启自动 Duet 时应得到以下流程：

```text
用户编辑当前 Buffer
  -> debounce 等待输入停顿
  -> scheduler 检查抑制条件与 throttle
  -> controller 决定 FIM / Duet 所有权
  -> Duet 请求当前光标附近的局部编辑
  -> parser、filter、changedtick 校验
  -> 显示一条 diff/cursor preview
  -> 用户通过统一 Tab API 接受，或显式 dismiss
  -> 接受成功后延迟调度下一次 Duet
```

具体目标：

1. 新增可取消的 Duet scheduler，支持 debounce、throttle、generation、`InsertLeave` 和接受后续预测。
2. 新增统一 suggestion controller，使 Virtual Text 与 Duet 最多只有一个 pending/visible owner。
3. 自动 Duet 与 Virtual Text FIM 按明确优先级互斥，并对被替换的内置 transport 做定向取消。
4. 新增统一 Tab 仲裁 API，但不创建默认 `<Tab>` 映射。
5. 将 Duet 的过滤、验证和 apply 从协调逻辑中拆出，保证错误目标不会被应用。
6. 丢弃 no-op、纯空白和超过安全上限的模型结果。
7. 每次应用形成一个可预测的 undo 单元，光标位置合法，接受后可以继续预测。
8. 保持现有手动 `predict/apply/dismiss` API 与默认行为可用。

## 3. 明确不做

本阶段不实现：

- 不发现或排序光标以外的候选位置。
- 不根据 diagnostics、references、document symbols 或文本匹配选择位置。
- 不显示 jump hint，不实现“两次 Tab：先跳转、再应用”。
- 不读取或修改其他 Buffer。
- 不加入跨文件上下文、import/require 扫描或 workspace 索引。
- 不把 marker 协议改成 JSON schema。
- 不让模型返回绝对路径、行号或多个编辑。
- 不默认启用自动 Duet，不默认产生额外付费请求。
- 不默认覆盖 `<Tab>`，不内置绑定某一个 snippet/completion 插件。
- 不把 cmp、Blink、LSP completion 或 LSP inline completion 的 UI 纳入本阶段 controller。
- 不重写 HTTP transport、recent-edit diff recorder 或现有 diff renderer。
- 不把 prompt、response、建议文本或 Buffer 内容加入 metrics/event/JSONL。
- 自动测试不访问真实 DeepSeek API，也不依赖任何 API key。

Phase 2 才处理当前 Buffer 的远处候选和跳转；Phase 3 才处理 LSP 与相关上下文；Phase 4 才允许受限跨 Buffer 建议。

## 4. 当前实现与问题边界

| 模块 | 当前行为 | Phase 1 问题 |
|---|---|---|
| `lua/minuet/virtualtext.lua` | 自己持有 request、候选、extmark 与 timer | 不知道 Duet 是否 pending/visible |
| `lua/minuet/duet/init.lua` | 手动 predict，按 Buffer 持有 pending 与 preview state | 协调、解析、apply、清理集中在一个模块 |
| `lua/minuet/duet/edits.lua` | 记录 recent-edit burst，支持 lazy setup | 自动预测启用时，lazy recorder 必须在第一次编辑前建立 baseline |
| `lua/minuet/backends/common.lua` | completion job 只能整体 `terminate_all_jobs()` | 跨通道仲裁不能误杀无关 cycle |
| `lua/minuet/duet/backends/common.lua` | Duet job 只能整体取消 | controller 无法只取消被替换的 prediction |
| `lua/minuet/duet/preview.lua` | 可显示插入、删除、替换和 cursor-only | no-op/cursor-only 目前也可能成为可见建议 |
| `lua/minuet/metrics.lua` | 已有 request 与 suggestion lifecycle | controller 不能重复发 accepted/dismissed/stale |
| 用户配置 | Duet 只能手动触发，Tab 各自绑定 | 无连续工作流和统一 fallback |

### 4.1 保留的正确基础

以下行为继续复用：

- `context.build()` 仍围绕当前窗口光标构造 editable region。
- 默认 editable region 仍为光标前 8 行、后 15 行。
- recent edits 继续使用现有 snapshot、external diff 和字符预算。
- provider 继续使用现有 OpenAI-compatible、Gemini、Claude 与 OpenAI transport。
- response 继续使用 `<editable_region>` 和 `<cursor_position/>` marker。
- preview 继续使用现有 extmark 与 diff highlight。
- metrics 继续由 frontend/transport 记录，controller 不成为第二套统计源。

### 4.2 本阶段的兼容范围

统一 controller 只覆盖：

- `minuet.virtualtext` 展示的 FIM 建议。
- `minuet.duet` 展示的 Next Edit 建议。

cmp、Blink、LSP completion 和 LSP inline completion 仍保留自己的 UI 与接受流程。它们的 request metrics 继续工作，但其候选可见性不参与本阶段 Tab 仲裁。README 必须明确这一边界，不能声称所有 frontend 已统一。

## 5. 固定设计决策

### 5.1 自动 Duet 默认关闭

`duet.auto_trigger.enabled` 默认必须为 `false`。

理由：

- 自动 Chat 请求会产生费用和网络流量。
- 当前真实 smoke 只有少量请求，还没有 100 次以上真实建议的接受率数据。
- roadmap 规定只有达到质量门后才考虑默认开启自动 Duet。
- 手动 `:Minuet duet predict` 必须继续不受此开关影响。

### 5.2 一次只有一个 UI owner

在 Virtual Text 与 Duet 范围内，全局最多存在一个 active lease：

- `pending`：provider 已准备或已发出请求，但没有可见 preview。
- `visible`：建议已经实际渲染并可接受。
- terminal：`accepted`、`dismissed` 或 `stale`，进入后立即释放 owner。

即使多个 Buffer 中保留内部 context，也不能在两个 Buffer 同时留下可接受的 Minuet UI。切换 Buffer 时，当前 owner 必须失效或被清理。

### 5.3 先统一所有权，不迁移全部 payload

本阶段采用 adapter-first 方案：

- controller 持有 source、bufnr、changedtick、generation、phase 和操作回调。
- Virtual Text 的候选字符串仍由 `virtualtext.lua` 持有。
- Duet 的 range、original lines、proposed lines 和 cursor 仍由 Duet state 持有。
- controller、metrics 和事件中不得复制 suggestion text。

Phase 2 引入远处 anchor 时，再把 payload 迁移为 roadmap 中完整的 `minuet.Suggestion` 数据模型。本阶段不为了类型整齐提前重写两个 renderer。

### 5.4 手动意图高于自动意图

用户显式调用 `virtualtext.action.next()` 或 `duet.action.predict()` 时，新的手动请求可以替换当前 pending/visible owner。自动任务不能替换一个已经可见的建议。

### 5.5 安全失效高于复用

第一版继续要求请求时 `changedtick` 与应用时完全一致。即使 Buffer 其他位置变化而 editable region 未变，也直接判 stale，不做 extmark 重定位或乐观复用。

## 6. Controller 状态模型

新增 `lua/minuet/suggestion.lua`，负责 Virtual Text 与 Duet 的所有权、generation 和 Tab 操作分发。

### 6.1 内部类型

```lua
---@alias minuet.SuggestionSource 'fim'|'duet'
---@alias minuet.SuggestionIntent 'manual'|'auto'|'after_accept'
---@alias minuet.SuggestionPhase 'pending'|'visible'|'accepting'|'accepted'|'dismissed'|'stale'

---@class minuet.SuggestionLease
---@field id integer
---@field generation integer
---@field source minuet.SuggestionSource
---@field intent minuet.SuggestionIntent
---@field bufnr integer
---@field changedtick integer
---@field phase minuet.SuggestionPhase
---@field cycle_id? integer
---@field ops? minuet.SuggestionOps

---@class minuet.SuggestionOps
---@field cancel fun(reason: string)
---@field can_accept? fun(): boolean, string?
---@field accept fun()
---@field dismiss fun(reason: string, explicit: boolean)
---@field is_visible fun(): boolean
```

`SuggestionLease` 不包含 anchor text、new text、prompt、response、路径或 API 配置。

### 6.2 内部 API

```lua
local controller = require 'minuet.suggestion'

local lease = controller.begin {
    source = 'duet',
    intent = 'auto',
    bufnr = bufnr,
    changedtick = changedtick,
}

controller.attach(lease, {
    cancel = cancel,
    can_accept = can_accept,
    accept = accept,
    dismiss = dismiss,
    is_visible = is_visible,
})

controller.is_current(lease)
controller.mark_visible(lease)
controller.finish(lease, 'stale', 'buffer_changed')
controller.accept_visible()
controller.dismiss_visible()
controller.invalidate_buffer(bufnr, 'buffer_changed')
controller.reset()
```

约束：

- `begin()` 返回 `nil` 表示当前优先级不允许启动，调用方不能创建 metrics cycle 或发网络请求。
- `attach()` 只能对 current lease 调用一次。
- 所有异步 callback 在解析、修改 source state 或 render 前必须先调用 `is_current()`。
- `mark_visible()` 只有在 extmark 实际存在后调用；若 lease 已过期，frontend 立即清除刚生成的 extmark。
- `finish()` 和所有 terminal 操作幂等，同一个 lease 只能进入一次 terminal state。
- `accept_visible()` 返回的是本次按键是否已被 source 接管：它先执行只读 preflight，再安排 source accept；实际 Buffer 修改和 accepted terminal state 可以稍后发生。
- 未提供 `can_accept` 时以 `is_visible()` 作为 preflight；preflight 返回 false 时调用 source 的非显式 stale/clear 路径并释放 lease，然后允许 Tab fallback。
- preflight 通过后，controller 在调用 source accept 前把 lease 转为 `accepting`；该状态继续阻止自动请求，但不接受第二次 Tab，避免 key repeat 排入两个 apply。
- source `accept` 抛错时，controller 必须释放 `accepting` lease 后原样抛出，不能留下永久占用 owner。
- source 只有在 Buffer 实际修改成功后才能 finish accepted 和记录 accepted metrics；controller 的 handled 返回值不能替代该事实。
- controller 不直接记录 suggestion metrics；source adapter 在实际 render/apply/dismiss/stale 位置保留现有统计责任。
- `reset()` 用于重复 `setup()`、测试清理和退出，必须取消 active lease 且不留下 timer/extmark。

### 6.3 状态转换

```text
idle
  -> begin
pending
  -> actual render
visible
  -> preflight passed and accept scheduled
accepting
  -> successful apply/insert
accepted

pending|visible|accepting
  -> explicit user dismiss
dismissed

pending|visible|accepting
  -> buffer/context change, supersede, unload, failed apply validation
stale

pending
  -> empty response, parse failure, filtered result, transport terminal without result
idle
```

parse failure 继续由 metrics 记录为 `parse_failed`；它不是 controller 新增的公开 phase。过滤结果静默释放 lease，不伪装成 dismiss 或 stale。

### 6.4 优先级矩阵

| 当前 owner | 新动作 | 结果 |
|---|---|---|
| 无 | 任意 manual/auto | 允许 |
| visible/accepting FIM 或 Duet | 自动 FIM/Duet | 拒绝新动作，保留当前 owner |
| visible/accepting FIM 或 Duet | 手动 FIM/Duet | 旧建议以 `superseded` 失效，新动作允许 |
| pending FIM | 自动 Duet | 取消该 FIM cycle，允许 Duet |
| pending Duet | 自动 FIM | 拒绝 FIM |
| pending 同 source | 更新后的自动动作 | 旧 generation 失效并定向取消，保留最新一次 |
| pending 任意 source | 手动动作 | 旧 generation 失效并定向取消，允许手动动作 |
| idle（刚释放 accepted lease） | `after_accept` Duet | 经过 scheduler debounce/throttle 后尝试 |

Buffer 编辑不是一个全局的无条件 invalidate：

- Duet pending/visible/accepting 在 `TextChanged*` 后立即失效。
- Virtual Text 继续先执行现有“用户输入是否匹配建议前缀”逻辑；匹配时缩短建议并保留 lease，偏离时才 stale。
- BufLeave、BufUnload、BufWipeout 对匹配 Buffer 的 lease 一律失效。

## 7. 定向 Transport 取消

generation 能阻止晚到 callback 更新 UI，但不能停止无用网络请求。Phase 1 同时增加按 cycle 取消，避免 controller 只能调用会误伤其他请求的 `terminate_all_jobs()`。

### 7.1 Job state 扩展

completion 与 Duet 的 job state 增加：

```lua
---@field cycle_id? integer
```

`start_job()` 的 handlers/options 接受当前 metrics `cycle_id`，所有内置 backend 在创建 job 时传入该值。

### 7.2 新增取消 API

两个 common 模块都新增内部 API：

```lua
terminate_cycle(cycle_id)
```

行为：

1. 复制当前 job 列表，避免 kill callback 修改正在遍历的表。
2. 只选择 `state.cycle_id == cycle_id` 且尚未退出的 job。
3. 先设置 `cancel_requested = true`，再发送 `sigterm`。
4. FIM 一个 cycle 有多个并行 request 时必须全部取消。
5. 晚到 `on_exit` 仍正常释放临时文件，并记录 request outcome `cancelled`。
6. 不重复 finish metrics，不取消其他 cycle。
7. 保留现有 `terminate_all_jobs()`，供同 backend 的旧行为和退出清理使用。

自定义 backend 若没有注册可取消 job，controller 仍通过 generation fence 保证 UI 正确；本阶段不要求第三方 backend 实现进程取消协议。

## 8. Duet Scheduler

新增 `lua/minuet/duet/scheduler.lua`。scheduler 只负责何时尝试自动 prediction，不构造 prompt、不读取整份 Buffer、不调用 renderer。

### 8.1 配置

```lua
duet = {
    auto_trigger = {
        enabled = false,
        debounce = 900,
        throttle = 1500,
        on_insert_leave = true,
        after_accept = true,
        max_buffer_size = 1000000,
        enable_predicates = {
            -- 默认拒绝 dotenv、常见 credential 路径和 binary Buffer
        },
    },
    max_edit_lines = 40,
    max_edit_chars = 12000,
}
```

语义：

- `debounce`：最后一次有意义编辑或接受后，至少等待多少毫秒。
- `throttle`：两次自动 Duet request start 之间的最小毫秒数；手动 predict 不被阻止，但会更新最近 request start。
- `on_insert_leave`：存在 dirty edit burst 时，InsertLeave 可以提前把任务推进到下一次 event loop；仍需满足 throttle 和全部 gate。
- `after_accept`：FIM 或 Duet 接受成功后，用同一 debounce 调度下一次 Duet。
- `max_buffer_size`：只限制自动触发；手动行为保持兼容。
- `enable_predicates`：只限制自动触发，覆盖默认列表时必须在文档中提醒用户自行保留 secret guard。
- `max_edit_lines`：按 diff hunk 的实际修改行数限制建议，不是 editable region 总行数。
- `max_edit_chars`：限制 proposed editable region 的总字节数，防止单行超大输出绕过行数限制。

所有非负整数配置都要规范化；非法值回退默认值，不能让 timer 接收负数、NaN 或字符串。

### 8.2 Recorder 启动关系

`recent_edits.enabled = 'lazy'` 在纯手动模式下保持现有语义。

当 `auto_trigger.enabled = true` 时，scheduler setup 必须调用 `edits.ensure_setup()`，在用户下一次编辑前建立 baseline。否则第一次自动 prediction 会在编辑完成后才启动 recorder，丢失最重要的 recent-edit burst。

如果 `recent_edits.enabled = false`，scheduler 仍可根据 `TextChanged*` 的 dirty generation 自动触发，但 prompt 中不包含 edit history。

### 8.3 调度状态

scheduler 至少持有：

```lua
---@class minuet.DuetScheduleState
---@field generation integer
---@field bufnr? integer
---@field dirty_tick? integer
---@field dismissed_tick? integer
---@field due_reason? 'text_changed'|'insert_leave'|'after_accept'
---@field last_started_ns? number
---@field timer? uv.uv_timer_t
```

只允许一个 active scheduler timer。新编辑重启同一个 debounce；BufLeave、BufWipeout、重复 setup 和关闭 auto trigger 都必须 stop + close timer。

### 8.4 事件与动作

| 事件 | 同步路径 | 延迟路径 |
|---|---|---|
| `TextChanged`/`TextChangedI`/`TextChangedP` | generation +1、标记 dirty、使 Duet lease 失效、定向取消 pending transport、重启 timer | debounce 到期后检查 gate |
| `InsertLeave` | 若 dirty 且配置允许，安排一次 scheduled callback | callback 中检查 throttle/gate |
| FIM accepted | 不直接请求 | 以 `after_accept` 原因启动 debounce |
| Duet accepted | 清理旧 preview/state | 以 `after_accept` 原因启动 debounce |
| explicit dismiss | 记录当前 changedtick | 相同 changedtick 不自动重试 |
| `BufLeave`/`BufWipeout` | generation +1、取消 timer/lease | 无 |
| repeated setup | 清掉旧 autocmd/timer | 按新配置重新建立 |

TextChanged autocmd 的同步路径禁止：

- 读取完整 Buffer。
- 执行 diff。
- 构造 prompt。
- 调用 LSP。
- 发网络请求。
- 写磁盘。

### 8.5 自动触发 gate

timer 到期后，只有全部满足时才能创建 controller lease：

1. `auto_trigger.enabled == true`。
2. bufnr 仍是当前、有效、loaded、普通 `buftype` 且 `modifiable`。
3. Buffer 大小不超过 `max_buffer_size`。
4. changedtick 仍对应 scheduler 记录的最新 dirty generation。
5. `mode(1)` 是普通模式 `n` 或插入模式 `i*`，且当前不在 paste mode、macro recording/executing 或命令行窗口；operator-pending、replace、visual、select、terminal 等模式均拒绝。
6. popup completion menu、nvim-cmp view 和 Blink menu 均不可见。
7. Buffer 不是 binary，且所有 `auto_trigger.enable_predicates` 返回 true。
8. 当前 changedtick 未被用户在相同上下文显式 dismiss。
9. controller 没有可见建议。
10. controller 优先级允许自动 Duet 替换或等待当前 pending owner。

gate 失败时不创建 metrics cycle。除 throttle 尚未到期外，失败不进行轮询重试；下一次文本变化或接受事件再调度。throttle 尚未到期时只重设一次剩余时间 timer，不 busy-loop。

### 8.6 手动与自动调用

保留：

```lua
require('minuet.duet').action.predict()
```

内部 prediction 入口接受 intent，但不把复杂 opts 变成稳定 public API：

```lua
predict('manual')
predict('auto')
predict('after_accept')
```

手动调用：

- 不受 `auto_trigger.enabled`、debounce、throttle、文件大小或 auto predicates 限制。
- 仍必须满足 Buffer 有效、loaded、modifiable 和 apply 安全校验。
- 可以抢占 pending/visible owner。

## 9. Duet 结果过滤与 Apply

新增 `lua/minuet/duet/apply.lua`，隔离“建议是否值得展示”和“当前是否仍能安全应用”两个概念。

### 9.1 建议数据

```lua
---@class minuet.DuetEdit
---@field bufnr integer
---@field changedtick integer
---@field range { start_row: integer, end_row: integer }
---@field original_lines string[]
---@field proposed_lines string[]
---@field cursor minuet.DuetParseCursor
---@field hunks minuet.DuetHunk[]
---@field changed_lines integer
```

该数据只存在于内存中的 source state，不进入 metrics、公开事件或 JSONL。

### 9.2 展示前过滤顺序

模型 response 通过 marker parser 后，按以下顺序处理：

1. Buffer 与 controller lease 仍有效。
2. 请求时 changedtick 与当前 changedtick 相同。
3. range 是合法的 0-based、end-exclusive 行范围。
4. `original_lines` 与当前 range 文本完全一致。
5. proposed 与 original 完全相同时判 no-op，静默丢弃；cursor-only 不再显示。
6. 去除全部 Lua `%s` 后文本相同，说明只调整空白，静默丢弃。
7. `apply.lua` 使用现有 histogram/linematch diff 选项计算 hunks 与 changed line count：每个 hunk 累加 `max(original_count, proposed_count)`。
8. changed line count 超过 `max_edit_lines` 时丢弃。
9. proposed region 总字节数超过 `max_edit_chars` 时丢弃。
10. 通过后才写入 Duet state、render，并记录 `preview_shown`。

preview 不得再自行计算第二份 hunks；它消费 filter 阶段存入 `DuetEdit.hunks` 的结果，确保大小判定与用户看到的 diff 完全一致。apply 的最终验证重新计算一次分类，防止内部 state 被意外修改。

纯空白过滤是有意的保守策略，包括缩进-only 建议。它可能放弃少量格式/缩进修复，但可以避免模型无意义格式化；filetype-specific 例外不在 Phase 1 引入。

过滤结果：

- 不记录 `dismissed`、`stale` 或 `parse_failed`。
- 保留 transport outcome 与 `with_result` 基线口径。
- 不显示包含 response text 的通知。
- 释放 controller lease，使后续编辑可以重新调度。

### 9.3 Apply 前验证

`apply()` 必须再次验证：

1. bufnr 有效、loaded、当前且 `modifiable`。
2. lease 仍属于当前 controller generation。
3. changedtick 与请求时完全一致。
4. range 未越界且 `start_row <= end_row`。
5. 当前 range 文本与 `original_lines` 完全一致。
6. proposed lines、cursor 和大小仍满足配置限制。

任一失败：

- 不修改 Buffer。
- 记录一次 `stale`，reason 使用现有 `apply_validation`。
- 清理 preview、source state 和 controller lease。
- 若失败发生在 Tab 的同步只读 preflight，`tab.accept_or_fallback()` 执行用户 fallback。
- 若 preflight 后、scheduled apply 前发生新的竞态，第二次验证仍拒绝修改并清理 stale；此时该次 Tab 已被 Minuet 接管，不再事后执行 fallback。

### 9.4 成功应用

成功路径：

1. 使用一次 `nvim_buf_set_lines()` 替换 line-aligned editable region。
2. API 调用失败时不得记录 accepted。
3. 只在 Buffer 确实修改成功后记录 `accepted`。
4. 根据 proposed cursor 计算目标行列，并 clamp 到实际 Buffer/line 边界。
5. 设置光标后清除全部 extmark 与旧 state。
6. 释放 controller lease。
7. 若配置允许，通知 scheduler 以 `after_accept` 调度下一次 Duet。

不得通过模拟输入应用代码。一次 suggestion 使用一次 Buffer 修改 API；不要在第一次修改前调用 `undojoin`，避免把模型编辑并入用户之前的输入。测试必须证明：一次 `u` 只撤销 suggestion，再一次 `u` 才撤销 suggestion 之前的用户编辑。

## 10. Virtual Text 适配

`virtualtext.lua` 保留候选 cycling、分行接受和匹配输入前缀能力，但接入 controller lease。

### 10.1 Trigger intent

内部 `trigger()` 增加 intent：

- `action.next()` 在尚无建议时使用 `manual`。
- 现有 debounce/autotrigger 使用 `auto`。

controller 拒绝时，不创建 metrics cycle、不调用 provider。

### 10.2 Callback fence

provider callback 必须同时满足：

- 现有 request/context identity。
- controller `is_current(lease)`。
- 原 Buffer 仍 loaded/current。

任何一个不满足都不能更新 suggestions 或 extmark。显式 dismiss 后的晚到 callback 必须在这里被阻断。

### 10.3 Preview 与终态

- extmark 实际创建后才调用 `controller.mark_visible()`。
- 完整 accept 的 scheduled Buffer 写成功后才 finish 为 accepted。
- 分行 accept 在仍有剩余建议时保持同一 visible lease；metrics accepted 仍按 cycle 去重。
- 用户完整输入匹配建议时，将 request 标为 consumed、清理 extmark，并正常释放 lease，不算 stale。
- 输入偏离、InsertLeave、BufLeave 或 Buffer unload 沿用现有 reason，frontend 清理后同步释放 lease。
- explicit dismiss 只记录一次 dismissed，并取消该 cycle 的仍在运行 job。

## 11. 统一 Tab API

新增 `lua/minuet/tab.lua`。它只做 Minuet 内部优先级与 fallback 分发，不创建 keymap。

### 11.1 Public API

```lua
local tab = require 'minuet.tab'

---@param fallback? string|fun(): string
---@return string
tab.accept_or_fallback(fallback)

---@return boolean handled
tab.accept()
```

行为：

1. 若 controller 的 visible owner 是 Duet，先执行不修改 Buffer 的 apply preflight；通过后 schedule apply。
2. 否则若 visible owner 是 FIM，确认当前 suggestion 仍可见后调用现有 scheduled accept。
3. 若 Minuet 接管该按键，`accept_or_fallback()` 返回空字符串；这表示 handled，不提前表示 accepted。
4. 若没有可接受建议或 Duet preflight 已失败，调用 function fallback 一次并原样返回其字符串。
5. string fallback 原样返回；未传 fallback 时返回 `'<Tab>'`。
6. fallback 抛错时不吞掉错误，不静默插入其他字符。

controller 正常情况下不会同时有两个 visible owner；Duet-first 是防御性优先级和未来 jump 状态的基础。

表达式映射求值期间存在 Neovim textlock，`tab.lua` 和 controller 不得在同步回调中调用 Buffer mutation API。Duet 使用只读 preflight 后 `vim.schedule()` apply；scheduled apply 必须完整重做第 9.3 节验证。Virtual Text 保留现有 scheduled Buffer write。这样既不会在 expr mapping 中非法修改 Buffer，也不会把 handled 误记为 accepted。

### 11.2 推荐映射

基础映射：

```lua
vim.keymap.set('i', '<Tab>', function()
    return require('minuet.tab').accept_or_fallback()
end, { expr = true, replace_keycodes = true, desc = 'Minuet accept or Tab' })
```

已有 snippet/completion 链的用户把原逻辑放入 fallback：

```lua
vim.keymap.set('i', '<Tab>', function()
    return require('minuet.tab').accept_or_fallback(function()
        -- 保留用户已有的 snippet jump / completion menu / indentation 逻辑。
        return '<Tab>'
    end)
end, { expr = true, replace_keycodes = true, desc = 'Minuet accept or fallback' })
```

插件 setup 不调用 `vim.keymap.set()`。README 不能暗示 Minuet 自动接管 snippet、Blink 或 cmp 的 Tab 行为。

## 12. Prompt 调整

继续使用现有 marker 与 few-shot，只对默认 Duet guidelines 做最小补强：

1. 任务是预测用户最可能进行的下一次局部编辑，不是主动重构。
2. 只做与 recent edit 和当前上下文直接相关的最小修改。
3. 若没有可靠编辑，原样返回 editable region 和一个 cursor marker。
4. 不修改无关格式、空白、注释或命名。
5. 只能返回一个 editable region，不得返回其他文件或解释。

parser 对 marker 的现有兼容行为不在本阶段大改；multiple cursor marker 等当前已拒绝的情况继续拒绝。no-op 即使合法返回也会在 preview 前被过滤。

## 13. 配置与文档 API

`lua/minuet/duet/config.lua` 增加类型注解：

```lua
---@class minuet.DuetAutoTrigger
---@field enabled boolean
---@field debounce integer
---@field throttle integer
---@field on_insert_leave boolean
---@field after_accept boolean
---@field max_buffer_size integer
---@field enable_predicates (fun(bufnr: integer): boolean)[]

---@class minuet.DuetConfig
---@field auto_trigger minuet.DuetAutoTrigger
---@field max_edit_lines integer
---@field max_edit_chars integer
```

默认 secret predicate 应在 config 模块中定义一次，再分别 deepcopy 到 recent edits 与 auto trigger 的默认列表，避免两份 guard 随时间漂移。默认至少拒绝：

- `.env`、`.env.*`。
- `.netrc`、`.npmrc`、`.pypirc`。
- `credentials`、`credentials.json`、`service-account.json`。
- `id_rsa`、`id_ed25519`。
- `.pem`、`.key`、`.p12`、`.pfx` 后缀。
- 设置了 `binary` 的 Buffer。

该检查只看廉价的 Buffer option 和路径 basename/extension，不同步读取文件内容。它是保守的默认拒绝列表，不是完整 secret detector。用户覆盖其中一个 predicate 列表不应隐式修改另一个列表。

README 更新内容：

- 把“automatic duet prediction is not implemented”改为“可选，默认关闭”。
- 删除对应 TODO。
- 说明自动模式会产生 API 请求与费用。
- 给出 DeepSeek `openai_compatible` Chat 配置，使用已在 Phase 0 smoke 验证的 `deepseek-v4-flash`。
- 给出 auto trigger 与 Tab fallback 示例。
- 更新完整默认配置和 Lua API 列表。
- 明确 auto predicate 只保护自动 Duet，用户主动触发其他 frontend 仍需自行避免敏感 Buffer。

## 14. 文件改动范围

### 14.1 新增文件

| 文件 | 职责 |
|---|---|
| `lua/minuet/suggestion.lua` | Virtual Text/Duet controller、generation、owner 与操作分发 |
| `lua/minuet/tab.lua` | `accept()` 和 `accept_or_fallback()` public API |
| `lua/minuet/duet/scheduler.lua` | debounce、throttle、autocmd gate、after-accept 调度 |
| `lua/minuet/duet/apply.lua` | no-op/whitespace/size filter、apply validation、Buffer 修改与 cursor clamp |
| `lua/minuet/metrics_report.lua` | 跨 Neovim session 离线汇总 Duet JSONL、去重、完整性检查与 100 visible 数据门禁 |
| `tests/suggestion_spec.lua` | controller 状态机与优先级 |
| `tests/tab_spec.lua` | Tab/fallback 契约 |
| `tests/duet_scheduler_spec.lua` | timer、gate、request-count 与 lifecycle race |
| `tests/duet_apply_spec.lua` | filter、validation、undo 与 cursor |
| `tests/metrics_report_spec.lua` | 跨 session 聚合、去重、损坏数据、隐私输出与门禁 |

### 14.2 修改文件

| 文件 | 改动 |
|---|---|
| `lua/minuet/duet/config.lua` | auto trigger、edit limits、共享默认 secret predicate |
| `lua/minuet/init.lua` | setup/reset controller，并保持 metrics -> controller -> frontend 的确定顺序；增加 `:Minuet report [glob...]` |
| `lua/minuet/virtualtext.lua` | controller lease、intent、callback fence、accept/dismiss/consume 终态 |
| `lua/minuet/duet/init.lua` | 协调 scheduler、controller、parser、preview 与 apply，不再内联 apply 规则 |
| `lua/minuet/duet/preview.lua` | 消费 apply/filter 已计算的 hunks，不再重复执行 diff |
| `lua/minuet/backends/common.lua` | job cycle ownership 与 `terminate_cycle()` |
| `lua/minuet/duet/backends/common.lua` | job cycle ownership 与 `terminate_cycle()` |
| 内置 backend 文件 | 把已知 lifecycle cycle ID 传入 `start_job()` |
| `tests/virtualtext_spec.lua` | controller 集成、consume、dismiss late callback |
| `tests/duet_init_spec.lua` | controller 集成、filter 后不 render、after-accept |
| `tests/deepseek_smoke.lua` | 增加显式 opt-in 的自动调度连续接受场景；仍不由 `make test`/CI 执行 |
| `tests/init_spec.lua` | 真实 root module 的 report dispatch、命令补全和隐私输出 |
| completion/Duet transport specs | 定向取消与临时文件清理 |
| `README.md` | 配置、API、费用、边界与示例 |

`lua/minuet/config.lua`、`lua/minuet/duet/edits.lua` 和 `lua/minuet/metrics.lua` 预计不需要行为改动：Duet 默认值与类型留在 `duet/config.lua`，recorder 已提供 `ensure_setup()`，现有 metrics reason 已覆盖本阶段分类。如果实现确实需要修改其中之一，先在第 23 节记录原因。不要为了目录结构一次性拆分 preview、context 或所有 backend。每个新增模块必须对应本阶段可独立测试的职责。

## 15. 自动测试计划

### 15.1 Controller

至少覆盖：

1. lease ID 和 generation 严格递增。
2. 自动动作不能替换 visible owner。
3. 手动动作可以替换 pending/visible owner。
4. pending FIM 被自动 Duet 定向取消。
5. pending Duet 阻止自动 FIM。
6. same-source 新 generation 使旧 callback 失效。
7. terminal 操作幂等，ops 只调用一次。
8. Buffer invalidation 只影响匹配 lease。
9. reset 清理 owner，不保留 raw suggestion data。
10. mark-visible 前后发生 supersede 时，旧 extmark 被 source 清理。
11. preflight false 释放 lease，并允许调用方 fallback。
12. source accept 抛错后不残留 accepting owner。

### 15.2 Scheduler

至少覆盖：

1. 默认关闭时不创建 timer、autocmd request 或 recorder I/O。
2. 连续 `TextChangedI` 只保留一个 timer，debounce 期间不请求。
3. 停顿后只发一次自动 Duet。
4. throttle 到期前只重设一次剩余 timer。
5. `InsertLeave` 只有 dirty burst 时触发。
6. accepted FIM 和 accepted Duet 各只调度一次后续预测。
7. explicit dismiss 后相同 changedtick 不重试；新编辑后可重试。
8. BufLeave/Wipeout 和 repeated setup 关闭 timer。
9. popup menu、paste、macro、nonmodifiable、non-file、binary、oversized、credential path 和 predicate failure 均抑制请求。
10. auto enabled + lazy recent edits 会在首个 edit burst 前 setup recorder。
11. timer callback 中 Buffer/generation 改变时不创建 metrics cycle。
12. custom backend 不可取消时，晚到 callback 仍被 generation 丢弃。

测试使用极短 timer 和 `vim.wait()` 驱动 Neovim event loop，不使用真实 sleep 秒数，不依赖网络或系统时间精度断言。

### 15.3 Apply 与 Filter

至少覆盖：

1. 完全 no-op 不 render。
2. cursor-only 不 render。
3. trailing/leading/blank-line whitespace-only 不 render。
4. 有真实 token 变化的插入、替换和删除可 render/apply。
5. changed line count 等于上限时允许，超过一行时拒绝。
6. proposed bytes 等于上限时允许，超过一字节时拒绝。
7. changedtick 改变后 apply 不修改 Buffer。
8. original range 文本不匹配时 apply 不修改 Buffer。
9. invalid/unloaded/nonmodifiable/wrong Buffer/range 越界时安全失败。
10. Buffer API 抛错时不记录 accepted。
11. cursor row/column 被 clamp 到合法位置。
12. 一次 `u` 只撤销 suggestion，第二次 `u` 才撤销之前的用户编辑。

### 15.4 Virtual Text 与 Duet 集成竞态

至少覆盖：

1. FIM visible 时自动 Duet 不启动。
2. pending FIM 到 Duet deadline 时被取消，晚到 callback 不显示。
3. pending Duet 时自动 FIM 不启动。
4. 手动 FIM/Duet 可以显式 supersede。
5. Duet dismiss 后 late callback 不 render。
6. Virtual Text dismiss 后 late callback 不 render。
7. Virtual Text 完整输入建议后 controller 回到 idle，无空 extmark。
8. 分行 accept 保持同一 lease，完整接受后才释放。
9. Duet response parse/filter 失败后释放 owner。
10. apply 成功后只调度一个 next prediction。
11. Buf 切换后旧 Buffer callback 不影响当前 Buffer owner。
12. metrics accepted/dismissed/stale/preview 不因 controller 重复计数。

### 15.5 Tab

至少覆盖：

1. Duet visible 时 apply，fallback 不调用。
2. FIM visible 时 accept，fallback 不调用。
3. 无建议时 function fallback 恰好调用一次。
4. string fallback 原样返回。
5. 无 fallback 时返回 `'<Tab>'`。
6. stale Duet 在同步 preflight 失败后执行 fallback。
7. preflight 后到 scheduled apply 前变 stale 时不修改 Buffer、记录一次 stale，且不晚调用 fallback。
8. fallback 返回空字符串时保持空字符串。
9. fallback error 不被吞掉。
10. controller 异常状态下不同时调用两个 source action。
11. accepting 状态下第二次 Tab 不重复 schedule source action。

### 15.6 Transport

至少覆盖：

1. `terminate_cycle()` 只取消目标 cycle。
2. 一个 FIM cycle 的所有并行 request 都被取消。
3. 其他 completion cycle 继续运行。
4. Duet cancel 后 outcome 为 `cancelled`。
5. cancel 与 process 正常退出竞态不 double-finish。
6. 每条路径最终删除私有 request body 临时文件。

### 15.7 跨 Session 质量报告

至少覆盖：

1. 只聚合 `channel = 'duet'`、`frontend = 'duet'`，忽略合法 completion 记录并拒绝未知来源。
2. 以 session/cycle/event/request ID 去重；同一键内容冲突时完整性失败。
3. 没有 `cycle_started` 的孤立 lifecycle 不能通过完整性门禁。
4. accepted visible 使用 preview 与 accepted 的 cycle 交集，不能超过 visible 数。
5. 统计 accepted、dismissed、stale、unresolved、parse failed、request outcome 和 P50/P95。
6. 100 条唯一 visible 只表示 `ready_for_review`，仍要求人工核对真实编辑 provenance。
7. malformed JSON、未知 schema、非法枚举、读取错误和终态冲突均使完整性失败。
8. 输入路径、源码、prompt、response、provider 私有名称和 raw error 不进入输出。

## 16. 性能要求

扩展 `make benchmark`，记录 Phase 1 同机基线：

- 10,000 次 scheduler `TextChangedI` 同步 callback 的总耗时和单次均值。
- 连续重置 debounce 时的 timer 数量，任何时刻最多一个。
- auto trigger 关闭时的 timer、filesystem、Buffer read 和 request 数均为 0。
- controller 10,000 次 begin/invalidate/finish 的时间和有界状态。
- 1、10、40 changed lines 的 filter + preview 分类耗时。
- 模拟连续输入时 debounce 期间 request 数为 0；停顿后每 generation 最多 1 次。

硬性边界：

- TextChanged 同步路径只做 O(1) 状态更新和 timer reset。
- 无网络、diff、prompt 构造、全 Buffer 读取或磁盘 I/O 出现在同步输入路径。
- scheduler idle 时没有活跃 timer。
- controller 不持有历史 suggestion 或无界 generation 表。
- benchmark 先记录结果，不设置脱离当前机器的武断微秒阈值；明显高于 Phase 0 recorder 量级时必须解释。

## 17. 隐私与安全

### 17.1 自动请求保护

自动 Duet 默认拒绝：

- dotenv、常见 credential basename/extension 和 binary Buffer。
- 非普通 Buffer、不可修改 Buffer。
- 超过 auto max buffer size 的 Buffer。
- 用户 predicate 拒绝的 Buffer。

本阶段不把该 guard 描述为全局 secret 防火墙。用户显式调用手动 Duet、FIM、cmp、Blink 或 LSP frontend 时，仍由用户决定是否把当前 Buffer 发送给 provider。

### 17.2 状态与事件

- controller 只保存 ID、枚举、bufnr、changedtick 和函数引用。
- scheduler 不保存 Buffer text。
- apply state 在建议结束后立即释放。
- 新配置、通知、metrics、User event 和 JSONL 不包含 API key、endpoint header、prompt、response、original/proposed text 或路径。
- 过滤与 apply error 只使用固定分类消息，不打印 provider raw response。

### 17.3 自动测试 fixture

- 只使用短小的虚构源码。
- 使用 fake backend/callback，不读取用户真实 Buffer。
- secret predicate 测试使用 sentinel，不使用真实 key。
- 真实 DeepSeek smoke 继续是显式手动目标，不进入 CI。

## 18. 实施顺序与提交边界

建议按以下顺序实施：

1. `test: define phase 1 controller and apply invariants`
2. `feat: add suggestion ownership controller`
3. `feat(transport): cancel jobs by metrics cycle`
4. `feat: adapt virtual text and duet to suggestion leases`
5. `feat(duet): validate and filter local edits`
6. `feat(duet): add opt-in prediction scheduler`
7. `feat: add tab arbitration API`
8. `test: cover scheduler races, undo, and fallback`
9. `perf: benchmark scheduler and controller hot paths`
10. `docs: document automatic duet and tab fallback`

提交原则：

- 每个行为变化同时带测试。
- controller 接入不能在同一提交顺便改 prompt 或 preview 样式。
- scheduler 接入不能默认打开配置。
- apply 拆分不能改变合法插入、替换、删除的视觉结果。
- 不提交真实 key、raw response、prompt 日志或用户源码。
- 涉及同步编辑事件时运行 benchmark。

## 19. 人工回归清单

使用无敏感内容的临时项目执行：

| # | 场景 | 预期 |
|---:|---|---|
| 1 | auto trigger 默认配置 | 不产生 Duet 请求 |
| 2 | 开启 auto 后连续输入 | 输入期间无请求风暴，停顿后最多一次 |
| 3 | InsertLeave 且存在 edit burst | 触发一次当前光标 Duet |
| 4 | InsertLeave 但没有编辑 | 不触发 |
| 5 | FIM preview 可见 | 自动 Duet 不覆盖 |
| 6 | FIM pending 到 Duet deadline | FIM 取消，只有 Duet 能显示 |
| 7 | Duet pending 时继续输入 | transport 取消胜出时 request 记 `cancelled` 且不虚构 stale；非空 response 已越过取消竞态时记 `stale`；两种分支都不显示 |
| 8 | Duet preview 后继续输入 | preview 立即清理，apply 无效 |
| 9 | Duet 插入/替换/删除 | preview 正确，Tab apply 正确 |
| 10 | 模型 no-op/cursor-only | 不显示 |
| 11 | 模型只改空白 | 不显示 |
| 12 | 模型输出超过 40 changed lines | 不显示 |
| 13 | Tab 无 Minuet 建议 | 原 snippet/completion/indent fallback 正常 |
| 14 | Tab 接受 FIM | 完整插入并延迟调度 Duet |
| 15 | Tab 接受 Duet | 一次应用，光标正确，延迟调度下一次 |
| 16 | 接受后按一次 `u` | 只撤销模型建议 |
| 17 | explicit dismiss | 相同 changedtick 不重复建议 |
| 18 | Buffer 切换 | 原 Buffer 不留可接受 UI，晚到结果无影响 |
| 19 | popup menu/snippet workflow | Minuet 未显示时完全走用户 fallback |
| 20 | dotenv、credential path 或 binary 自动模式 | 不创建 request cycle |
| 21 | `:Minuet stats` | request 与 preview/accept/dismiss/stale 操作一致 |
| 22 | JSONL sentinel | 不含源码、建议、路径或凭据 |

## 20. 验收标准

### 20.1 正确性

- Virtual Text 与 Duet 不会同时成为 visible owner。
- 每个异步 callback 同时受 source identity 与 controller generation 保护。
- dismiss、supersede、Buffer change 后的 late callback 永不重新 render。
- 每次自动 edit generation 最多发一个 Duet cycle。
- no-op、whitespace-only 和过大编辑不会显示。
- apply 前验证 bufnr、generation、changedtick、range 和 original text。
- accepted 只在 Buffer 修改成功后记录。
- 一次 `u` 只撤销 suggestion。
- apply 后 cursor 永远位于合法 row/column。

### 20.2 交互

- 自动 Duet 默认关闭，用户显式开启后才产生请求。
- 插件不创建默认 Tab keymap。
- `tab.accept_or_fallback()` 在无 Minuet 建议时完整保留用户 fallback。
- manual predict/apply/dismiss 继续可用。
- 接受 FIM 或 Duet 后可以自动进入下一次 prediction 调度。
- popup menu、paste、macro 和不安全 Buffer 不触发自动 Duet。

### 20.3 取消与资源

- controller 替换 pending owner 时只取消目标 cycle。
- cancelled request 正确 finish metrics 并清理临时文件。
- scheduler 任意时刻最多一个 timer，idle/disabled 时为零。
- repeated setup、BufWipeout 和退出不泄漏 timer、job、extmark 或 state。

### 20.4 兼容性

- 现有 provider、manual Duet、Virtual Text cycling/line accept、cmp、Blink 和 LSP 测试全部通过。
- controller 仅承诺 Virtual Text 与 Duet 的可见仲裁。
- 自定义 backend 即使不可主动 kill，也不能用晚到 callback 污染 UI。
- 配置新增字段有类型注解、默认值和 README 说明。

### 20.5 隐私与性能

- 新公开事件、JSONL、controller 和 scheduler state 不包含 source/prompt/response/path/key；apply/frontend 仅在建议存活期间保留必要的原文与 proposed text，并在终态立即释放。
- auto trigger 关闭时没有新增 I/O、timer 或请求。
- TextChanged 同步路径没有慢操作。
- `make benchmark` 记录 controller/scheduler/filter 新基线。
- 所有自动测试不访问真实网络。

## 21. 验证命令

实现完成后运行：

```sh
make test
make format-check
make benchmark
git diff --check
```

真实 endpoint 只做显式手动回归：

```sh
read -rsp 'DeepSeek API key: ' DEEPSEEK_API_KEY
export DEEPSEEK_API_KEY
make smoke-deepseek
unset DEEPSEEK_API_KEY
```

Phase 1 smoke 还需要在临时配置中开启 `duet.auto_trigger.enabled = true`，执行第 19 节的连续接受场景。真实请求结果只记录分类计数和聚合延迟，不记录 response、源码或 key。pending Duet 后修改 Buffer 的真实 transport 验证接受两种竞态结果：取消先完成时必须得到 `cancelled` 且没有 suggestion stale；非空结果已到达时必须得到对应 `stale`。任一分支都不得 render preview。

## 22. Phase 1 退出条件

只有全部满足后，Phase 1 才算完成：

1. 第 20 节全部自动验收项通过。
2. 第 19 节人工回归有记录；无法执行的场景明确写出外部阻塞，不能伪造结果。
3. DeepSeek FIM/Duet 手动 smoke 仍通过，自动调度至少完成一次真实连续接受流程。
4. JSONL 与公开 event 再次通过 sentinel/key/path 扫描。
5. scheduler/controller/filter benchmark 已记录。
6. 没有 stale 误应用、错误 Buffer 修改、request storm 或默认意外请求。
7. README 已说明 opt-in、费用、Tab fallback、secret guard 边界和现有 frontend 范围。
8. 实施偏差与遗留问题写入第 23 节。

Phase 1 原退出计划要求先在真实工作流中收集至少 100 次 visible Next Edit 建议，再决定 Phase 2 的 candidate source、分数和阈值。2026-08-03 用户明确要求暂缓该数据门禁并直接继续后续任务；这是一项显式产品风险接受，不等于数据已经收集。Phase 2 只能使用 roadmap 中的保守启发式初值，自动付费请求继续默认关闭，并且不得宣称具备真实接受率、撤销率或候选定位率证据。后续数据仍至少需要报告 preview、accepted、dismissed、stale、parse failed 和 P50/P95，不得包含源码或 prompt。

跨 Neovim session 的收集必须使用一个不混入测试或 smoke 数据的专用 JSONL 文件。`:Minuet report` 默认读取已配置的 `metrics.jsonl.path`，也接受显式 path/glob；它会去重并检查 schema、cycle 起点、冲突终态和非法枚举。`ready_for_review` 仅证明计数与结构完整，无法从 JSONL 推断真实工作流来源，因此进入 Phase 2 前仍须人工核对 cohort provenance。

## 23. 实施记录

本节在代码完成过程中持续更新，不另建完成报告。以下结果来自 2026-08-03 当前工作树；未实际执行的项目保持为待执行，不以自动测试结果代替真实请求或人工 UI 检查。

| 项目 | 结果 |
|---|---|
| 实施状态 | Phase 1 退出条件全部满足；在 100 条真实 visible 数据门禁完成前不得开始 Phase 2 |
| 开始日期 | 2026-08-03 |
| 完成日期 | 2026-08-03 |
| 相关 commits | 未创建；按实施目标保留现有 dirty worktree，未 stage 或 commit |
| `make test` | 通过：151/151；测试中的三次 User autocmd error 为 metrics 隔离错误的预期 fixture，未导致失败 |
| `make format-check` | 通过：StyLua 2.5.2 检查 `lua/` 与 `tests/` |
| `make benchmark` | 通过；Phase 1 同机结果见下表 |
| DeepSeek continuous smoke | 通过：2 次 FIM 均成功并产生 preview（1 accept、1 dismiss），P50/P95 790.39/805.39 ms；3 次手动 Duet 加 2 次自动 Duet 共 5 次请求，产生 3 次 preview、2 accept、1 dismiss，P50/P95 1038.04/1240.55 ms；接受自动建议后成功启动 follow-up 请求；pending 请求在编辑后由真实 transport 取消，outcome=`cancelled`、无非空结果、无 stale、无 preview |
| 真实 smoke 隐私扫描 | 通过：51 条临时 JSONL record 与 31 个公开 lifecycle payload 均不含 API key、源码 sentinel、fake key 或临时 Buffer path；临时目录在脚本退出时删除 |
| 100 visible 数据门禁 | 已运行隐私保护的离线报告：标准 metrics 位置匹配 0 个文件、0 个 session、0 条 visible；2026-08-03 用户明确要求暂缓该门禁并继续 Phase 2，未用测试或合成数据代替，也不据此声称质量达标 |
| 人工回归 | 通过：在无网络、无敏感内容的临时 TUI session 中逐项执行第 19 节 22 个场景；session 与临时 JSONL 已删除，结果见 23.2 |
| 与本文偏差 | controller 新增内部 `release()`，用于 empty/parse-failed/filtered 结果无 lifecycle 地释放 lease；scheduler 新增仅供测试与 benchmark 使用的 `_inspect()`；新增组合 integration/config/init/transport specs 以覆盖跨模块竞态；为可验证 Phase 2 前置数据门禁，新增隐私保护的跨 session 离线报告与 `:Minuet report`，但不把结构完整误称为真实数据 provenance；首次真实 smoke 把“取消先完成且无结果”错误地强制解释为 stale，现已按 Phase 0 口径修正规格与脚本：空结果只记 request cancelled，只有非空晚到结果才记 suggestion stale |
| 遗留问题 | Phase 1 无未完成退出项；100 次真实 visible Next Edit 数据仍为 0/100，并由用户明确延期。该缺口必须保留到后续质量记录，不能用 Phase 2 自动测试替代 |

### 23.1 Phase 1 同机 benchmark

环境：AMD Ryzen 7 9700X、16 logical CPUs、x86_64、Neovim 0.12.4、LuaJIT 2.1、StyLua 2.5.2。

| 路径 | 2026-08-03 结果 |
|---|---:|
| controller 10,000 次 begin/visible/terminal | 0.77 ms 总计，0.08 us/cycle，饱和后 Lua heap 增长 3.33 KB，active owner 为 0 |
| scheduler 10,000 次 `TextChangedI` callback | 17.37 ms 总计，1.74 us/event，debounce 中 1 个 timer、0 个 request |
| 模拟连续输入 | debounce 中 0 request，停顿后 1 request |
| auto trigger 关闭 | 0 timer、0 filesystem call、0 Buffer read、0 request |
| 1 changed line filter + preview | 0.008 ms |
| 10 changed lines filter + preview | 0.052 ms |
| 40 changed lines filter + preview | 0.889 ms |
| metrics 10,000 cycles / 70,000 updates | 88.42 ms 总计，8.84 us/cycle，1.26 us/update |

### 23.2 人工回归进度

执行日期：2026-08-03。环境为真实 Neovim TUI、临时普通 Buffer 和延迟 fake FIM/Duet provider；不访问网络，不使用 API key。异步 callback 仍经过真实 scheduler、controller、preview、Tab、apply 与 metrics 路径。真实 provider 行为由单独的 DeepSeek smoke 验证，不能由本表替代。

| # | 结果 | 观察记录 |
|---:|---|---|
| 1 | 通过 | 默认关闭时实际编辑并离开 Insert mode，Duet request/cycle 均为 0 |
| 2 | 通过 | opt-in 后停顿显示一次 Duet preview；连续输入 request-storm 断言同时由 benchmark 与 scheduler test 验证 |
| 3 | 通过 | dirty burst 后 `InsertLeave` 请求增量为 1，并显示当前光标 Duet preview |
| 4 | 通过 | clean generation 的 `InsertLeave` 请求增量为 0 |
| 5 | 通过 | FIM visible 时手动安排 scheduler deadline，请求增量为 0；FIM 保持可接受 |
| 6 | 通过 | pending FIM 后继续输入：FIM 与 Duet 各启动 1 次，late FIM 不显示，只有 Duet preview 出现 |
| 7 | 通过 | pending Duet 后继续输入：preview 为 false，stale 增量为 1 |
| 8 | 通过 | Duet preview 后继续输入，preview 立即清除，随后 apply 返回 false |
| 9 | 通过 | 观察插入、替换和删除 preview；统一 Tab 成功应用替换，cursor 保持合法 |
| 10 | 通过 | unchanged text 加 cursor-only marker 不显示 preview |
| 11 | 通过 | whitespace-only response 不显示 preview |
| 12 | 通过 | 41 changed lines response 不显示 preview |
| 13 | 通过 | 无 Minuet suggestion 时表达式映射执行原始 Tab fallback |
| 14 | 通过 | 统一 Tab 接受 FIM，inline text 完整插入；自动测试同时确认只调度一次后续 Duet |
| 15 | 通过 | 统一 Tab 接受 Duet 后 Buffer 只修改一次，follow-up request 增量为 1，follow-up no-op 静默释放 |
| 16 | 通过 | 第一次 `u` 只撤销 suggestion，第二次 `u` 才撤销 suggestion 前的编辑状态 |
| 17 | 通过 | explicit dismiss 后相同 changedtick 请求增量为 0，新编辑后请求增量为 1 |
| 18 | 通过 | pending request 时切换 Buffer，late callback 后 owner 为 none，当前 Buffer 无 preview |
| 19 | 通过 | 实际 `Ctrl-N` popup 显示时 `pumvisible() = 1`，Duet 请求增量为 0；无 suggestion 时 fallback 仍工作 |
| 20 | 通过 | dotenv、binary 和 oversized Buffer 的自动请求增量分别均为 0 |
| 21 | 通过 | `:Minuet stats` 的 preview/accepted/dismissed/stale 与本次 TUI 操作一致，并显示 frontend coverage 边界 |
| 22 | 通过 | 临时 JSONL 共 3 条 allowlisted lifecycle 记录；虚构 source sentinel 与 Buffer path 扫描均为 false，文件随后删除 |

实施中如果发现以下假设不成立，先更新本文再继续改代码：

- targeted cycle cancellation 无法覆盖某个内置 transport。
- 单次 Buffer API 修改不能形成独立 undo 单元。
- FIM prefix-consume 与全局 controller 无法在不改变现有体验的情况下协调。
- DeepSeek marker/no-op 遵循率不足以支撑自动触发。
- 900/1500ms 默认 debounce/throttle 在真实工作流中造成明显 request storm 或响应过晚。

最终决策优先级保持：

```text
安全性 > 不打扰 > 延迟 > 接受率 > 功能覆盖范围
```
