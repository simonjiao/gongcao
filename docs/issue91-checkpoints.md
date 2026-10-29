# #91：阶段交付与阻塞恢复

`step` 在业务阶段和必要受控写入全部确认后才消费；Developer 的 `blocked/failed`
不会完成阶段。控制器等待进程与后代收束，在原任务租约内保存有来源证明的修改。

保存复用 `Controlled` 的 commit、意图、推送及回读。每个 Run 使用独立的
`gongcao/save-<task-hash>-<run-id>` 分支；提交带 Task URL、Run 和原始 target SHA。
无改动不创建空提交。保存不创建 PR、不改变已有 PR head、不构成质量通过。
分支更新使用确切远端 SHA 条件，正式发布仍要求快进和原有审查/验证门禁。
`pause` 可保存已收束的成果；`cancel` 保留本地现场，取消后不再发起提交或推送。
提交与保存边界重新检查取消标记/状态；已发出的未知写入仍保留意图供对账。

后续 Developer 的新 worktree 从逐一验证过的检查点提交接续。Run 记录 `source.sha`、
原始 `target_sha` 和来源 Run；任务 target/PR head 只有正式发布确认后才更新。
需求变化、保存分支被删除/移动、未知写入或未确认的进程清理不能通过 retry 绕过。
旧版本没有来源证明的未完成运行保留现场，不猜测其来源或自动采纳。

原 Issue 的授权操作员可新发 `/gongcao retry`。评论仍经白名单、不可编辑性、ID、
当前阶段/版本检查；控制器在同一租约内执行既有恢复对账与 retry 重置。
它延续未完成的 step/until/auto 权限，不恢复 SDK 旧会话，不跳过任何门禁。
最终评论核验、较旧指令替代、retry 重置和模型策略记录在同一写事务内完成。
仅模型/强度变更时，新的 retry 可在已有角色提示词摘要一致的前提下采用新配置；
角色配置变化或缺少旧来源证明仍须对账。历史会话参数保持原样。
retry 评论不附带需求修改；需求变更须重新核验和授权。

正常暂停、阻塞、失败都在返回前尝试更新并回读原有唯一状态评论；前台与后台共用
状态写入锁及持久 PATCH 意图。网络失败保留 dirty/intent/error，不能宣称交接成功，
未知结果只读对账、不盲目重发。每轮到期只尝试一次，指数退避最多 300 秒，
记录跨重启保留；不会因达到三次失败而永久停止，网络恢复后可继续同步/回读。
状态同时展示当前 Run 的保存状态和同版本最近已确认的检查点及来源 Run，
retry 无新修改再次阻塞时保留成果入口，版本变化后不沿用旧入口。
状态区分会话结束、业务阶段、成果提交、Agent 自报
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

## PR #94 本轮 review 修复范围

三项独立风险分别由现有边界处理：取消复用 `save_guard` 与受控写入的再次核验；
状态恢复复用持久退避、唯一评论锁及 PATCH 回读；成果入口从已有 Run 保存记录
选取当前基线的最近确认项。没有新增 Stage、数据表、状态机或兼容路径。

测试复用现有真实 Git/worktree/OS 沙箱夹具及 GitHub/SDK 替身：取消时机与暂停
对照、保存意图之后取消、连续读取失败/响应丢失跨重启恢复、二次阻塞和版本变化。
本轮不修改 SDK 参数链路，不重复真实模型验收；固定 SHA 的受影响回归、全量
本地质量检查和复审结果记录在 [PR #94](https://github.com/simonjiao/gongcao/pull/94)。

## 已有验收记录

需求依据为 #91 正文 SHA-256
`416e1f97346f83dda0172aed30f6239ff25bf66e800aa7da56b78ca05f10b85d`。

- 固定实现 `4c2c0489d9f2415d8a07cc12378f855c61f71699`，本地 Python 3.12.3：
  `uv run ruff check .`、`uv run ruff format --check .`、`uv run mypy`、
  `uv run pytest -q` 全部通过（322 passed，341.49 秒）。
- 同一实现的 `uv run python -m qa check --offline` 通过；真实 OS 检查确认
  宿主凭据、宿主仓库、外部写入均隔离，质量检查环境也保持隔离。
- Standards / Spec 独立复审无剩余阻断。全部验证在本机进行，不依赖 GitHub CI。
- 真实定向验收绑定 `8766580ca27acaa702de96549258e611ab5fbd48`：
  [QA #92 的结果](https://github.com/simonjiao/gongcao/issues/92#issuecomment-6486697924)，
  Run `98609bd6e20f4680bad879d8f143aab1`，三次新 SDK 会话均确认
  `gpt-6.1-sol` / `xhigh`。首次 Developer blocked 后实际 commit/push/回读，
  GitHub retry 创建新会话接续检查点，真实 draft PR 到达 review 入口暂停。
  [PR #93](https://github.com/simonjiao/gongcao/pull/93) 与 QA Issue 已关闭，未合并；
  正式工作分支已删除，检查点分支保留作证据。
- 该真实任务采用手工登记，未声称验证自动发现/自动状态发布，也未执行 review 后的
  业务质量验收。完整状态交接由离线 E2E 覆盖。后续指令事务与模型参数恢复修订采用
  离线回归和最终全量测试，未将旧真实结果追记为最新实现的真实运行。

可共享的会话、提交链、资源清理和私有原始归档哈希见
[证据索引](evidence/issue91-directed.json)。AirDB #307 的现有 worktree、阻塞状态和
正在运行的实例未修改或重启；没有启动第二个 serve。本变更尚未部署到该实例。
