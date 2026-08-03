# Cursor Tab 第五实施步骤：有限跨 Buffer Next Edit（Phase 4）

> 状态：已完成（工程退出条件通过；真实质量门禁按用户决定延期）
>
> 前置条件：[`03-symbol-context.md`](03-symbol-context.md) 已完成工程退出条件
>
> 数据状态：真实 visible cohort 仍为 0/100，按用户决定延期；跨 Buffer 默认关闭且不作为质量已验证功能
>
> 范围：同 workspace、已加载 Buffer 中的一处 suggestion；每次只请求、预览和修改一个 target Buffer

## 1. 目标

把 Phase 3 已取得但仅作摘要的其他 Buffer LSP reference，升级为显式 opt-in 的候选。模型仍只收到一个 target Buffer editable region，第一次 Tab 跳到目标并展示 diff，第二次 Tab 才应用。

```text
origin Buffer edit
  -> bounded semantic pipeline
  -> same-buffer candidates + guarded loaded-buffer references
  -> select exactly one target
  -> snapshot origin identity + target identity/version/range
  -> request one target editable region
  -> origin shows target path:line hint; hidden target stores sign
  -> first Tab validates both anchors, enters jumplist, switches Buffer, reveals diff
  -> second Tab revalidates target and applies one undo unit
```

## 2. 非目标

- 不打开或读取未加载文件，不执行 workspace scan/index/search。
- 不修改多个 Buffer、多个 range 或一个 patch set。
- 不自动保存 target，不处理磁盘写入，不运行 formatter/tests。
- 不跨 workspace，不编辑 terminal/help/prompt/nofile/secret/binary/oversized Buffer。
- 不在 target 未显示时提前渲染完整 diff，不创建 floating preview Buffer。
- 不默认启用，不因 related context 已启用而自动启用 cross-buffer edit。
- 不把 target path/source/response 写入 metrics、JSONL 或 public lifecycle event。
- 不声称 cross-buffer 定位率已达发布标准。

## 3. 双重显式开关

```lua
duet = {
    scope = 'workspace', -- 'cursor' | 'buffer' | 'workspace'
    candidates = {
        related_buffers = true,
    },
    preview = {
        cross_jump_text = 'Next edit: %s:%d',
    },
}
```

只有 scope 与 flag 同时满足才读取其他 Buffer reference 作为候选。默认仍为 `scope='buffer'`、`related_buffers=false`，因此升级配置不增加跨 Buffer LSP/context/provider 成本。

非法 scope 回退 `buffer`。cross jump text 必须恰好接受 path string 和 line integer且格式化成功；否则回退默认。UI path 只用 workspace-relative safe label。

## 4. Semantic Location

`DuetSemanticContext` 新增：

```lua
---@field related_references {
---  bufnr: integer,
---  row: integer,
---  col: integer,
---  path: string,
---  name: string,
---}[]
```

LSP reference URI 只有满足下列条件才进入：

- URI 映射到已加载 Buffer，不调用 load/open。
- 与 origin 使用同一个 workspace root，path 可安全相对化。
- loaded、listed、普通文件、modifiable、非 binary/secret，大小不超过配置 guard。
- 不是 origin Buffer；current Buffer reference 继续进入 `references`。
- LSP character col 按 client encoding 转成 target byte col。
- 总数仍共享 `lsp.max_locations`，稳定按 path/row/col 去重。

cache 只保存 bufnr、relative path、row/col 和 bounded identifier。BufWipeout 立即 invalid；target changedtick 不属于 origin semantic cache key，因此 candidate select/context build 时必须再次验证。

## 5. Candidate

source 新增 `related_buffer`，基础分 provisional `55`。去重 key 从 row 改为 `bufnr + row`：

- same-buffer 来源按 Phase 3 累加与距离扣分。
- related reference 同行只贡献一次 `55`，不与 origin cursor distance 混算。
- related candidate 稳定按 score、source、workspace path、row、col 排序。
- candidate metadata 不保存 path/name，只保存 source enum 与数字；candidate 顶层 bufnr 指 target。
- target 任一 guard 失败时淘汰；全部淘汰则退化同 Buffer。

## 6. Anchor 与状态

lease/state 增加：

