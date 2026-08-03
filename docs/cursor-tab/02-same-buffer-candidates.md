# Cursor Tab 第三实施步骤：同 Buffer 候选位置与两步跳转（Phase 2）

> 状态：已完成
>
> 前置条件：[`01-current-buffer-next-edit.md`](01-current-buffer-next-edit.md) 的工程实现与真实 smoke 已完成；100 条真实 visible 数据门禁按用户决定延期
>
> 数据偏差：Phase 1 后的 100 条真实 visible 建议仍为 0/100；用户于 2026-08-03 明确要求暂缓该门禁并继续。本阶段评分均为 provisional，不代表真实质量结论
>
> 范围：仅当前 Buffer；候选仅来自当前光标、recent edit hunk 和 Neovim diagnostic cache；一次只请求一个候选区域

## 1. 目标

把 Phase 1 固定围绕当前光标的 Duet 升级为当前 Buffer 内的下一编辑预测：Neovim 先发现并排序少量可信位置，只把最高分位置交给现有 marker prompt。模型不能返回任意文件或任意行号。

完成后的主流程：

```text
eligible trigger
  -> flush bounded recent edits
  -> discover cursor/recent-edit/diagnostic candidates
  -> deduplicate and rank
  -> build existing editable region around rank #1
  -> request one Duet rewrite
  -> validate and prepare one edit
  -> local target: render normal diff
  -> remote row: render origin hint + target sign
  -> first Tab: validate, jump, reveal diff
  -> second Tab: validate, apply, record accepted
```

必须保持 Phase 1 的 generation、Buffer identity、changedtick、original text、大小过滤、一次 undo 和 targeted cancellation 约束。

## 2. 非目标

- 不实现 LSP document symbols、definition、references 或任何新 LSP request；这些属于 Phase 3。
- 不读取其他 Buffer，不加入 import/require 或相关文件上下文。
- 不实现跨 Buffer jump/apply；这些属于 Phase 4。
- 不让模型选择 path、row 或 candidate。
- 不一次发送多个候选区域，不并行请求多个 Duet。
- 不根据 filetype 调整权重，不加入历史接受率；这些需要真实数据并属于 Phase 5。
- 不默认开启 automatic Duet，不安装 `<Tab>` mapping。
- 不把 diagnostic message、recent diff、源码、路径或候选 metadata 写入 metrics/JSONL/public event。

## 3. 数据门禁延期决策

原计划要求先收集 100 条真实 visible 建议再确定评分。用户明确选择先实现后续阶段，因此本阶段只能采用 roadmap 已写明的启发式作为工程初值：

- 代码和测试只能证明确定性、安全性、资源边界与交互契约。
- 不声称候选定位率、接受率或权重优于其他方案。
- `duet.auto_trigger.enabled` 继续默认 `false`。
- Phase 5 的 500 条真实数据和发布质量门不因本次延期自动豁免；若用户届时仍要求跳过，只能记录为未验证风险，不能伪造结果。
- `:Minuet report` 继续显示真实计数；smoke、fake provider 和合成 fixture 不进入真实 cohort。

## 4. 复用边界

| 现有模块 | Phase 2 用法 |
|---|---|
| `duet.edits` | 读取有界 `get_events()`；不复制 recorder 或另存源码 |
| `vim.diagnostic` | 只读当前 Neovim diagnostic cache；不触发 LSP 请求 |
| `duet.context` | 接受显式候选 row/col，继续使用现有字符预算和 marker 字段 |
| `suggestion` | lease 增加目标位置与 jump 状态，并支持第一次 Tab 后恢复 visible |
| `duet.preview` | remote 时先渲染 jump hint/sign，聚焦后复用现有 diff renderer |
| `duet.apply` | 两次 Tab 前都执行现有 changedtick/original/range 验证 |
| `duet.scheduler` | 不在 TextChanged 同步路径发现候选；只在 delayed predict 中运行 |
| `metrics` | 保持 cycle/request/lifecycle schema，不新增位置或来源字段 |

