# Cursor Tab 第六实施步骤：质量调优与受控发布（Phase 5）

> 状态：工程完成，发布门禁待真实数据
>
> 前置条件：[`04-cross-buffer-next-edit.md`](04-cross-buffer-next-edit.md) 工程退出条件已完成
>
> 真实数据状态：0/500 visible；用户决定先完成后续工程任务，因此本阶段不得宣称已达到发布质量

## 1. 目标

本阶段不再扩大 edit surface，而是让当前功能可测量、可比较、可抑制明显低质量重复，并明确区分工程完成与真实发布门禁。

```text
provider result
  -> parse/filter
  -> in-memory repeat fingerprint
  -> preview/accept/dismiss
  -> bounded accepted-undo observer
  -> allowlisted JSONL
  -> offline report / baseline-vs-variant comparison
  -> 500-visible release review gate
```

## 2. 非目标

- 不用单元测试、smoke、benchmark 或合成 JSONL 冒充真实编辑 cohort。
- 不因工程测试通过而默认启用 automatic Duet 或 cross-buffer edit。
- 不上传 telemetry，不记录源码、diff、prompt、response、path、identifier、diagnostic、filetype 或任意自由文本标签。
- 不在运行时自动调参，不为不同语言创建不同控制流分支。
- 不自动判定“可发布”；provenance、错误 Buffer 修改与 stale 误应用仍需人工审查。

## 3. 配置

```lua
duet = {
    auto_trigger = {
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
}
```

默认 `auto_trigger.enabled=false`、cross-buffer 双开关关闭。filetype 表默认为空，不在没有真实数据时预设语言优劣。非法 key/value 回退或删除；所有数值有界。

## 4. 同上下文重复建议抑制

- 只在 provider 已返回且 edit 已通过安全 filter 后执行，不改变 transport。
- fingerprint 由 target bufnr、changedtick、range 和 proposed region 的 SHA-256 组成；内存中只保存 hash 与时间。
- 相同 fingerprint 在 TTL 内不再次展示，记录 `filtered/repeat`；不同 changedtick、target、range 或文本不抑制。
- LRU/TTL 同时有界，setup/reset 清空；关闭时不计算 hash。
- 这是 UI 质量抑制，不算 provider 成本节省；scheduler 的 same-tick dismiss 抑制继续负责自动请求。

## 5. Filter 与撤销指标

生命周期新增：

- `filtered`，reason 仅允许 `no_op`、`whitespace_only`、`too_many_lines`、`too_many_bytes`、`repeat`。
- `reverted`，仅表示已接受 suggestion 在 `undo_window` 内由 `TextChanged` 观察到 undo sequence 穿过其接受 sequence。

accepted 后只保存 cycle ID、bufnr、undo sequence、单调时钟；不保存 edit 内容。pending observer 全局有界。普通后续 edit 的一次 undo若尚未穿过 suggestion sequence，不计 reverted；过期 entry直接丢弃。

## 6. Filetype 触发策略

scheduler 通过同一函数从 `auto_trigger.filetype[vim.bo[bufnr].filetype]` 解析 debounce/throttle，未配置字段继承全局值。策略表不进入 metrics/JSONL，离线实验使用不同日志文件，避免持久化任意标签或语言信息。

## 7. Offline Report 与比较

保留 100-visible early review gate，新增 500-visible release review gate：

| 指标 | 门槛 |
|---|---:|
| visible cohort | >= 500 |
| Next Edit preview P50 | < 1500 ms |
| Next Edit preview P95 | < 4000 ms |
| visible acceptance | >= 25% |
| accepted 后 10 秒内 reverted | < 10% |
| parse failure | < 2% |

report 同时输出 dismiss、no-op/filter 和 request outcome。`ready_for_release_review` 只表示可测门槛与数据完整性通过，绝不代表 provenance 已验证、FIM P50 已通过、stale 误应用为零或错误 Buffer 修改为零。