```lua
---@field origin_bufnr integer
---@field origin_changedtick integer
---@field target_bufnr integer
---@field target_changedtick integer
---@field cross_buffer boolean
---@field state_bufnr integer
---@field focusing boolean
```

controller active owner 仍只有一个。`invalidate_buffer()` 必须匹配 origin 或 target；state 实体只由 origin `state_bufnr` 持有，action 在跳转后通过 current lease 找回它，不能按当前 target 新建空 state。

clear/setup/reset/terminal 必须删除 origin hint、target sign、target diff 和所有 anchor 引用。

## 7. Context 与 Provider

- `context.build(target_bufnr, candidate, semantic)` 读取 target snapshot，不移动 cursor。
- current file/path/filetype/diagnostics 都描述 target；recent edits仍是同一 bounded session history。
- related context不得重复包含 target 本身。
- marker prompt只允许改 target editable region，不包含 origin patch。
- provider callback 前后验证 target loaded/modifiable/changedtick/original range以及 current controller generation。
- origin 在 response 等待期必须仍是 current Buffer；用户切走即 stale。

`apply.prepare()` 接受 `lease.target_bufnr`，不再错误要求 target 在 response parse 时已是 current。它仍要求 current controller、target loaded/modifiable、changedtick/range/original/limits。真正 `apply.apply()` 时 target 必须是当前 Buffer。

## 8. Cross Preview

preview extmark state 改为记录 `{ bufnr, id }`，从而一次 clear 可删除多个 Buffer 的 extmark。

初始 cross state：

- origin row：`Next edit: relative/path.lua:N` virtual text。
- target row：`>>` sign extmark，可存在于未显示但已加载 Buffer。
- 不显示 target source text或完整 diff。
- semantic highlight 继续 `MinuetDuetJump -> DiagnosticInfo`，文本与 sign 提供非颜色信号。

same-buffer `Next edit: line N` 保持不变。

## 9. 第一次 Tab

1. controller preflight 验证 generation、origin current/version、target identity/version/range/original。
2. `state.focusing=true`，避免本次受控 origin `BufLeave` 把自身取消。
3. 使用标准 `:hide buffer {target}` 切换当前窗口，不使用 `nvim_win_set_buf` 绕过 jumplist/alternate Buffer 语义；`hide` 修饰保证 `nohidden` 下未保存 origin 仍留在内存且不被写入或丢弃。
4. 失败则恢复 focusing 并 stale，不写任何 Buffer。
5. 设置 target cursor，清 hint/sign，渲染完整 diff。
6. lease accepting -> visible；accepted/after_accept 均不触发。

必须验证 `getjumplist()`/`<C-o>` 可返回 origin，且 alternate Buffer 语义合理。若 Neovim `:buffer` 在当前版本不产生 jumplist entry，实施必须先调用标准 mark/jumplist API或等价 normal jump，不伪造文本按键。

## 10. 第二次 Tab 与撤销

- action 通过 controller current lease 找到 origin-owned state。
- preflight 再验证 target 是 current、target changedtick/range/original 完全匹配。
- 一次 `nvim_buf_set_lines` 修改 target，cursor clamp，accepted 一次。
- 一个 `u` 只撤销 suggestion；origin 不变化。
- follow-up scheduler 以成功应用后的 target Buffer 为起点。

target 在 jump 前/后被用户、LSP edit或其他 API修改都直接 stale，不做 extmark relocation/merge。

## 11. 事件失效

- origin TextChanged/BufLeave（非 focusing）/BufWipeout：取消。
- target TextChanged/BufWipeout/unload/readonly：取消。
- jump 后 target BufLeave：取消并清 diff；不自动跳回 origin。
- target diagnostic/reference 消失不单独取消已生成 edit，只要 target snapshot仍一致；下一 cycle 重排。
- dismiss before jump停留 origin；dismiss after jump停留 target；两者不写 Buffer且清全部 extmark。
- setup/reset清所有 Buffer extmark、semantic request/timer/cache waiter。

## 12. 测试

### Candidate/Semantic

- other URI maps only to safe same-workspace loaded Buffer。
- unloaded/outside/secret/binary/nofile/unmodifiable/oversized filtered。
- related flag/scope 任一关闭时零 cross candidate。
- bufnr+row dedup、score/tie stable、same-buffer fallback。
- UTF-16 target column conversion、BufWipeout invalidation。

