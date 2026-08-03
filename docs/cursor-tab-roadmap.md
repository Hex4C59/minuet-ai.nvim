# Minuet Cursor Tab 风格改造计划

## 1. 文档目的

本文定义基于当前 `minuet-ai.nvim` fork 实现 Cursor Tab 风格代码预测的工程计划。

目标不是逐像素复刻 Cursor，也不是让模型自动重构整个仓库，而是在 Neovim 中实现一条稳定、低干扰、可验证的连续编辑工作流：

1. 在当前光标处提供低延迟 FIM 补全。
2. 根据最近编辑预测当前 Buffer 的下一处局部修改。
3. 用同一个 Tab 交互接受建议或跳转到建议位置。
4. 在可靠性达到门槛后，再扩展到少量相关文件中的单处编辑。

本文以仓库当前 `main` 分支为基线。当前代码已经包含实验性的 `Duet` 下一次编辑预测，因此改造应优先复用已有实现，而不是另起一套平行系统。

---

## 2. 产品目标

### 2.1 目标体验

用户修改代码后，插件应在合适的时机执行以下一种行为：

- 在当前光标处显示行内插入建议。
- 在当前 Buffer 的附近位置显示插入、删除或替换预览。
- 提示存在另一处高置信度编辑，按 Tab 跳转到目标位置并显示预览。
- 接受一项建议后，继续预测下一项编辑，形成连续的 Tab 工作流。

第一版的理想交互：

```text
用户输入
  -> 停顿
  -> 显示当前位置 FIM 或当前 Buffer 下一编辑
  -> Tab 接受
  -> 自动请求下一项建议
  -> Tab 继续接受或跳转
```

### 2.2 “80% Cursor Tab 体验”的工作定义

这里的 80% 指常用局部编辑体验，不指 Cursor 内部模型质量、服务端基础设施或全语言覆盖率。

计划覆盖：

- 当前行和多行插入。
- 当前 Buffer 内的小范围替换与删除。
- 根据最近修改更新相邻代码或调用点。
- 根据 LSP diagnostics 和 references 选择下一编辑位置。
- 少量相关文件中的单处、用户确认式编辑。
- 低延迟预览、Tab 接受、一次 `u` 撤销。

暂不承诺：

- 任意大型仓库的全局语义理解。
- 一次生成并自动应用多文件补丁。
- 无确认的大范围重构。
- 对所有语言和 LSP 实现保持相同质量。
- 与 Cursor 相同的专有模型、训练数据和服务端延迟。

### 2.3 安全边界

- 默认一次只建议一个编辑目标。
- 所有修改必须由用户明确接受。
- 接受前必须验证 Buffer 版本和原始文本。
- 过期、歧义或越界建议必须丢弃，不能尝试“猜着应用”。
- 第一阶段只允许修改当前 Buffer。
- 跨文件阶段默认只允许已加载、可修改且未发生冲突的 Buffer。
- `.env`、凭据文件、二进制文件和超大 Buffer 默认不进入上下文或编辑历史。

---

## 3. 当前基线

### 3.1 已有能力

当前仓库已经具备以下可复用模块：

| 能力 | 当前实现 |
|---|---|
| 当前光标 FIM/聊天补全 | `lua/minuet/virtualtext.lua` 与 `lua/minuet/backends/` |
| 下一次编辑预测 | `lua/minuet/duet/init.lua` |
| 当前 Buffer 上下文切分 | `lua/minuet/duet/context.lua` |
| 最近编辑历史 | `lua/minuet/duet/edits.lua` |
| Chat provider | `lua/minuet/duet/backends/` |
| 结构化输出协议 | `<editable_region>` 与 `<cursor_position/>` markers |
| 插入、删除、替换预览 | `lua/minuet/duet/preview.lua` |
| 结果解析与边界过滤 | `lua/minuet/duet/utils.lua` |
| 过期结果检查 | `changedtick` 与 `request_seq` |
| 测试基础 | `tests/duet_*_spec.lua` |

当前 Duet 已经不是普通 FIM。它会：

1. 选取光标前后固定行数作为可编辑区域。
2. 将其余当前 Buffer 内容作为不可编辑上下文。
3. 附加最近编辑的 unified diff。
4. 让聊天模型重写可编辑区域并返回目标光标位置。
5. 对原区域和建议区域计算 diff，再通过 extmark 展示。
6. 在应用前检查 `changedtick`，避免应用过期结果。

### 3.2 当前主要缺口