## 5. Candidate 模型与 API

新增 `lua/minuet/duet/candidates.lua`：

```lua
---@alias minuet.DuetCandidateSource 'cursor'|'recent_edit'|'diagnostic'

---@class minuet.DuetCandidate
---@field bufnr integer
---@field row integer                  -- 0-based
---@field col integer                  -- 0-based byte column
---@field source minuet.DuetCandidateSource
---@field score number
---@field distance integer
---@field metadata { sources: minuet.DuetCandidateSource[], severity?: integer, edit_age?: integer }

---@param bufnr integer
---@return minuet.DuetCandidate[]
require('minuet.duet.candidates').collect(bufnr)

---@param bufnr integer
---@return minuet.DuetCandidate?
require('minuet.duet.candidates').select(bufnr)
```

`collect()` 返回深拷贝的新表，不把 recorder event 或 diagnostic table 引用暴露给调用方。无有效候选时 `select()` 返回 `nil`，调用方释放 pending lease 且不创建 metrics cycle/network request。

测试与 benchmark 可给 `collect()` 传入内部 options 覆盖 cursor/events/diagnostics，避免依赖真实 LSP 或异步 recorder；这些 options 不写入 README 公共 API。

## 6. 候选来源

### 6.1 Cursor

- 使用当前窗口光标的 0-based row 与 byte col。
- 仅当 `bufnr` 是当前 Buffer、已加载且可修改时加入。
- 基础分 `100`。

### 6.2 Recent Edit Hunk

- 只读取 `duet.edits.get_events()` 中 `event.bufnr == bufnr` 的事件。
- 从标准 unified diff hunk header 的 new-file start row 提取位置；不解析 diff body，不保存行内容。
- 最新事件基础分 `90`，每老一个事件扣 `5`，最低 `50`。
- 一个事件有多个 hunk 时每个 hunk产生一个候选；删除 hunk 的 new count 为 0 时把位置 clamp 到当前 Buffer 合法行。
- malformed header 静默忽略，不回退到猜测位置。

### 6.3 Diagnostics

- 使用 `vim.diagnostic.get(bufnr)` 的当前缓存，不调用 `vim.lsp.buf_request*`。
- ERROR/WARN/INFO/HINT 基础分分别为 `80/60/40/30`。
- 只保存 severity 和位置，不保存 message、code、source 或 user_data。
- stale/out-of-range diagnostic 被过滤；同一行多个 diagnostic 只保留最高 severity 的一次来源分。
- 无 LSP client 或无 diagnostic 时返回空来源，不通知、不报错。

## 7. 去重、评分与稳定排序

去重 key 为 `bufnr + row`。同一行不同来源合并为一个候选：

1. 每种来源最多贡献一次分数；同来源重复记录只保留最高基础分。
2. 合并后 `score = unique source scores sum - min(distance * 0.5, 50)`。
3. `distance = abs(candidate.row - current_cursor.row)`，距离惩罚只扣一次。
4. `source` 与 `col` 取该行最高单项来源；同分优先级为 cursor、recent_edit、diagnostic。
5. `metadata.sources` 固定按 cursor、recent_edit、diagnostic 排序。
6. 总排序依次为：score 降序、source 优先级、distance 升序、row 升序、col 升序。
7. 最多返回 `duet.candidates.max_candidates` 个，默认 `8`，非法值回退默认并 clamp 到 `1..64`。

不同来源可累加，使 recent edit 与 error diagnostic 的交集有机会超过纯 cursor；单独 diagnostic 不会凭低置信信号抢走当前光标。该规则是 provisional，不能描述为数据优化结果。

## 8. 配置

```lua
duet = {
    scope = 'buffer', -- Phase 2 accepts 'cursor' or 'buffer'.
    jump_requires_confirmation = true,
    candidates = {
        cursor = true,
        recent_edits = true,
        diagnostics = true,
        max_candidates = 8,
    },
    preview = {
        cursor = '...', -- existing value
        jump_text = 'Next edit: line %d',
        jump_sign = '>>',
    },
}
```