### Context/Apply/Controller

- hidden target context snapshot不移动 origin cursor/window。
- prepare hidden target succeeds only for lease target；apply before focus fails。
- origin/target changedtick、range/original guards。
- controller invalidate匹配两 anchor，state在 target action可找回。

### Integration/TUI

- fake LSP other-buffer reference -> one provider request centered target。
- response 前 Buffer switch或target edit fences callback。
- cross initial origin path:line + hidden target sign，无完整 diff泄漏。
- first Tab switches/jumplist/diff/no write/no accepted。
- second Tab one write/accepted/one undo/follow-up target。
- dismiss/stale/setup/wipe before/after jump清多 Buffer extmark。
- cross disabled保持 Phase 3行为且不枚举相关候选。
- 80x24/120x40 path裁切无 overlap；颜色不作为唯一信号。

## 13. Benchmark 与隐私

- 32 loaded Buffer、64 cross references candidate normalize/select。
- 多 Buffer extmark render/clear 1,000 次。
- cross disabled hot path零额外 Buffer read/list。
- 全量 `make benchmark` 保持 TextChanged同步路径零 LSP/network/Buffer全读。

secret/key/path扫描必须证明 absolute URI、identifier、source、prompt、response不进入 metrics/event/JSONL。UI 与 provider可使用 safe workspace-relative target path，这是显式功能数据，不持久化。

## 14. 文件范围

主要修改 `symbols.lua`、`candidates.lua`、`suggestion.lua`、`context.lua`、`apply.lua`、`preview.lua`、`duet/init.lua`、config、README、benchmark；新增 cross candidate/preview/apply/integration tests。provider transport、metrics schema和marker parser不变。

## 15. 退出条件

1. 默认关闭且双开关生效。
2. 一次只修改一个 safe loaded same-workspace target。
3. first Tab零写入，second Tab严格重验并单 undo。
4. jumplist可返回，target invalid永不写入。
5. 全部旧/新测试、format、benchmark、diff、TUI、隐私扫描通过。
6. 真实 cohort 0/100状态继续可见，不把 fake cross测试当定位率证据。
7. 实施记录列出偏差与残余风险后才进入 Phase 5。

## 16. 验证命令与实施记录

```sh
make test
make format-check
make benchmark
git diff --check
```

| 项目 | 结果 |
|---|---|
| 实施状态 | 已完成；跨 Buffer 仍默认关闭 |
| 开始日期 | 2026-08-03 |
| 完成日期 | 2026-08-03 |
| 100 visible 数据 | 0/100；用户明确延期 |
| 自动测试 | 184/184 通过；覆盖双开关、安全 URI 映射、UTF-16 col、cache invalidation、hidden target prepare、双 anchor/path/version、两步 Tab、dismiss/stale、单次 undo |
| 格式/benchmark/diff | `make format-check`、`make benchmark`、`git diff --check` 通过；32 loaded Buffer + 64 references 的 P50 0.404 ms、P95 1.013 ms、max 1.338 ms；1,000 次多 Buffer hint render/clear 平均 0.002 ms；关闭路径 0 次 Buffer 枚举 |
| TUI/jumplist/undo | `tests/cursor_tab_cross_tui.lua` 在 tmux PTY 的 80x24 dark/xterm-256color 与 120x40 light/xterm 通过；screen-cell、hidden sign、diff reveal、jumplist return、单 undo 均为真实终端断言 |
| 隐私扫描 | 通用 `sk-` 长 token 扫描无匹配；候选/metrics 测试证明 identifier、diagnostic、path、prompt、response 不进入持久化字段；UI 只显示安全 workspace-relative path |
| 与本文偏差 | 裸 `:buffer` 改为标准 `:hide buffer` 修饰形式，以支持 `nohidden` 且 origin 未保存的真实场景；仍走 Buffer/jumplist/alternate Buffer 语义，不写入或丢弃 origin |
| 遗留问题 | cross score/interaction 无真实数据校准；真实 cohort 仍为 0/100；功能保持双开关默认关闭，不构成发布质量证明 |