| 缺口 | 影响 |
|---|---|
| Duet 只能手动 `predict()` | 无法形成自然的连续 Tab 工作流 |
| 可编辑区域总是围绕当前光标 | 无法主动预测同文件中的下一处位置 |
| 没有候选位置发现与排序 | 模型必须在固定局部范围内工作 |
| 没有 LSP diagnostics/references 上下文 | 函数签名变更、类型错误等场景利用不足 |
| 没有 import/require 和相关 Buffer 上下文 | 项目级 API 推断较弱 |
| FIM 与 Duet 状态相互独立 | 可能同时请求、同时显示、争用快捷键 |
| 没有统一 Tab 仲裁 | 与 Blink、snippet、缩进和 Duet 的优先级不明确 |
| Duet 仅有单一局部区域结果模型 | 尚不能表达“先跳转，再确认编辑” |
| 没有质量遥测 | 无法用接受率、撤销率和延迟指导调优 |
| 请求取消仅局限于各自 backend | FIM 与 Duet 之间缺少统一代次和资源调度 |

### 3.3 不应重写的部分

以下模块已经提供了正确基础，除非测试暴露具体问题，不应在第一阶段重写：

- HTTP transport 与 provider transform。
- 最近编辑的 snapshot/diff 记录器。
- Duet marker 协议和严格解析。
- 基于 `vim.text.diff`/`vim.diff` 的 diff 预览。
- `changedtick` 过期检查。
- 现有 FIM、cmp、Blink 和 LSP frontend。

---

## 4. 总体架构

### 4.1 双通道模型

使用同一个 DeepSeek API Key，但按任务选择不同接口：

```text
Inline FIM
  endpoint: /beta/completions
  input: prompt + suffix
  purpose: 当前光标处快速插入

Next Edit
  endpoint: /chat/completions
  input: messages + 结构化编辑上下文
  purpose: 插入、替换、删除和下一位置预测
```

推荐配置方向：

```lua
provider = 'openai_fim_compatible'

duet = {
    provider = 'openai_compatible',
    provider_options = {
        openai_compatible = {
            model = 'deepseek-v4-flash',
            end_point = 'https://api.deepseek.com/chat/completions',
            api_key = deepseek_api_key,
            name = 'DeepSeek',
        },
    },
}
```

接口和模型名称必须通过真实 API 请求验证。不要仅依据配置可写入就假设服务端兼容所有字段。

### 4.2 分层数据流

```text
Neovim events
  -> edit history
  -> trigger policy
  -> candidate discovery
  -> context ranking and budgeting
  -> FIM or Next Edit provider
  -> response parser
  -> validation
  -> suggestion controller
  -> inline/diff/jump preview
  -> Tab apply
  -> feedback and next prediction
```

### 4.3 建议统一模型

FIM 与 Duet 最终都应交给统一控制器，而不是各自独立占有 UI 和按键状态。

建议内部数据结构：

```lua
---@class minuet.SuggestionAnchor
---@field bufnr integer
---@field changedtick integer
---@field start_row integer
---@field start_col integer
---@field end_row integer
---@field end_col integer
---@field original_text string

---@class minuet.SuggestionEdit
---@field new_text string
---@field cursor_row integer
---@field cursor_col integer

---@class minuet.Suggestion
---@field id integer
---@field kind 'inline'|'local_edit'|'remote_edit'
---@field source 'fim'|'duet'
---@field state 'pending'|'visible'|'stale'|'accepted'|'dismissed'
---@field anchor minuet.SuggestionAnchor
---@field edit minuet.SuggestionEdit
---@field score number?
---@field reason string?
---@field created_at integer
```

第一阶段不必立即迁移所有旧代码。可先由适配器将现有 FIM 字符串和 Duet range 转换为该结构，再逐步让 renderer 和 apply 直接消费统一模型。

### 4.4 模块规划

保留现有 `duet` 名称，避免大规模破坏 API。新增模块只对应真实职责：

```text
lua/minuet/
├── suggestion.lua              # 统一建议状态、验证和生命周期
├── tab.lua                     # Tab 仲裁和 fallback
└── duet/
    ├── init.lua                # 对外 action 与协调
    ├── scheduler.lua           # 自动触发、debounce、throttle、取消
    ├── candidates.lua          # 候选编辑位置发现与排序
    ├── context.lua             # 上下文预算与 prompt context
    ├── edits.lua               # 现有最近编辑记录器
    ├── preview.lua             # inline/diff/jump 预览
    ├── apply.lua               # 验证、应用、光标移动、undo
    ├── feedback.lua            # 本地指标和调试事件
    └── backends/
```

