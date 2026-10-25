# 第三阶段验收（GitHub PR #14）

第二阶段已按用户授权在 [PR #4](https://github.com/simonjiao/gongcao/pull/4) 合并，
合并提交 `82eafb9a00f8fc06556539b73314791ecb76dfb9`。
本阶段的 Python 实现固定为 `c4c968a2778ac2e29eba25664936086468ae516a`；后续提交只整理文档和证据。
执行、恢复和保守阻断边界见 [第三阶段契约](stage3.md)。

## 自动化与独立审查

- uv 锁文件、Ruff/格式、mypy 通过；pytest 启用 beartype 和资源/未处理析构告警错误检查。
- 本地完整回归 144 项通过；新增 28 项可靠性测试。
- [固定实现 CI](https://github.com/simonjiao/gongcao/actions/runs/40144339417)：
  Python 3.12 / 3.13 各通过 144 项，分别为 45.95 / 54.94 秒；完整日志没有资源泄漏或事件循环关闭告警。
- 真实 OS 测试覆盖 SIGKILL、PID namespace 内 setsid 后代死亡、保留部分开发文件并用新线程/Worktree
  重试、清理不明的 setsid 逃逸后代继续阻断、并行开发互不污染源文件、资源墓碑/大小写别名互斥。
- 协议替身覆盖创建 PR 成功但本地尚未记录、未知操作不重放、错误 SHA 的完成结果恢复后仍失效、
  服务停止、依赖循环、重试预算、人工刷新基线和日志筛选；不能把这些替身用例称为真实 GitHub 验收。

Standards：3 项发现全部修复并复核，剩余 0。重点为错误 SHA 证据复活、过早释放资源和误计重试。
Spec：3 项发现全部修复并复核，剩余 0。重点为逃逸后代清理不明、错误 SHA 证据和大小写资源别名。
两项均为独立 Agent 审查，不是 GitHub 平台的独立账号批准。

## 真实 SDK / GitHub 与恢复

2026-10-25（上海时间），在 [专用 Issue #15](https://github.com/simonjiao/gongcao/issues/15) /
[测试 PR #16](https://github.com/simonjiao/gongcao/pull/16) 验证。只新增两个可信夹具文件，main 不接收测试代码。
真实模型完成分析、开发、独立审查退回、修订、重新审查与验证；固定 head 的旧证据失效。

- base：`82eafb9a00f8fc06556539b73314791ecb76dfb9`。
- 首轮目标：`6df689f37831c867bdf381d61a60cafdecd769a0`；最终目标：
  `ed5f9295fd462f45bb6ebbdcd5e416bd37199ede`，与 Gongcao 实现 SHA 分开记录。
- 实际配置文件 SHA256：`0d3c4b1e33d230b92d0c10b361e8bafa44c259d2d6b29b115fb7a48c608aba8e`。
- 策略哈希：`30984ffa9ddcf30e31f1016220d534365a58c1edad429b49eefa560416808116`。

| 角色 | Run | Thread |
| --- | --- | --- |
| 分析 | `cc0a50c44a874228a06c93064bd109dd` | `01a17053-0601-76a1-832a-1849b7c7c418` |
| 初次开发 | `638a0f9cada54c60a3b969ca58509e81` | `01a17053-5c00-7d62-a630-3db83c58ae92` |
| 审查退回 | `1a03d38de65041a09eca5779b9e1f514` | `01a17055-7c09-7810-9835-a62156100764` |
| 修订 | `293c0f4e10b74535a8ad1004d7d6b0d2` | `01a17055-f1b4-7e11-be8c-39066af41ab3` |
| 首次审查通过 | `5614fa869d3f4d7f8392d241454f02ac` | `01a17057-7a7e-7ec0-b811-63952c37f31c` |
| 首次验证 | `1d87353fdb594442a2e049ff43fa150d` | `01a17058-1438-7781-b65c-46ec4d20e058` |
| 人工重试后的审查 | `9d1e0312c6744297b392ba72a8bbb3a3` | `01a1705c-2ebc-7a63-9201-46b5f7daaeaf` |
| 自动恢复后的验证 | `e6ec37ef0d3b41f3ae5680308284296b` | `01a1705e-6816-75d2-8128-400f3ea82582` |

八次真实运行使用独立线程、上下文及 Worktree，宿主权限隔离均有实际探测。只保留最后的当前版本
审查/验证资格；人工 retry 已使旧检查及模型评审证据失效，没有修改数据库绕过状态。

第一次自动故障检查点在质量检查阶段：确认控制器身份和活动 PID 沙箱后发送 SIGKILL。
`recover` 验证旧执行退出、上下文、工作区、租约及远端事实，恢复为 pending_review / queued。
随后在新质量工作区重新执行四项完整检查，当前检查时间晚于中断，没有复用被打断的检查。
其中 pytest 为 120 passed、9 个 subtests，39.65 秒；必要真实检查的八个边界输入全部通过。

第二次故障发生在 COMMENT 的 HTTP 写入已经成功且读取确认、SQLite intent 尚为 pending 时。
`serve --once --concurrency 2` 启动后自动只读对账，将同一 intent 记为 succeeded；前后 GitHub
评审 ID 和正文完全一致，没有重复发布该评审。完成独立验证后再次达到 mergeable / completed。
最终七项受控操作全部成功，重复轮询没有新增模型运行或远端操作。

实际中断点是“质量执行”和“COMMENT 成功后记账前”。原计划的开发期人工检查窗口未命中，
当时没有发送信号；PR 创建结果丢失和模型中途退出分别由前述协议测试/真实 OS 测试覆盖。
不将本轮说成真实中断了 SDK 开发会话，八次真实模型运行都正常完成。

[最终目标 CI](https://github.com/simonjiao/gongcao/actions/runs/40144612093) 成功。
checkout 为 `95361cb589f9875ff4a30bcaff631b12d5d00a1f`，父节点由 GitHub API 证明恰为上述 base/head，
步骤成功、PR merge ref 与完整 retarget 历史均有证据。非草稿、MERGEABLE/CLEAN 和当前 head 由控制器核验。
此测试仓库正式 reviewDecision 为空；所有评审均是 COMMENTED，没有发送 APPROVE。

源仓库全部跟踪文件前后哈希一致、工作区干净。保存清理前事实后，测试 PR #16 已关闭且未合并，
Issue #15 已关闭。当前“可合并”是清理前的验收记录；实现 PR #14 与父 Issue #1 仍保持开放。

[结构化证据](evidence/stage3-c4c968a.json) 保存配置、上下文/日志哈希、Token 用量、隔离结果、
故障检查点、intent 前后值、真实评审、当前门禁和源文件哈希。私有原始数据保留在
`/tmp/gongcao-stage3-acceptance-c4c968a`，认证内容不提交。

## 使用边界与规模

Linux + Bubblewrap、可信任务代码、同一 state-dir 协调。模型沙箱仍有专用模型认证并允许联网；
质量检查没有模型认证。未知启动窗口、泛用 helper 的中断、同次开机的后代清理不明保持待核对，
不强行解锁资源或重放写入。程序不自动合并或发布。

生产代码约 3,600 行，超过原先 2,900 行估算上限约 700 行，主要用于持久化进程身份、资源互斥、
只读对账和恢复门禁；未增加外部调度框架、服务、UI 或第二套项目管理系统。