- `scope = 'cursor'` 强制只生成 cursor candidate，提供 Phase 1 行为回退。
- `scope = 'buffer'` 启用本阶段三种来源。
- 非法 scope 回退默认 `buffer`；`workspace` 在 Phase 4 前不接受。
- 三个来源可以独立关闭；全部关闭时不请求。
- `jump_requires_confirmation = true` 是安全默认值。
- jump sign 保持最多两个显示单元；非法/空值回退 ASCII `>>`。
- jump text 必须是带一个 `%d` 的短模板；格式错误时回退默认。它只表达当前状态，不显示快捷键教学。

## 9. Context 显式目标

`context.build(bufnr, candidate?)` 保持旧调用兼容：

- 未传 candidate 时继续使用当前窗口光标。
- 传入时以 candidate row/col 切分 editable region，不移动真实 cursor。
- row clamp 到 `0..line_count-1`，col clamp 到目标行 byte 长度。
- `candidate.bufnr` 若存在且不等于 `bufnr`，立即拒绝；Phase 2 不接受跨 Buffer。
- 返回的 `changedtick`、range 与 original lines 来自同一次 Buffer snapshot。
- prompt 字段保持不变；Phase 2 不把 source/score/diagnostic message 注入模型。

## 10. Suggestion 与 Duet 状态

`SuggestionLease` 增加：

```lua
---@field target_row? integer
---@field target_col? integer
---@field jump_required? boolean
---@field jumped? boolean
```

controller 增加 `resume_visible(lease)`，只允许 current lease 从 `accepting` 回到 `visible`。它用于第一次 Tab 已完成跳转但尚未应用的状态，不产生 accepted/dismissed/stale metrics，也不改变 generation。

`DuetState` 保存 candidate、origin row/col 和 jump-required 状态；终态或 setup/reset 时全部释放。controller 仍不保存 original/proposed text。

## 11. Remote Preview 与两步 Tab

### 11.1 初始 remote 状态

模型结果通过 parse/filter 后，以第一个实际 diff hunk 的 Buffer row 作为 suggestion target。若 target row 与请求时 origin row 不同，且 `jump_requires_confirmation = true`：

- origin row 只显示 `Next edit: line N` 虚拟文本。
- target row 设置 ASCII `>>` sign/extmark。
- 不在其他可见行提前展开完整 diff，减少视觉噪声。
- 两者使用 `MinuetDuetJump` semantic highlight，默认链接 `DiagnosticInfo`；即使无颜色，文本和 sign 仍可辨认。

不得创建 floating window、modal、animation 或默认 keymap。终端 resize、窄窗口、tmux/SSH 下只依赖 Neovim extmark 自身裁切，不计算固定宽度布局。

### 11.2 第一次 Tab

1. controller `can_accept` 先执行完整 apply preflight。
2. 设置当前窗口 cursor 到 target row/col，clamp 到合法位置。
3. 清除 origin hint 与 target sign，展开现有 diff preview。
4. lease 标记 `jumped = true`、`jump_required = false`。
5. controller 从 accepting 恢复 visible。
6. 不修改 Buffer、不记录 accepted、不调度 follow-up。

### 11.3 第二次 Tab

再次执行完整 preflight，成功后使用现有 apply 路径修改一次 Buffer、记录 accepted、形成独立 undo 单元并调度下一次 prediction。

`duet.action.apply()` 与统一 Tab 使用相同两步安全语义，避免命令绕过 confirmation。`duet.action.dismiss()` 在跳转前后均清理所有 extmark。

## 12. Candidate 失效与异步边界