不要为了目录整齐一次性拆分 `duet/init.lua`。每个新模块应在对应阶段出现，且必须有独立测试价值。

---

## 5. 核心子系统设计

### 5.1 触发策略

FIM 和 Next Edit 不应在每次按键后同时请求。

建议规则：

| 场景 | 动作 |
|---|---|
| 插入模式连续输入 | 只调度 FIM |
| 停顿 150-300ms | 可发 FIM |
| 停顿 700-1200ms 且存在有效编辑 burst | 可发 Duet |
| `InsertLeave` | 刷新编辑历史，可调度 Duet |
| 接受 FIM 后 | 延迟调度 Duet，寻找下一项编辑 |
| 接受 Duet 后 | 延迟调度下一次 Duet |
| LSP diagnostics 更新 | 仅标记候选脏，不立即请求 |
| Buffer 或光标发生不兼容变化 | 取消/作废当前建议 |

请求优先级：

```text
可见且可接受的建议
  > 正在进行的 Duet 请求
  > 当前光标 FIM 请求
  > 预取请求
```

抑制条件：

- completion menu 可见且配置不允许并存。
- snippet 正在等待 Tab 跳转。
- macro 正在录制或执行。
- paste mode、生效中的 operator、命令行窗口或不可修改 Buffer。
- Buffer 超过限制、文件类型在 denylist、路径命中 secret guard。
- 最近一次编辑仅为空白移动，且没有 diagnostics 或相关候选。
- 用户刚 dismiss，且上下文没有发生有意义变化。

### 5.2 候选位置发现

不要让模型在整个仓库中自由猜位置。Neovim 先产生少量候选，再让模型重写最佳区域。

候选来源按阶段引入：

1. 当前光标附近区域。
2. 最近编辑 hunk 附近。
3. 当前 Buffer 的 LSP diagnostics。
4. 最近被修改符号的 LSP references。
5. 当前 Buffer 中相同标识符的文本匹配。
6. import/require 指向的已加载 Buffer。
7. 最近访问且属于同一 workspace 的 Buffer。

候选结构：

```lua
---@class minuet.DuetCandidate
---@field bufnr integer
---@field row integer
---@field col integer
---@field source 'cursor'|'recent_edit'|'diagnostic'|'reference'|'text'|'related_buffer'
---@field score number
---@field metadata table
```

初始启发式评分建议：

```text
当前光标附近                         +100
最新 edit hunk 附近                  +90
error diagnostic                    +80
warning diagnostic                  +60
被修改符号的同文件 reference          +75
同 workspace 已加载 Buffer reference +55
最近访问 Buffer                     +20
距离光标越远                         逐步扣分
候选位于未修改/不可写 Buffer           直接淘汰
```

MVP 每次只把排名第一的候选交给模型。后续可以将前三个候选的位置摘要交给模型做选择，但不要一开始就允许模型返回任意路径和行号。

### 5.3 上下文收集与预算

每次 Next Edit 请求建议包含：

```text
文件路径和 filetype
候选位置附近的可编辑区域
候选 Buffer 的非编辑上下文
最近编辑 history
相关 diagnostics
最近修改符号的定义/引用摘要
少量相关文件片段
```

建议预算比例：

| 内容 | 初始预算 |
|---|---:|
| 可编辑区域 | 不截断，最大 40 行 |
| 当前 Buffer 邻近上下文 | 40% |
| 最近编辑 | 25% |
| diagnostics 与 symbol 信息 | 10% |
| 相关文件片段 | 25% |

上下文应以字符预算实现，后续有稳定 tokenizer 时再切换为 token 预算。

必须加入：

- workspace-relative path，而不是临时文件路径。
- filetype 和注释/缩进风格。
- 每个附加片段的来源标签。
- “不可编辑上下文”与“可编辑区域”的明确边界。

禁止默认加入：

- 整个仓库。
- 任意未引用的大文件。
- `.env`、密钥、证书和常见凭据路径。
- 终端 Buffer、帮助 Buffer、插件 UI Buffer。

### 5.4 Prompt 与响应协议

短期继续使用现有 marker 协议：

```text
<editable_region>
...rewritten text...
<cursor_position/>
</editable_region>
```

原因：

- 当前 parser 已严格验证 marker 数量。
- 可以保留原样文本、空行和缩进。
- 对 OpenAI-compatible 流式文本响应要求较低。
- 比要求模型生成绝对行号更稳定。

Prompt 需要补强：

