# #57 精简前风险清单与边界对照

实施依据：[专项审查](https://github.com/simonjiao/gongcao/issues/57#issuecomment-6431917940)。
固定起点 `3717d873c8e22aaaa86d67323b0c7f74df41ea9e`，比较基线
`f5c81118f8fbeef8b1b261e3fabe93f6dff9096d`。本清单先于集中精简编写。
只收敛重复校验、评论夹具和相邻重复读取，不调整业务阶段、租约或写入门禁。

## 逐测试决定与断言去向

下表名称均省略 `test_`；未注明迁移的断言保留在同名函数。

| 原函数 | 独立风险与决定 | 集中精简后的断言位置 |
| --- | --- | --- |
| until_is_a_forward_entry_checkpoint | 保留入口、倒退、修订入口和非法目标；合入已有 PR 的不可达目标 | 同名参数表，增加 PR 标识，复用目标断言 |
| steps_include_publication_revision_and_pending_ci | 保留五次阶段迁移、审查退修订、CI 等待不消费；暂停 run/serve 防越界只检查一次 | 同名；各阶段入口断言全部保留，重复暂停轮询移出循环 |
| pause_settles_agent_then_resumes_without_replaying | 保留运行中暂停与缓存恢复，保留真实 worker/worktree | 同名 |
| trusted_commands_bind_baseline_deduplicate_and_invalidate_feedback | 保留 API 身份、普通材料忽略、消费去重、重启、反馈输入、旧 SHA 及未知写入优先 | 同名，共用评论夹具 |
| initial_policy_is_consumed_once | 保留 discovery 默认 step、初始 until 标签与冲突、重复登记不重授 | 同名；手工默认 auto 已由 background_commands 的原断言覆盖 |
| schema_two_upgrade_preserves_intents_and_legacy_auto | 保留 v2→v3、两次重启、未知写入与旧 auto 兼容 | 同名；既有 v0/v1 升级用例保持 |
| execution_policy_changes_require_new_permission | 保留策略 hash 变化使授权失效 | 同名 |
| rejected_policy_change_cannot_reopen_terminal_or_blocked_work | 保留 merged / needs_human / cancelled 三类边界 | 同名三个参数项 |
| lost_lease_cannot_accept_feedback | 保留过期与替换 owner 两个负例，及任务/证据不被修改 | 同名两个参数项 |
| journaled_operation_settles_before_pause | 保留已登记操作确认后才暂停、无 pending 意图与租约泄漏 | 同名；不与其它暂停窗口合并 |
| remote_pause_is_read_after_agent_before_publication | 保留 Agent 完成至首次远端写入间的窗口 | 同名，共用评论及远端策略夹具 |
| unreachable_until_and_revoked_operator_cannot_authorize_work | 分开两个风险的组织，不删断言 | 不可达目标移入 until 参数表；撤权保留独立 operator_revocation 测试 |
| until_validates_the_stage_after_policy_rebuild | 保留策略重建后重新判断目标的历史缺陷 | 同名 |
| paused_poll_failure_preserves_sibling_execution | 保留暂停任务读失败与兄弟任务继续运行 | 同名 |
| background_commands_are_recorded_without_agent_lease_and_survive_restart | 保留读取无 observer/无额外执行租约、pending 持久化与阶段消费重启一致 | 同名；同时断言消费事务失败时阶段/运行/消费均回滚 |
| edited_and_conflicting_commands_pause_without_replay | 保留已授权评论改成普通文字撤回、指纹及冲突暂停 | 同名参数项，共用评论夹具 |
| conflict_is_independent_of_poll_batching | 与上一项合并组织，保留分批与同批的独立顺序 | edited_and_conflicting 的两种轮询参数；原冲突拒绝审计断言保留 |
| until_current_review_pauses_after_review_write_without_advancing | 保留审查写入完成后的精确入口竞争 | 同名，复用已到 review 的准备夹具 |
| step_received_during_failed_checks_stops_at_revision | 保留检查失败转修订前的单步消费 | 同名，复用 review 准备与评论夹具 |
| remote_pause_after_publish_keeps_confirmed_pr_and_sha | 保留纯 pause 与冲突两个发布完成窗口，确认 PR、新 SHA、已成功意图及无重复写入 | 同名两个参数项 |
| control_cli: offline_cli_preserves_task_pr_sha_and_evidence_through_control_modes | 保留实际多进程 CLI、持续 serve 唤醒、OS 沙箱、Git push、同任务/PR/SHA/证据及无重复写入 | 同名；仅共用 CLI argv，保留 qa/copilot_fixture 协议替身 |
| inputs: transient_github_read_retries_but_a_write_never_replays | 保留 GET 暂时性失败恢复、POST 一次发送 | 同名 |
| inputs: github_read_retry_is_bounded_and_never_retries_denied_access | 保留三次上限与权限拒绝不重试两个参数项 | 同名 |
| qa_review: copilot_wakeup_waits_for_lease_release_before_stopping_serve | 保留停止服务时机的独立真实 QA 回归 | 同名，不合入控制器测试 |
| qa_review: qa_pytest_snapshot_supports_git_clones_inside_real_quality_sandbox | 保留实际 OS 隔离中的完整 pytest/Git 克隆及源码 tree 一致 | 同名，不迁走或排除测试 |
| 新增：普通评论元数据更新 | 新增唯一小型定向回归：只增加评论及 updated_at，正文/SHA 不变不得误进人工/待核对 | safe 的版本守卫与既有分析证据；同一用例验证正文变化失效，既有用例保留 SHA 变化失效 |

既有 `test_pr2.py` 的全流程检查仍保留正式审查 COMMENT 次数、质量/CI 与旧 SHA 失效断言；
本次不改其它既有测试。不会以迁移测试至 QA 文件或删除安全参数项降低内部行数。

## 正式代码的重复路径及等效依据

| 路径 | 可集中收敛部分 | 必须保留的边界 |
| --- | --- | --- |
| collect → apply_pending → issue | 共用一份小型纯指令/版本校验规则；pending JSON 一次解码；复用审计写入 | collect 不改阶段；安全点再次核验 operator、SHA/需求/阶段；编辑与跨轮询冲突审计 |
| issue → 控制字段写回 | 在内存中合成最终控制数据和反馈基线，一次写入，减少读回/再保存 | 反馈失效在同一事务中完成，不复用旧结果 |
| revalidate → check_policy | 收敛同一次调用中的重复 task 读取、终态判断与 fence；保留校验顺序 | 先拒绝终态/失效租约，再核对撤权及策略，再到 checkpoint |
| run 入场 → execute 首次循环 | 将两份相邻入场逻辑合成循环内一份 sync→poll→revalidate→状态/依赖检查；run 仅对暂停任务提前轮询以唤醒 | 后续循环跨完整阶段，逐次重新检查依赖；Agent 前后、受控操作前后均保留实时检查 |
| poll → revalidate/checkpoint | 仅收敛无异步分界的连续校验；不取消网络/写入之后的检查 | collect 仍为独立 Context；后台监听不占 jobs；暂停任务先轮询再申请执行槽 |
| safe → Store.guard | 用业务版本/阶段检查后守卫当前快照，避免 updated_at 等评论元数据误失效 | 真正正文、目标 SHA、阶段及反馈基线变化仍拒绝；lease/人工/取消/合并优先 |
| Store.finish / transition / intent；Controlled.perform | 不作行数精简 | 阶段与消费同事务；纯暂停先收束已登记写入；未知结果不可重放 |

重复校验不是一律删除：后台接收与前台应用相隔异步时间，二次授权核验保留；
受控写入前有隔离验证等异步工作，前后检查点保留。只在同一快照、同一事务或未跨工作
边界时共享规则/结果。真实 QA 场景及历史四轮失败证据优先保留。

## 起点量化

| 分类 | 相对 main 新增/删除 | 主要文件 |
| --- | --- | --- |
| 正式代码 | +859 / −25 | control.py 582 行；Workflow 355；Scheduler 155 |
| 内部测试 | +823 / −4 | test_control.py 575；CLI E2E 143 |
| QA（含文档） | +449 / −11 | 真实评论、隔离副本与协议夹具均保留 |

起点完整 pytest 为 249 项，最近本地 Python 3.12/3.13 用时分别 238.20/241.74 秒；
远端固定 `3717d87` 的 push CI [40421518697](https://github.com/simonjiao/gongcao/actions/runs/40421518697) 成功。
正式代码约 650–750、内部新增约 450–550 行作为参考，达不到时按具体保留风险解释。
集中精简后再记录同口径行数、item 数量、耗时和断言去向；不为数字反复修改状态机。

## 集中精简结果

本轮只调整 `control.py`、`workflow.py` 和两个控制测试文件，QA 场景未修改。
同 main 比较的口径为 `git diff f5c8111 --numstat`，不把删除行抵扣新增行。

| 分类/文件 | 精简前 | 精简后 |
| --- | --- | --- |
| 正式代码增量 | +859 / −25 | +842 / −42 |
| 内部测试增量 | +823 / −4 | +725 / −4 |
| QA 增量 | +449 / −11 | +449 / −11 |
| control.py 总行数 | 582 | 556 |
| Workflow 总行数 | 355 | 347 |
| Scheduler 总行数 | 155 | 155 |
| test_control.py 总行数 | 575 | 493 |
| test_control_cli.py 总行数 | 143 | 127 |

热点 `issue` 从约 142 行收敛到 100，`apply_pending` 从约 80 到 71，`collect`
从约 80 到 67；共用纯指令规则、版本绑定和审计写入抵消了一部分净行数收益。
不再逐次 JSON 解码，不再在同一调用中重复读取和保存策略，也不再执行两份入场轮询。

参考的 650–750 / 450–550 新增行目标未达到，具体保留内容为：

- `control.py` 仍有独立的收集、应用、阶段消费和监听窗口；它们分别发生在后台读取、
  租约安全点、SQLite 迁移事务和等待 Agent 时，不能合成一次校验。
  `checkpoint` 的 45 行、`initialize` 的 40 行保留消费/升级兼容和标签冲突边界。
- 实际 CLI E2E 仍有 127 行；GitHub GET 失败/鉴权/写入不重放负例 37 行，
  QA 租约释放与沙箱 Git 克隆回归 63 行。这些 227 行均有不同协议或 OS 边界。
- `test_control.py` 的 493 行保留表中全部独立竞争窗口和参数负例，新增版本元数据
  回归及消费失败回滚断言；没有把它们移入 QA、改成纯 mock 或删掉安全参数。

定向控制及实际 CLI 测试：34 passed，40.77 秒；Ruff、format、mypy 通过。
离线 QA 的真实 OS 访问探测通过，确认宿主凭据/仓库不可读、工作区只读、外部不可写。

## Standards

未发现硬性标准违规，也未发现值得继续修改的明确代码异味。owner/expiry fence、
终态优先、应用时再次授权、阶段与消费同事务、未知意图与资源占用均保留。
`safe(current)` 先比对业务版本/阶段，再执行完整 Store.guard；实际 CLI、worktree、
Git push 和 OS 检查均保留。共享规则收敛了具体重复，未引入第二套工作流。
独立审查的小组回归为 10 passed。

## Spec

未发现精简引入的阻断缺陷或范围扩散。受理与消费的双重版本绑定、撤权、同秒冲突、
旧 SHA、终态保护均保留。Store 核心事务未删改，新增消费失败回滚断言；评论元数据
变化保留证据，真正正文变化使证据失效。Workflow 合并没有跨掉 Agent 或受控写入
安全点，已有 PR 反馈仍先失效旧证据，再按原流程重建分析和审查。

两轴结论：Standards 0 项，Spec 0 项；最终固定 SHA 的 CI 和完整真实 QA 单独记录。


完整本地矩阵：Python 3.12.3 为 250 passed（250.62 秒），3.13.13 为
250 passed（253.63 秒）；两版本 Ruff、format、mypy 全部通过。
精简前为 249 项（238.20 / 241.74 秒）；本轮新增 1 项元数据回归，其余参数合并
前后净数相同。两版本同时运行，耗时只作本次记录，不据此推断性能回归或提升。
