# #91：阶段交付与阻塞恢复

`step` 在业务阶段和必要受控写入全部确认后才消费；Developer 的 `blocked/failed`
不会完成阶段。控制器等待进程与后代收束，在原任务租约内保存有来源证明的修改。

保存复用 `Controlled` 的 commit、意图、推送及回读。每个 Run 使用独立的
`gongcao/save-<task-hash>-<run-id>` 分支；提交带 Task URL、Run 和原始 target SHA。
无改动不创建空提交。保存不创建 PR、不改变已有 PR head、不构成质量通过。
分支更新使用确切远端 SHA 条件，正式发布仍要求快进和原有审查/验证门禁。

后续 Developer 的新 worktree 从逐一验证过的检查点提交接续。Run 记录 `source.sha`、
原始 `target_sha` 和来源 Run；任务 target/PR head 只有正式发布确认后才更新。
需求变化、保存分支被删除/移动、未知写入或未确认的进程清理不能通过 retry 绕过。
旧版本没有来源证明的未完成运行保留现场，不猜测其来源或自动采纳。

原 Issue 的授权操作员可新发 `/gongcao retry`。评论仍经白名单、不可编辑性、ID、
当前阶段/版本检查；控制器在同一租约内执行既有恢复对账与 retry 重置。
它延续未完成的 step/until/auto 权限，不恢复 SDK 旧会话，不跳过任何门禁。
retry 评论不附带需求修改；需求变更须重新核验和授权。

正常暂停、阻塞、失败都在返回前尝试更新并回读原有唯一状态评论；前台与后台共用
状态写入锁及持久 PATCH 意图。网络失败保留 dirty/intent/error，不能宣称交接成功，
未知结果只读对账、不盲目重发。状态区分会话结束、业务阶段、成果提交、Agent 自报
检查与控制器验收，列出缺少的材料和可用的下一步。

沙箱仍隐藏 `.git` 和宿主凭据。上下文由控制器提供已核实的原始 SHA 与 checkout SHA；
Agent 不应将隐藏 `.git` 当作宿主 Git 损坏。原版/r1 包或 Release 元数据缺失时，
依赖这些材料的检查是 `NOT_RUN`，其余工作可继续，不能据此跳过验收。

模型配置默认 `gpt-6.1-sol` / `xhigh`，示例见 `gongcao.example.yaml`。配置分别记录来源。
SDK `thread/start` 显式设置模型和 `model_reasoning_effort`，核对响应，`turn/start`
再次传入 `model` / `effort`。模型目录用于支持性检查，真实推理失败仍按失败记录；
不将目录可见当作模型调用成功。协议依据：[Codex App Server](https://learn.chatgpt.com/docs/app-server)。

SQLite v5 只增加 Run `details`，升级保留历史会话和未知操作，不回填旧模型/强度。
测试包括 v4 升级/重启、旧版本升级，以及真实 Git/worktree/OS 沙箱下的完整离线链路。
`qa/checkpoint_fixture.py` 是明确的 SDK 替身，不是真实模型验收；真实验证须显式 `--real`，
使用独立状态目录与 QA 资源，不启动第二个 serve，不触碰 AirDB #307 及现有运行实例。