1. 明确这是“预测最可能的下一次编辑”，不是通用重构。
2. 允许返回原区域不变，代表不应建议编辑。
3. 强制最小修改，不得顺手格式化无关代码。
4. recent edits 从旧到新，最新权重最高。
5. diagnostics 只是证据，不要求机械修复全部诊断。
6. 不得输出不在 editable region 中的文件或代码。
7. 输出必须且只能有一个 editable region 和一个 cursor marker。

中期可实验结构化 JSON，但只有满足以下条件才迁移：

- DeepSeek 对 schema 的遵循率明显高于 marker 协议。
- 流式解析不增加可见延迟。
- 空白和多行文本能无损表达。
- 至少 500 次请求中的解析失败率低于 1%。

### 5.5 统一 Tab 仲裁

Tab 不能无条件被插件吞掉。建议优先级：

```text
1. Duet 当前目标位置已有可见编辑 -> 应用编辑
2. Duet 建议位于其他位置 -> 跳转并展示/聚焦编辑
3. FIM 虚拟文本可见 -> 接受完整 FIM
4. snippet 可以向前跳 -> snippet jump
5. Blink/cmp 菜单可见 -> 保持现有 completion 行为
6. 原始 Tab -> 缩进或插入制表符
```

需要提供一个表达式映射或回调 API，而不是插件安装时强制覆盖 `<Tab>`：

```lua
local tab = require 'minuet.tab'

vim.keymap.set('i', '<Tab>', function()
    return tab.accept_or_fallback()
end, { expr = true })
```

实际实现必须兼容函数式 fallback，避免要求用户拼接不可读的 termcode 字符串。

建议保留显式动作作为调试和无 Tab 用户的后备：

```text
Minuet duet predict
Minuet duet apply
Minuet duet dismiss
Minuet virtualtext accept
```

### 5.6 预览与跳转

预览分三类：

| 类型 | 展示方式 |
|---|---|
| 当前光标纯插入 | 现有 inline virtual text |
| 当前视口内替换/删除 | 现有 `DiffAdd`/`DiffDelete` extmark |
| 当前 Buffer 其他位置 | 当前行显示轻量 jump hint，目标处放 sign/extmark |

远端候选的交互采用两步而不是盲应用：

1. 第一次 Tab 跳转到目标并显示完整 diff。
2. 第二次 Tab 应用编辑。

可提供配置允许高置信度同屏候选一次 Tab 应用，但默认保持两步确认。

跨 Buffer 候选：

- 跳转前保存原窗口和 jumplist 语义。
- 使用普通 Buffer 打开流程，不使用临时 preview Buffer 应用修改。
- 目标 Buffer 有未保存冲突时仅预览，不自动覆盖。
- 用户返回原位置应能使用 `<C-o>` 或插件 dismiss action。

### 5.7 验证与应用

应用前至少验证：

1. `bufnr` 仍有效且可修改。
2. 建议属于当前 controller generation。
3. 当前 `changedtick` 等于请求时版本，或目标锚点文本仍然完全匹配。
4. range 未越界。
5. 原始文本与 `original_text` 完全一致。
6. 新文本大小和修改行数未超过配置限制。

如果 `changedtick` 变化但目标区域未变，后续可以允许基于 extmark 重定位；第一版直接判 stale 更安全。

应用要求：

- 使用 `nvim_buf_set_text()` 或 `nvim_buf_set_lines()`，不模拟键盘输入。
- 单项建议必须形成一个可预测的 undo 单元。
- 设置光标前先 clamp row/column。
- 应用后清理 extmark、请求状态和旧候选。
- 记录 accepted 事件，再调度下一次预测。

### 5.8 建议抑制与质量门

模型返回结果不等于必须展示。

第一版规则：

- 建议与原文完全相同则静默丢弃。
- 只改变行尾空格或无意义格式时丢弃。
- 超过最大修改行数时丢弃。
- 解析失败或 marker 异常时丢弃。
- 目标区域已经变化时丢弃。
- 纯删除且范围较大时要求更高置信度或不展示。
- 同一上下文中用户 dismiss 后，不重复展示相同文本 hash。

后续评分信号：

- 候选来源分数。
- 最近 edit 与目标文本的标识符重叠。
- 目标处 diagnostic 严重度。
- 模型是否保持大部分原区域不变。
- 建议大小。
- 相同模式的历史接受率。

---

## 6. 分阶段实施计划

### 文档维护方式

采用“一个长期 roadmap + 一个当前里程碑实施规格”的方式：

