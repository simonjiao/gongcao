# PR2 范围与执行契约

来源：[Issue #1](https://github.com/simonjiao/gongcao/issues/1)。PR1 已在 PR #2 合并。
本 PR 实现显式登记任务的前台闭环；PR3 的租约、并发调度与重启恢复保持独立。

每个模型角色使用固定 SHA 的独立 Worktree/上下文和会话；审查与验证只读。
开发只得到已确认分析或当前版本的修订发现，审查不继承开发会话。
模型报告只是候选结论，控制器必须另外满足代码、检查、CI 和 GitHub 保护事实。

| 阶段 | 必须满足的事实 |
| --- | --- |
| 分析 | 当前请求和 SHA 的结构化结果；已有 PR 直接进入审查，新 Issue 进入开发 |
| 开发/修订 | 当前版本完成记录、实际权限探测、独立工作区的控制器提交、受控推送与 PR 确认 |
| 审查 | 目标项目 checks 成功、独立只读会话结论；COMMENT 固定 commit_id，不提交 APPROVE |
| 修订 | 当前 SHA 的审查/检查失败依据；轮次上限，超限转人工 |
| 验证 | 必需 workflow 在目标分支/SHA 的最新 PR 运行成功、必要 real_checks 成功、只读验证结论 |
| 可合并 | 上述证据仍有效，PR 非草稿，GitHub mergeable/CLEAN 与正式 reviewDecision 均满足 |
| 已合并 | 只接受 GitHub 的 merged 事实；程序没有合并/发布接口 |

## 质量适配与证据

quality.checks、real_checks 是 argv 数组，不通过隐式 shell 执行；需要 shell 时项目须显式配置。
{python} 使用可用基础解释器，{sha} 展开目标 SHA。ci_workflows 使用 workflow 文件名。
检查在专属可写 Worktree 中运行，操作系统隔离与 Agent 相同，但不放入模型认证，也不继承
控制器 PYTHONPATH。输出仅保留两路各 20KB 尾部并标注截断，记录命令、退出码、时间及隔离结果。

CI 通过 GitHub Actions API 获取，按仓库、目标 SHA、head 分支、pull_request 事件及指定文件匹配，
选择最新运行；还须从成功 job 的 actions/checkout 步骤证明当前 PR merge ref 的实际 checkout SHA，
并通过 GitHub Commit API 核实其父提交恰为当前 base/head。缺少关联信息时等待，不能只凭 head 接纳
其他 PR 或旧 base 的 CI；pending 等待，失败进入修订，skipped 不能满足必需 workflow。
不把 SDK 自述当作 CI 或测试通过。正式审批需求由 GitHub reviewDecision/mergeStateStatus 核验，
同账号模型评审仅为 COMMENT。目标请求/head/base 改变使本地旧审查和检查失效，配置摘要变化也重建门禁。

inspect 返回检查证据、SHA、配置哈希、运行及受控写入记录；JSONL 继续保存 SDK 事件。
任务阶段、执行状态与修订次数分别持久化。阶段推进采用事务内快照核对，取消不能被迟到结果覆盖。

## 受控写入与重复请求

模型没有宿主 GitHub/SSH 凭据。控制器在每个目标版本实际探测隔离与仓库 origin，之后才允许
当前阶段对应的 push/create PR/COMMENT/ready。草稿 PR 与评审包含稳定操作标识。
推送不使用 force；目标分支出现意外提交即停止。只自动修订同仓库 PR，跨仓库写入转人工。

写入前提交 SQLite intent，再查询远端：已匹配则记录成功；未确认的已有意图不再次发送。
异常后先查询实际状态，可证明成功才接受，不能确认则待核对。阶段推进仍需新鲜目标版本。
每次前台推进有操作系统任务锁，避免同任务多个调用同时发送副作用；这不是 PR3 的调度/租约机制。

数据库模式 0→1 在事务内增加 PR 关联、修订次数、质量 artifacts 和 operations；保留旧运行、日志与状态。
升级/再次打开、旧 running 记录和未来模式拒绝均有定向测试。硬中断后的自动恢复不在本 PR 内。

## 验收边界

自动化使用真实 Git/Worktree/Bubblewrap，远端 GitHub/SDK 协议可用替身；不能当作真实端到端验收。
最终还须在固定实现 SHA 的专用测试事项中走通真实创建 PR、审查退回、再次提交、旧证据失效及门禁阻断，
并分别记录实现 SHA、目标代码 SHA、GitHub/CI 事实与运行证据；不自动合并测试 PR。