- TextChanged/BufLeave/BufWipeout 继续立即取消 lease 和目标 transport。
- response callback 在 parse、state 写入和 render 前继续检查 generation、current Buffer 和 changedtick。
- `DiagnosticChanged` 不发请求；若 active candidate 仅由 diagnostic 支撑且对应 row 已消失，则使 lease stale 并清理 hint/sign/diff。
- diagnostic 仍存在但 severity 改变不重排已发出的请求；下一 cycle 重新发现。
- 第一次 Tab 后目标文本或 changedtick 变化，第二次 Tab 必须拒绝且不写 Buffer。
- setup/reset、dismiss、stale 和 filtered/no-op 路径都不得留下 sign/extmark。

## 13. 文件范围

### 13.1 新增

| 文件 | 职责 |
|---|---|
| `lua/minuet/duet/candidates.lua` | 当前 Buffer 候选发现、diff hunk row 解析、diagnostic cache、去重、评分和稳定排序 |
| `tests/duet_candidates_spec.lua` | 来源、分数、去重、排序、限制、异常输入与无 LSP 降级 |
| `tests/cursor_tab_jump_spec.lua` | remote response、第一次 Tab jump、第二次 apply、stale、dismiss 与 undo 集成 |
| `tests/cursor_tab_tui.lua` | 可重复的实际 PTY screen-cell 回归，不进入自动测试或真实质量 cohort |

### 13.2 修改

| 文件 | 改动 |
|---|---|
| `lua/minuet/duet/config.lua` | scope、candidate、confirmation 与 jump preview 默认值/type |
| `lua/minuet/duet/context.lua` | 接受显式 candidate row/col |
| `lua/minuet/suggestion.lua` | target/jump lease 字段与 `resume_visible()` |
| `lua/minuet/duet/init.lua` | discover/select、remote state、focus/apply 两阶段、DiagnosticChanged invalidation |
| `lua/minuet/duet/preview.lua` | origin hint、target sign、focus 后 diff |
| `tests/duet_context_spec.lua` | explicit target 与跨 Buffer 拒绝 |
| `tests/suggestion_spec.lua` | accepting -> visible 状态约束 |
| `tests/duet_preview_spec.lua` | jump hint/sign 和 clear |
| `tests/duet_config_spec.lua` | 新默认值与非法值 normalize |
| `tests/cursor_tab_bench.lua` | candidate discovery 规模基线 |
| `README.md` | same-buffer scope、candidate 来源、两步 Tab、配置和限制 |

本阶段不修改 provider transport、metrics schema、recent edit 存储格式或 prompt marker 协议。

## 14. 自动测试

### 14.1 Candidates

至少覆盖：

1. cursor-only 默认候选。
2. unified diff 单/多 hunk row 提取与 deletion clamp。
3. current Buffer 之外的 edit event 被忽略。
4. diagnostics severity 分数与不保存 message。
5. 同一行重复 diagnostic 不叠加，同一行不同来源正确累加。
6. recent+error 可超过纯 cursor。
7. 距离惩罚只扣一次且 capped。
8. 分数相同的稳定 tie-break。
9. max candidates 边界与配置来源开关。
10. invalid/unloaded/nonmodifiable/wrong current Buffer 返回空。
11. 无 diagnostic/LSP 时只保留 cursor/recent。
12. 返回值不共享输入 metadata 引用。

### 14.2 Context

- explicit candidate 不移动真实窗口 cursor。
- row/col clamp 后 editable before/after 正确。
- candidate Buffer 不匹配时拒绝。
- 旧 `build(bufnr)` 行为保持。

### 14.3 Controller/Preview/Tab

- `resume_visible()` 只接受 current accepting lease。
- remote 初始只显示 origin hint + target sign。
- 第一次 Tab cursor 跳转、Buffer 不变、accepted 不增加、lease 回 visible。
- 第二次 Tab apply 一次并 accepted 一次。
- 第一次与第二次 Tab 都运行 preflight。
- 跳转后目标变化不应用并清理。
- dismiss/reset/DiagnosticChanged 清理所有 extmark。
- `jump_requires_confirmation = false` 保持一次 apply。
- local target 保持 Phase 1 一次 Tab apply。
- remote apply 的一次 `u` 只撤销 suggestion。