- 本文只维护总体目标、阶段边界、依赖顺序和最终质量门。
- `docs/cursor-tab/NN-*.md` 每篇覆盖一个可独立验收的里程碑，而不是一个函数、一个任务或一个 commit。
- 下一篇实施规格在上一阶段达到退出条件后再写，避免过早设计被真实数据推翻。
- 每篇规格同时包含目标、非目标、接口决策、改动范围、测试、验收和实施记录；不再拆出平行的设计稿、测试计划和完成报告。
- 实施中发现偏差时先更新当前规格，并在文末记录原因；已经由代码和测试清楚表达的细节不重复抄进文档。

这种方式保留逐步决策的上下文，又避免大量小文档失去同步。

### Phase 0：建立可测基线

目标：先把当前 Duet 和 FIM 的行为量化，避免无指标魔改。

实施规格：[`cursor-tab/00-observability-baseline.md`](cursor-tab/00-observability-baseline.md)

任务：

- 增加 request started/finished、preview shown、accepted、dismissed、stale、parse failed 事件。
- 记录内存级延迟与计数；默认不落盘。
- 增加可选 JSONL 本地日志，默认关闭，并过滤 prompt、源码和 API key。
- 增加 `:Minuet stats` 或 Lua API 输出会话统计。
- 为当前 DeepSeek FIM 和 Chat endpoint 增加手动 smoke test 文档。
- 建立 10-20 个真实编辑场景的人工回归清单。

验收：

- 不改变现有默认行为。
- 所有现有测试通过。
- 能看到 FIM/Duet 的请求延迟、展示数、接受数和过期数。
- 日志中不包含源代码、prompt 或凭据。

### Phase 1：将现有 Duet 产品化为当前 Buffer Next Edit

目标：不做候选跳转，先让光标附近的 Duet 自动、稳定、可连续使用。

实施规格：[`cursor-tab/01-current-buffer-next-edit.md`](cursor-tab/01-current-buffer-next-edit.md)

任务：

- 新增 `duet.scheduler`，支持 debounce、throttle、generation 和取消。
- 在 `InsertLeave`、输入停顿、接受 FIM/Duet 后调度预测。
- FIM 与 Duet 请求互斥或按优先级取消。
- 实现统一 suggestion controller。
- 实现 Tab 仲裁 API，不默认覆盖用户键位。
- 将 Duet apply 抽到独立验证路径，并确保一次 `u` 可撤销。
- 增加 no-op、超大编辑、纯空白修改过滤。
- DeepSeek Chat 作为 `openai_compatible` Duet provider 的示例配置。

范围限制：

- 仅当前 Buffer。
- 可编辑区域仍围绕当前光标。
- 一次只请求和展示一条 Duet 建议。
- 最大编辑 40 行，默认建议保持现有 8 行前、15 行后。

验收：

- 连续输入时不出现请求风暴。
- 新请求使旧结果失效，旧结果不能重新显示。
- 可见 FIM 与 Duet 不会同时争用 Tab。
- 应用建议后光标位置正确。
- Buffer 变化后建议必定失效。
- 当前测试之外，新增 scheduler、controller、Tab 和 stale race 测试。

### Phase 2：同 Buffer 候选位置与跳转（已完成）

目标：从“重写光标附近”升级为“预测当前 Buffer 的下一处编辑”。

实施规格：[`cursor-tab/02-same-buffer-candidates.md`](cursor-tab/02-same-buffer-candidates.md)

实施结果：164/164 自动测试、完整格式与 benchmark、实际 PTY screen-cell 回归通过；候选扫描 1,000 次的 P95 为 1.547 ms。详细证据和已知风险见实施规格第 21 节。

数据门禁偏差：2026-08-03 用户明确要求暂缓 Phase 1 后的 100 条真实 visible 数据收集并继续后续任务。Phase 2 因此使用本文原始启发式作为保守初值；不得把该决定写成已具备真实接受率证据，自动付费请求继续默认关闭，评分与阈值在 Phase 5 真实数据门禁前都只视为 provisional。

任务：

- 新增 `duet.candidates`。
- 候选来源先实现：当前光标、最近 edit hunk、diagnostics。
- 为候选建立启发式评分和去重。
- `context.build()` 接受显式候选位置，而不是总读当前窗口光标。
- suggestion 支持目标 row/column 与 jump 状态。
- 预览支持目标 sign/extmark 和当前行 jump hint。
- 实现两步 Tab：跳转、应用。
- 跳转后验证目标版本与原始文本。

验收：

