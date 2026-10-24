# 第二阶段验收记录（GitHub PR #4）

[基础阶段 PR #2](https://github.com/simonjiao/gongcao/pull/2) 已合并；
本记录对应 [Issue #1 的第二阶段 / PR #4](https://github.com/simonjiao/gongcao/pull/4)。
第三阶段的调度、租约和重启恢复继续独立交付，父 Issue 保持开放。

最终 Python 生产代码：`a5a36718abe9e5df15e997a0fed7887ad0c481f1`。
验收记录与实测示例配置随本记录提交，不改变该 Python 实现；实际质量配置摘要和策略哈希单独记录。
执行契约、配置和边界见 [第二阶段说明](pr2.md)。

## 自动化与审查

- uv 锁文件、Ruff 检查及格式、mypy：通过；pytest 启用 beartype。
- 本地 Python 3.12.3：116 passed，70.70 秒。
- [固定实现 SHA 的 CI](https://github.com/simonjiao/gongcao/actions/runs/40116385617)：
  Python 3.12.15 / 3.13.16 各通过 116 项测试，分别为 38.69 / 53.91 秒。
  两份完整 job 日志未发现 ResourceWarning、unraisable 或 Event loop is closed。
- 自动化覆盖真实 Worktree/Bubblewrap、本地 bare Git 推送、取消与版本竞态、未知写入不重放、
  SQLite 0→1 升级/再次打开、质量配置变更、CI 的 PR/base/head/retarget 绑定、输出脱敏边界。
  SDK/GitHub 协议替身测试与下述真实验收分别记录。
- Standards：发现均已修复并复核，剩余 0 项。
- Spec：发现均已修复并复核，剩余 0 项。
  两项均为独立 Agent 审查，不代表 GitHub 正式独立账号批准。

## 真实 GitHub 与 SDK 链路

2026-10-25（上海时间），用固定 Python 实现完成
[专用 Issue #11](https://github.com/simonjiao/gongcao/issues/11) →
[测试 PR #12](https://github.com/simonjiao/gongcao/pull/12) 的完整前台链路。
夹具仅新增 acceptance_fixture.py 与 tests/test_acceptance_fixture.py；首轮有意遗漏下界，
独立审查实际发现负数处理及边界测试缺陷并退回，控制器提交修订后重新审查。

- base：`36aab6cffbc64999bf3af21e853b7165bb4634c0`（main）。
- 首轮目标：`86601757f2a1fdc10af26d58872ea5563a10610d`。
- 最终目标：`437f02c51d0e392c4094201296dc26b9ea3f8bed`，与 Gongcao 实现 SHA 分开记录。
- 质量策略哈希：`fca8be7391be389d04ad6f97aec70d250a294b9d355e152c04be3585809d2d85`。
- YAML 文件 SHA256：`929270ecbf151a7c404ce10bdf44b9ceadd95115081f91a90910e1336d8ab77d`。

| 角色 | Run | Thread |
| --- | --- | --- |
| 分析 | `73146419bd5140bcb07f26211b7c2f5e` | `01a16f00-cd1b-7702-bf08-8778e4c75d14` |
| 首轮开发 | `dc2c9fcbc1624dd4bbf8946b968d68c0` | `01a16f01-3264-78f1-90e7-b435782c52cb` |
| 审查退回 | `da9c154e305e407cb3a592df00707f0e` | `01a16f02-9dc9-7bb3-8e68-cad950c9a333` |
| 修订 | `0363419932fc4047878af74727f318f7` | `01a16f03-2358-7943-8097-685c61811699` |
| 再次审查 | `8ca7da7b1b474df4b90852d8eff005da` | `01a16f04-7c75-7c83-aa70-3577e6db965f` |
| 独立验证 | `c6c8aab3e75e496293588046bb541ca5` | `01a16f05-231a-7b12-8eac-074d50a7c89c` |

六次运行分别创建线程、上下文和 Worktree，实际验证角色写权限及宿主凭据隔离。
新提交使前四次运行与旧 checks 失效，最终审查/验证仅绑定最终目标。
首轮四项完整项目检查通过（pytest 72 项），仍被独立审查退回；修订后的四项检查全部重新通过
（pytest 74 项、9 个 subtests，21.35 秒），没有沿用首轮的通过结果。
必要真实检查覆盖 -500、-1、0、1、99、100、101、500，exit 0。

[最终目标 CI](https://github.com/simonjiao/gongcao/actions/runs/40117505267) 的 Python 3.12/3.13
各通过 74 项测试、9 个 subtests。job 日志中的 PR #12 merge ref 实际 checkout 为
`fd8f0ccd60556300afa02ce6a417e055a374d36d`，GitHub Commit API 确认父节点正是上述 base/head。
步骤元数据为空，证明明确使用“成功 job + checkout 日志”路径；完整 timeline 没有 retarget 事件。
相同实现的 Issue #9 演练另有 CI 未完成时等待的快照，目标及来源在证据中分别标明。

控制器确认非草稿、当前 head、MERGEABLE/CLEAN 后停在 mergeable / completed。
本夹具仓库没有要求正式批准，reviewDecision 为空；两条真实评审都为 COMMENTED，commit_id 分别
对应首轮和最终目标，没有发送 APPROVE。正式批准缺失时阻断另由自动化覆盖。
再次执行没有新模型 Run，六项受控操作数量不变，未重复推送、创建 PR 或发布评审。

源仓库全部跟踪文件的前后 SHA256 一致，工作区干净；真实 CLI 的 stderr 均为空。
[结构化证据](evidence/pr2-a5a3671.json) 保存配置、检查输出、隔离结果、GitHub 事实、操作记录、
上下文/日志哈希及可取得的 Token 用量。完整私有原始数据保留在
`/tmp/gongcao-stage2-acceptance-final`，不提交认证内容。

上述状态为清理前的验收事实。保存并复核后，测试 PR #12 已关闭且未合并，Issue #11 已关闭；
main 没有接收夹具代码。实现 PR #4 与父 Issue #1 保持开放。

## 真实演练暴露的问题

以下轮次保留为失败或安全阻断证据，不能计为通过；没有直接修改数据库绕过门禁。

| 测试对象 | 结果与修复 |
| --- | --- |
| Issue #3 / PR #5 | 分支名中的 task- 被误认为密钥前缀，推送未确认，进入待核对。修复脱敏边界后再次执行没有新模型运行或写操作，仍保留待核对；测试 PR 关闭未合并。 |
| Issue #3 / PR #6 | 本地 unittest 通过，但 pytest 无法隐式导入根目录夹具；CI 阻断。补充绑定版本的失败日志，后续夹具显式用 importlib 加载，测试 PR 关闭未合并。 |
| Issue #7 / PR #8 | CI 成功但 GitHub job 的 steps 为空，严格门禁等待。仅对整体运行及 job 都成功的空步骤场景增加 checkout 日志证明，仍核验 PR merge ref、SHA、父节点及完整 retarget 历史；测试 PR 关闭未合并。 |
| Issue #9 / PR #10 | 本地配置仅含夹具 unittest，独立验证角色发现缺少目标仓库要求的四项完整检查，转待人工处理。补齐检查配置并实际验证后，从新的专用事项重新执行；旧任务状态保持，测试 PR 关闭未合并。 |

Gongcao 自身的 pytest 会启动嵌套沙箱，临时 HOME 和虚拟环境需放在 /tmp，避免路径重叠。
完整检查配置已实际通过 Ruff、格式、mypy 及目标仓库的 74 项测试；示例 YAML 使用相同设置。

失败或取消的工作流不能使用上述空步骤回退，也不能借其他成功 job 驱动修订。
日志先脱敏再截尾，超长检查输出整行省略，避免密钥前缀恰好被截掉。

## 使用边界

Linux + Bubblewrap、可信任务代码。Agent 沙箱仍有专用模型认证副本并允许联网；
宿主 GitHub/SSH 凭据仅供控制器，质量检查沙箱没有模型认证。
不能取得实际隔离或 CI 版本证明时等待，不把模型自述当作通过。
base 分支关联结合当前 ref 和完整 retarget 历史推断；事件读取失败或时间相等均不接受。

受控写入只包含提交、非 force 推送、草稿 PR、COMMENT 和 ready；没有合并或发布接口。
持久化 intent 不等于完整崩溃恢复，第三阶段实现租约、调度及重启核对。