`compare(baseline, variant)` 分别分析两个独立路径集合，输出 count/rate/latency delta；不合并 cohort，不猜测统计显著性。候选分数、prompt、预算和触发策略的变体由用户配置与独立文件路径确定。

## 8. 测试

- repeat：相同 fingerprint 抑制，changedtick/range/text变化放行，TTL/LRU/reset/disabled 有界。
- feedback：立即 undo 计数，普通 edit undo不误计，超时/多 Buffer/max pending/setup cleanup。
- scheduler：filetype override、字段继承、非法配置、默认路径无额外开销。
- metrics/report：filtered/reverted 去重、allowlist、500 gate、各门槛边界、empty/integrity failure、comparison delta。
- integration：repeat 不显示、不 accepted；accepted -> undo -> reverted 恰好一次。
- regression：全部 Phase 1-4 tests、format、benchmark、diff、TUI、secret scan。

## 9. 文档与发布边界

README 必须包含：

- opt-in 配置与成本说明。
- 质量日志启用、独立 cohort 文件与 `:Minuet report`。
- repeat/filetype 配置。
- 常见故障：无预览、LSP timeout、stale、cross target 不合格、日志不可写/达到上限。
- 隐私：明确记录与不记录字段、文件权限、无上传、如何删除 cohort。
- 自动 Duet 与跨 Buffer 保持默认关闭，直到真实 500 cohort 和人工 provenance/safety review 全部完成。

## 10. 退出条件

1. 工程功能、测试、format、benchmark、TUI、隐私扫描全部通过。
2. report 真实显示当前 cohort 数，0/500 时保持 release review false。
3. 合成数据只验证计算，不写入真实 cohort或实施结果。
4. 工程退出条件完成后可将 Phase 5 标为“工程完成、发布门禁待真实数据”，不得标为“已发布”。

## 11. 实施记录

| 项目 | 结果 |
|---|---|
| 工程状态 | 完成；不等于已发布 |
| 开始日期 | 2026-08-03 |
| 完成日期 | 2026-08-03 |
| 真实 visible cohort | 默认真实日志位置匹配 0 个文件、0 个 session、0/500 visible；`ready_for_release_review=false`，未用测试数据补齐 |
| repeat/filetype/feedback | 完成：SHA-256 内存指纹有 TTL/LRU 上限；filetype 只声明 debounce/throttle；accepted undo observer 只保存 cycle/buffer/sequence/time |
| report/compare | 完成：保留 100-visible early gate，增加 500-visible release-review gate、filtered/reverted 聚合和独立路径 cohort delta |
| 自动测试 | 194/194 通过；合成 500 条场景只验证门槛数学，不写入真实 cohort，也不构成发布证据 |
| 性能 | 10,000 次唯一 repeat fingerprint 共 401.89 ms（40.19 us/check），仅保留 128 条；10,000 次空闲 feedback callback 共 16.48 ms（1.65 us/event），0 Buffer 读取 |
| 既有性能回归 | scheduler 10,000 次 callback 为 23.57 ms、0 request；candidate P50/P95 0.848/1.540 ms；semantic P50/P95 0.317/0.476 ms；cross-buffer P50/P95 0.387/0.989 ms |
| format/diff | `stylua --check lua/ tests/` 与 `git diff --check` 通过 |
| TUI | 同 Buffer与跨 Buffer 脚本均在 tmux 实际 PTY 的 80x24 dark/xterm-256color、120x40 light/xterm-256color 返回 exit 0 |
| 隐私扫描 | 仓库通用 `sk-` 密钥模式无匹配；生产代码与文档无测试 sentinel；JSONL allowlist、hash-only repeat state 与 0 Buffer-read idle path 由测试/benchmark 覆盖 |
| 发布状态 | automatic Duet 与 cross-buffer 默认关闭；真实 500 cohort、FIM P50、provenance、stale 误应用与错误 Buffer 修改人工审查均未完成，因此 release review 未通过 |