- 修改函数签名后，可将同文件 diagnostic 或最近相关位置排到前列。
- 远处建议不会在第一次 Tab 时直接修改代码。
- 跳转后第二次 Tab 可应用，`u` 可撤销。
- 候选消失或 Buffer 变化时不留下 extmark。
- 无 LSP 客户端时优雅退化到当前光标和 recent edit 候选。

### Phase 3：符号感知与相关上下文（已完成）

目标：提高同文件预测质量，并为有限跨文件预测准备上下文层。

实施规格：[`cursor-tab/03-symbol-context.md`](cursor-tab/03-symbol-context.md)

实施结果：175/175 自动测试、格式、benchmark、隐私扫描和实际 PTY 回归通过；10k 行 × 8 identifiers 的文本扫描 P95 为 0.471 ms。详细证据与限制见实施规格第 19 节。

数据门禁偏差继续沿用 Phase 2 的用户决策；本阶段 reference/text 分数、LSP deadline 与 context budget 均为 provisional，不构成真实定位率提升证据。

任务：

- 从最近 edit 提取可能改变的标识符。
- 使用 LSP document symbols、definition 和 references 获取候选。
- 对 LSP 请求设置严格超时和缓存，不阻塞 UI。
- 收集 workspace-relative path、filetype、diagnostics 摘要。
- 收集 import/require 直接相关的已加载 Buffer 片段。
- 实现统一字符预算、来源标签和 secret/path guards。
- Prompt 加入候选来源和最近编辑意图，但仍只允许模型改一个 editable region。

验收：

- 函数签名、字段名和类型变更场景的候选定位率提升。
- LSP 超时不阻塞 FIM 或编辑输入。
- 上下文预算始终受配置上限约束。
- 测试能证明敏感路径不进入 context。
- 相同 Buffer/version 的 LSP 上下文可复用，变化后正确失效。

### Phase 4：有限跨 Buffer Next Edit（已完成）

目标：支持同 workspace 中一个相关 Buffer 的单处建议。

实施规格：[`cursor-tab/04-cross-buffer-next-edit.md`](cursor-tab/04-cross-buffer-next-edit.md)

安全默认：只有 `scope='workspace'` 与 `candidates.related_buffers=true` 同时配置才启用；真实 cohort 仍延期，跨 Buffer 分数与发布质量保持 provisional。

实施结果：184/184 自动测试、格式、benchmark、diff、隐私扫描及 80x24/120x40 实际 PTY 回归通过。跨 Buffer 候选 benchmark（32 个已加载 Buffer、64 个 reference）P50 为 0.404 ms、P95 为 1.013 ms；关闭路径不枚举 Buffer。跳转使用 `:hide buffer` 保留 `nohidden` 下未保存 origin，并保有 jumplist/单 undo 语义。详细证据和延期的数据风险见实施规格第 16 节。

任务：

- 候选扩展到 LSP references 指向的已加载 Buffer。
- suggestion anchor 加入目标 Buffer 和 workspace identity。
- 实现跨 Buffer jump preview。
- 接受前验证目标 Buffer 的 `changedtick` 和 original text。
- 处理目标 Buffer 未显示、已修改、只读或卸载状态。
- 保证每次建议仍只修改一个 Buffer、一个 range。
- 提供跨 Buffer 功能开关，默认先关闭。

验收：

- 修改定义后，可以建议一个相关调用点。
- 不会静默覆盖目标 Buffer 中的并发修改。
- 目标 Buffer 无效时安全丢弃。
- 跨 Buffer 跳转进入 jumplist，用户可以自然返回。
- 关闭跨 Buffer 功能时不产生额外 LSP/reference 成本。

### Phase 5：质量调优与受控发布（工程完成，发布门禁待真实数据）

目标：决定是否达到可日常使用水平，而不是无限增加功能。

实施规格：[`cursor-tab/05-quality-controlled-release.md`](cursor-tab/05-quality-controlled-release.md)

当前状态：工程实现、194/194 自动测试、格式、benchmark、diff、隐私扫描及四组实际 PTY 回归均通过。真实日志位置仍为 0 个文件、0 个 session、0/500 visible，`ready_for_release_review=false`；按用户决定先完成工程任务，发布门禁没有用测试或合成数据替代。

实施结果：增加有界 SHA-256 同上下文重复抑制、accepted undo feedback、声明式 filetype debounce/throttle、allowlisted filtered/reverted 指标、500-visible release-review gate 和独立 cohort compare。10,000 次 repeat fingerprint 为 40.19 us/check且只保留 128 条，10,000 次空闲 feedback 为 1.65 us/event且不读取 Buffer。automatic Duet 与跨 Buffer 继续默认关闭；FIM P50、真实 cohort provenance、stale 误应用和错误 Buffer 修改仍需发布前人工验证。详细证据见实施规格第 11 节。

