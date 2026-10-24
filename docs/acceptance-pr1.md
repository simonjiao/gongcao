# PR1 验收记录

实现与测试基线：`4199f9784fc2ec8f32939544bb16234fd84b8893`。
本文件和证据 JSON 是后续文档提交，不改变已验收的生产代码。

## 自动化验证

- `uv sync --locked` / `uv lock --check`：锁定依赖一致。
- `uv run ruff check .`、`uv run ruff format --check .`、`uv run mypy`：通过。
- `uv run pytest -q`：**43 passed**，16.71 秒；pytest 对整个 gongcao 包启用 beartype。
- 覆盖真实 Bubblewrap 的四角色权限、宿主授权文件不可见、环境中无 GitHub token、
  符号链接越界、uv 项目检查、独立 Worktree；以及状态门禁、上下文与 PR Diff、
  新 SHA/请求变化的证据失效、双 SQLite 连接取消竞态、超时/退出/日志失败和日志脱敏轮换。
- 状态流测试使用替代 SDK worker；它们不等于真实模型或真实 GitHub 工作闭环验收。
- Standards 与 Spec 两个独立审查各发现 3 项问题，均已修复并复核，无剩余阻塞项。

## 真实 SDK 与只读 GitHub 验收

2026-10-24，使用已登录的 GitHub CLI 只读登记本仓库 Issue #1，
在以上固定 SHA 上运行官方 Python SDK 0.163.0 随附的 Codex 0.163.0。
采用专门的 analyst 提示，限定检查 PR1，不允许修改代码或远端对象。

- Run：`d20f8a99dadf4c39bb97978c8bf909e1`
- Thread：`01a16e12-d046-75a3-a13d-d9938f611da8`
- 完成耗时：27.929 秒；执行结果 `completed`，任务进入 `pending_development/queued`。
- 启动前真实隔离探测通过：宿主凭据与源仓库不可读、工作区只读、外部写入被拒绝、uv 可运行。
- 记录 335 条 SDK 事件及 2 次工具执行，包含结构化结果和 SDK Token 用量。
- `logs --follow` 完整回放 340 条运行事件，观察到 ended 后退出；前一次真实运行
  已在 Agent 运行期间验证持续跟随，见 [前次证据](evidence/pr1-ee7d97b.json)。
- 固定 SHA 的 Worktree 保持干净。没有执行开发、GitHub 写入、PR 审查或自动合并。

可核查的版本、SHA、上下文哈希、工具命令、Token 用量、隔离结果、日志哈希及完整结构化结果
见 [证据 JSON](evidence/pr1-4199f97.json)。完整 SQLite、上下文、SDK 会话和脱敏 JSONL
保留在本次环境的 `/tmp/gongcao-pr1-acceptance-4199f97`，认证文件不提交到仓库。

```bash
uv run gongcao --state-dir /tmp/gongcao-pr1-acceptance-4199f97 status 1
uv run gongcao --state-dir /tmp/gongcao-pr1-acceptance-4199f97 inspect 1
uv run gongcao --state-dir /tmp/gongcao-pr1-acceptance-4199f97 logs 1
```

这些证据满足 PR1 的真实单 Agent 基础验收。PR2 的真实 Issue→PR→审查→修订→验证链路，
以及 PR3 的崩溃/结果不明恢复演练，仍是后续独立交付的验收条件。