### 14.4 兼容性

全部 Phase 0/1 provider、FIM、Duet、cmp、Blink、LSP、metrics、scheduler、transport 和 Tab 测试继续通过。所有自动测试使用 fake backend/cache，不访问网络。

## 15. Benchmark

扩展 `make benchmark`，同机记录：

- 10,000 行 Buffer，cursor + 100 recent hunks + 1,000 diagnostics 的单次 candidate collect。
- 1,000 次 candidate collect 的 P50/P95/max。
- 同行大量 diagnostics 去重后的候选数和 Lua heap 增长。
- TextChangedI 现有同步 benchmark 必须保持无 candidate discovery、无 diagnostic scan、无 Buffer 全读和无 LSP request。
- remote jump hint/sign render 与 focus 后 diff render 的耗时。

不先设武断微秒阈值；若 collect 明显超过 5ms 或产生无界状态，必须优化或记录阻塞。

## 16. 人工 TUI 回归

在 80x24、120x40 和至少一个宽窗口中，用临时普通 Buffer 和 fake provider 执行：

| # | 场景 | 预期 |
|---:|---|---|
| 1 | scope=cursor | 行为与 Phase 1 相同 |
| 2 | remote recent+diagnostic 胜出 | origin hint 与目标 `>>` 出现 |
| 3 | 第一次 Tab | 跳到目标并展示 diff，源码未修改 |
| 4 | 第二次 Tab | 只修改目标区域，cursor 合法 |
| 5 | apply 后一次 `u` | 只撤销 suggestion |
| 6 | jump 前 dismiss | hint/sign 全部清理 |
| 7 | jump 后 dismiss | diff 全部清理，源码不变 |
| 8 | jump 后编辑目标 | 第二次 Tab 拒绝，不误应用 |
| 9 | DiagnosticChanged 移除唯一候选 | pending/visible 状态清理 |
| 10 | 无 diagnostics | cursor/recent 正常退化 |
| 11 | 窄窗口/长行 | hint 被 Neovim 裁切但不覆盖源码、不报错 |
| 12 | dark/light/无自定义 highlight | sign + 文本仍可区分，颜色不作为唯一信号 |
| 13 | tmux/SSH 等价 TERM 环境 | 不依赖鼠标、popup 或终端私有协议 |
| 14 | popup menu 可见 | scheduler gate 与 Tab fallback 保持 Phase 1 行为 |
| 15 | setup/reset/Buffer wipe | 无 sign/extmark/timer 泄漏 |

人工记录不得把临时源码、路径、diagnostic message 或 response 写进本文。

## 17. 隐私与安全

- candidate metadata 只含枚举、数字和来源集合。
- diagnostic message/code/source/user_data 不进入 candidate、prompt、metrics、event 或通知。
- recent diff 仍只进入现有 prompt；candidate parser 只提取 hunk header 行号。
- jump hint 只显示 1-based line number，不显示 Buffer 名、路径或 diagnostic 文本。
- 不新增 JSONL 字段，不新增真实数据落盘。
- secret predicate、binary/size/modifiable gate 继续在 scheduler/request 前生效。
- `scope='cursor'` 提供保守回退；automatic requests 默认关闭。

## 18. 实施顺序

1. candidates 单元测试与实现。
2. context explicit target 测试与实现。
3. controller jump state 测试与实现。
4. preview hint/sign 测试与实现。
5. Duet candidate integration 与两步 Tab 集成测试。
6. DiagnosticChanged、dismiss、stale、undo 回归。
7. benchmark、README、人工 TUI、implementation record。

不 commit、stage、reset 或清理现有 dirty worktree。

## 19. 验收标准

### 19.1 正确性