任务：

- 收集不少于 500 次建议的匿名本地指标。
- 分析接受率、立即撤销率、dismiss 率、no-op 率和延迟。
- 对候选评分、自动触发时机、prompt 和预算做离线对比。
- 加入同上下文重复建议抑制。
- 根据 filetype 提供不同的触发阈值，而不是不同代码分支。
- 编写用户配置、故障排查和隐私文档。
- 只有达到质量门槛后才考虑默认启用自动 Duet 或跨 Buffer。

建议发布门槛：

| 指标 | 目标 |
|---|---:|
| FIM 首条建议 P50 | < 700ms |
| Next Edit 预览 P50 | < 1500ms |
| Next Edit 预览 P95 | < 4000ms |
| 可见建议接受率 | >= 25% |
| 接受后 10 秒内撤销率 | < 10% |
| 解析失败率 | < 2% |
| stale 建议误应用 | 0 |
| 越界/错误 Buffer 修改 | 0 |
| idle CPU 增量 | 接近 0 |

---

## 7. 配置草案

以下只是目标 API 草案，不应在一个提交中一次性实现：

```lua
require('minuet').setup {
    provider = 'openai_fim_compatible',
    n_completions = 1,

    virtualtext = {
        auto_trigger_ft = { '*' },
    },

    duet = {
        enabled = true,
        provider = 'openai_compatible',
        auto_trigger = {
            enabled = true,
            debounce = 900,
            throttle = 1500,
            on_insert_leave = true,
            after_accept = true,
        },
        scope = 'buffer', -- 'cursor' | 'buffer' | 'workspace'
        max_edit_lines = 40,
        jump_requires_confirmation = true,
        candidates = {
            cursor = true,
            recent_edits = true,
            diagnostics = true,
            references = true,
            related_buffers = false,
            max_candidates = 8,
        },
        context = {
            max_chars = 48000,
            related_files_max_chars = 12000,
        },
        provider_options = {
            openai_compatible = {
                model = 'deepseek-v4-flash',
                end_point = 'https://api.deepseek.com/chat/completions',
                api_key = deepseek_api_key,
                name = 'DeepSeek',
                optional = {
                    temperature = 0.2,
                    max_tokens = 2048,
                },
            },
        },
    },
}
```

设计原则：

- 新功能默认保守，跨 Buffer 默认关闭。
- 保留现有 `duet.action.predict/apply/dismiss` API。
- 配置迁移不引入无必要的兼容层；真正发布过的字段才需要迁移说明。
- 不把用户 API key 存入插件状态、事件或日志。

---

## 8. 测试计划

### 8.1 单元测试

需要覆盖：

- scheduler 的 debounce、throttle、取消和 generation。
- FIM 与 Duet 的优先级仲裁。
- candidate 评分、去重和稳定排序。
- context 字符预算和敏感路径过滤。
- marker/JSON 解析失败。
- no-op、纯空白和超大编辑过滤。
- changedtick、original text 和 range 验证。
- Tab fallback 的每个优先级分支。
- 跨 Buffer anchor 验证。
- 接受、dismiss、stale 和 undo 事件。

### 8.2 Transport 测试

使用本地 fixture 或现有 data URL 风格测试：

- OpenAI-compatible SSE 正常响应。
- 部分流、超时、空响应和 malformed chunk。
- 请求取消后晚到 callback 不更新 UI。
- API 401、429、500 的通知和退避。
- DeepSeek Chat 响应中 marker 被分割到多个 chunk。

测试不得依赖真实 API key。

### 8.3 集成场景

至少包含：

1. 当前行纯插入。
2. 多行函数体插入。
3. 当前区域单行替换。
4. 删除冗余分支。
5. 修改函数签名后修复同文件调用点。
6. 修改字段名后修复 diagnostic。
7. 建议请求期间继续输入，旧建议被丢弃。
8. 跳转后目标文本变化，应用被拒绝。
9. snippet 活跃时 Tab 不被 Minuet 抢占。
10. Blink 菜单可见时 fallback 正确。
11. 跨 Buffer 引用跳转和安全应用。
12. secret buffer 不被记录或发送。

### 8.4 性能测试

扩展现有 benchmark，测量：

- 每次 `TextChangedI` 的同步耗时。
- 编辑历史 recorder 的 CPU、临时文件和内存开销。
- candidate discovery 的 P50/P95。
- LSP 请求等待时间与超时退化。
- preview render 对 1、10、40 行 diff 的耗时。
- 连续输入 60 秒产生的请求数。

硬性要求：任何网络、diff 或 LSP 慢操作都不能在输入事件的同步路径中阻塞 UI。

---

## 9. 开发与提交顺序

建议按以下小步提交，避免一个巨大分支无法回归：

1. `test: add duet metrics and lifecycle coverage`
2. `feat(duet): add prediction scheduler`
3. `feat: add unified suggestion controller`
4. `feat: add tab arbitration API`
5. `feat(duet): validate and filter proposed edits`
6. `feat(duet): discover same-buffer candidates`
7. `feat(duet): preview and jump to remote buffer locations`
8. `feat(duet): add LSP diagnostic candidates`
9. `feat(duet): add symbol reference context`
10. `feat(duet): add guarded cross-buffer predictions`
11. `docs: document Cursor Tab workflow and privacy`

每个提交要求：

- 行为变化有测试。
- 不包含 API key、真实 prompt 日志或用户源码 fixture。
- 运行 `make test`。
- 运行 `make format-check`。
- 涉及 recorder 或事件热路径时运行 `make benchmark`。

---

## 10. 风险与对策

| 风险 | 对策 |
|---|---|
| 建议很多但接受率低 | 默认少展示；加入 no-op/大小/重复抑制和反馈指标 |
| FIM 与 Duet 请求互相干扰 | 统一 controller、generation 和优先级 |
| Chat 延迟破坏输入体验 | 较长 debounce、异步请求、旧请求取消、只在强信号后触发 |
| 三候选导致成本过高 | Cursor Tab 路线默认 FIM `n_completions = 1`；需要时再手动请求替代候选 |
| 模型返回大范围重写 | 固定 editable region、最大行数、原文相似度过滤 |
| 过期建议修改错误文本 | changedtick + original text + range 三重验证 |
| LSP 不可用或很慢 | 所有 LSP 信号可选并有超时；退化到 recent edits/cursor |
| 上下文泄露敏感信息 | path/filetype guard、预算白名单、默认不记录 prompt |
| 跨 Buffer undo 体验混乱 | 一次只编辑一个 Buffer；跨 Buffer 默认仅跳转预览 |
| 模型不稳定遵循 marker | 严格 parser、few-shot、失败静默丢弃；达到数据门槛后再评估 JSON schema |
| 上游 Minuet 持续演进 | 尽量扩展现有 Duet API；减少对公共 completion backend 的侵入 |

---

## 11. 明确不做

首轮路线不包含：

- 自动应用多个文件的补丁。
- 后台索引整个仓库并建立向量数据库。
- 自训练或微调模型。
- 自动运行生成代码或 shell 命令。
- 为每种语言维护独立预测引擎。
- 在 UI 中展示模型思维链或自然语言解释。
- 为兼容尚未发布的实验接口长期保留双实现。

如果 Phase 3 的同 Buffer 接受率仍低于门槛，不进入跨 Buffer 阶段，应先修正模型、上下文和触发策略。

---

## 12. 第一轮实施建议

第一轮开发只做 Phase 0 和 Phase 1，建议控制为以下交付物：

1. DeepSeek Chat Duet 示例配置可工作。
2. Duet 支持输入停顿和 `InsertLeave` 自动预测。
3. FIM 与 Duet 只有一个建议能处于可见状态。
4. 提供统一 Tab API，但不强制覆盖用户键位。
5. 当前 Buffer 修改能安全预览、接受、dismiss 和撤销。
6. 提供会话级接受率与延迟统计。
7. 所有新增异步竞态有自动测试。

完成第一轮后，用真实工作流收集至少 100 次建议，再决定 Phase 2 的候选评分细节。不要在没有数据前过早实现复杂仓库索引。

---

## 13. 成功判定

该改造成功的标志不是“功能列表看起来像 Cursor”，而是：

- 建议多数出现在用户可能继续编辑的位置。
- 插入、替换和删除都能在接受前看清。
- Tab 行为可预测，不破坏 snippet、completion 和缩进。
- 用户继续输入时 UI 不闪烁，旧请求不会回魂。
- 任意过期或歧义建议都不会被错误应用。
- 接受后可以自然进入下一项预测。
- 日常使用中的节省按键数和接受率持续提升。

最终优先级始终是：

```text
安全性 > 不打扰 > 延迟 > 接受率 > 功能覆盖范围
```