- 每个 cycle 只选择一个当前 Buffer candidate。
- context editable region 以该 candidate 为中心。
- remote 第一次 Tab 永不修改 Buffer，第二次才可应用。
- 两次操作前均验证 generation、bufnr、changedtick、range 和 original text。
- stale/消失 candidate 永不 render 或 apply。
- candidate 去重与排序在相同输入下完全确定。

### 19.2 交互

- jump hint/sign 在无颜色时仍可识别。
- 不创建默认 keymap、modal、floating window 或鼠标依赖。
- local suggestion、fallback、completion menu 与 manual Duet 保持兼容。
- jump 前后 dismiss 都可恢复干净编辑界面。

### 19.3 性能与资源

- candidate discovery 不在 TextChanged 同步 callback 中运行。
- 无 LSP request，diagnostic cache 读取失败时静默降级。
- setup/reset/terminal lifecycle 不泄漏 extmark、timer、job 或 candidate table。
- benchmark 和全量测试通过。

### 19.4 文档与数据诚实性

- README 配置/API 与实现一致。
- implementation record 写入真实测试、benchmark 和人工结果。
- 0/100 数据缺口保持可见，不声称评分经过真实验证。

## 20. 退出条件

只有以下全部满足后才能编写 Phase 3 规格：

1. 第 14 节自动测试和全部历史测试通过。
2. `make format-check`、`make benchmark`、`git diff --check` 通过。
3. 第 16 节人工 TUI 回归逐项有真实记录。
4. no LSP、diagnostic 消失、jump 后 stale 和 undo 均已验证。
5. README、配置注解和公开 API 同步。
6. 没有错误 Buffer 修改、第一次 Tab 直接应用、旧 callback render 或资源泄漏。
7. 第 21 节记录全部实施偏差和遗留风险。

本阶段不要求再次运行付费 endpoint：候选发现和 jump 均在 transport 前后本地完成，Phase 1 已验证相同 DeepSeek marker/streaming 协议。若 provider/prompt/response 协议发生变化，则必须恢复真实 smoke。

## 21. 验证命令与实施记录

```sh
make test
make format-check
make benchmark
git diff --check
```

| 项目 | 结果 |
|---|---|
| 实施状态 | 已完成 |
| 开始日期 | 2026-08-03 |
| 完成日期 | 2026-08-03 |
| 100 visible 数据 | 0/100；用户明确延期，不作为质量已验证证据 |
| 自动测试 | `make test`：164/164 通过；包含 candidate、显式 context、两步 Tab、DiagnosticChanged、jump 后 stale、dismiss、一次 undo 和 confirmation opt-out |
| 格式检查 | `make format-check` 通过 |
| benchmark | `make benchmark` 通过；10k 行 + 100 hunks + 1k diagnostics 的 1,000 次 collect：P50 0.828 ms、P95 1.547 ms、max 2.120 ms；10k 同行 diagnostics 去重为 1 candidate，heap +5.91 KB；jump hint 0.002 ms，focus + diff 0.001 ms |
| 实际 TUI | `tests/cursor_tab_tui.lua` 在 80x24、120x40、180x50，dark/light，`xterm`/`xterm-256color`/`screen-256color` 共 6 个 PTY 场景通过；额外 80x24 长行裁切通过 |
| diff 检查 | `git diff --check` 通过；通用 key pattern 扫描无仓库命中 |
| 与本文偏差 | 真实数据门禁按用户决定延期；未重复调用付费 endpoint；新增可重复 PTY screen-cell 脚本作为人工终端检查的结构化证据 |
| 遗留问题 | provisional scoring 尚无真实数据校准；PTY 宿主不响应 Neovim background-color DSR 查询会显示启动警告，但 dark/light 显式配置后的 screen-cell 断言均通过 |

实际终端回归还结合自动集成测试核对了 `scope=cursor`、无 diagnostics 降级、popup/fallback、jump 前后 dismiss、candidate 消失、setup/reset 和 Buffer wipe。PTY 脚本只检查屏幕单元与状态，不保存临时源码、路径、diagnostic message 或 response。
