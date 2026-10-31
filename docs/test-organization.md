# 测试职责与覆盖

对应 [Issue #80](https://github.com/simonjiao/gongcao/issues/80)，基线
`bb395c572b2ba84fadabac32ee54110d2d583bcf`（已含 #107）。只整理现有测试、夹具与文档；
新增场景为 0，生产模块只改说明。历史文档中的旧路径按下表查找当前职责。

公共 pytest 夹具由 `tests/conftest.py` 注入；纯工具显式从 `tests/_support/` 导入。
GitHub 协议替身、沙箱 Worker、QA Run、CLI 和任务准备工具分别归位，测试不互相导入。
生产模块在夹具执行时导入，保持 pytest-beartype 在测试收集前安装的类型检查。
离线命令共用一个只读 checkout，各测试的 state、gate 和 QA 数据仍独立。

| 原位置 | 当前职责 |
| --- | --- |
| test_pr2 | test_workflow、test_delivery、test_remote_writes、test_schema、test_github_api、test_quality_execution、test_config |
| test_stability | test_store、test_scheduler、test_recovery、test_schema、test_events |
| test_inputs / test_jobs | test_config、test_github_api、test_cli、test_store、test_scheduler、test_qa_execution |
| test_quality | test_quality_plan、test_quality_execution、test_archive |
| test_qa / test_qa_review | test_qa_execution、test_qa_resources、test_qa_evidence |
| test_state / test_repo_root | test_store / test_repository_preparation |

先完成不删用例的迁移：223 个函数、403 个收集实例，忽略路径后 ID/参数逐项相同，
AST 比对测试体与参数（排除导入位置）无变化。随后仅合并下列重复项：

| 删除项 | 保留/替代断言及理由 |
| --- | --- |
| test_policy_change_can_publish_new_same_sha_review | test_workflow 的 test_policy_change_rebuilds_review_and_validation_at_same_sha 合并两条策略变更完整链；保留同 SHA、旧 Reviewer/Validator 失效、第三条新评审与 MERGEABLE/COMPLETED 断言 |
| test_target_change_invalidates_quality_artifacts | test_store 的 test_pr_base_change_invalidates_evidence_with_unchanged_head 同为 Store.sync 版本失效边界，补入原 quality-results 不可复用断言；原有 base SHA/ref/repository 和在途/已完成负例保留 |
| test_invalid_quality_policy_is_rejected 的四个参数实例 | test_config 的 test_invalid_policy_cannot_grant_writes_or_legacy_quality 在同一 Config.load 边界保留三个旧 quality 字段、负 max_revisions、只读角色提权、负 timeout 全部拒绝；合并 YAML 文件准备，无新增参数排列 |

最终 220 个函数、397 个收集实例；减少 3 个函数、6 个实例，新增测试函数/场景为 0。
不同执行边界不作为重复删除，关键风险与原始用例关系如下（未列删除的断言保留）：

| 风险 | 保留覆盖（tests/ 下） |
| --- | --- |
| Schema v0/v1/v2–3/v4、未来版本拒绝和重复启动 | test_schema：原 test_pr2、test_stability、test_control、test_checkpoints 的独立升级/拒绝用例；v0 按 completed/running 参数保留 |
| 租约、容量、旧 owner 迟到写入与分支占用 | test_store：原 test_stability 的 six lease/alias cases；test_scheduler 保留依赖环、并发 Worktree、容量不消耗重试预算 |
| SHA/来源、取消并发和终态保护 | test_store 保留原 test_state 全部用例；test_runner、test_control、test_checkpoints 的取消/来源/授权负例不变 |
| 实际 OS 权限、宿主秘密/网络隔离、目标源码与污染检查 | test_sandbox、test_processes 不变；test_quality_execution 保留实际 Bubblewrap 检查；不是提示词或环境变量替代 |
| 本地 bare Git、交付唯一性与验收缺项（#107） | test_delivery 的 test_delivery_write_boundary_and_restart_preserve_completed_developer[acceptance_blocked] 保留 blocked+true、单 PR、NOT_RUN、后续检查阻断；test_incomplete_developer_report_cannot_deliver 保留全部四个负例 |
| Review/Validation 与需求变化门禁（#107） | test_delivery 保留全部请求变更窗口、安全负例、交付中断后旧上下文拒绝；test_workflow 保留独立评审/修订与正式批准缺失门禁 |
| 未知写入与重启 | test_remote_writes 的 test_ambiguous_write_queries_remote_and_never_replays 全部六个参数；test_recovery 保留 SIGKILL、活进程/逃逸后代、精确 SHA、PR 成功但未本地确认等原 test_stability 用例 |
| 追加 POST、历史不覆盖、未知对账、旧 PATCH 只读、取消与纠错（#107） | test_discovery 保留九个测试函数及原有参数/断言；另两项按职责迁至 test_config（发现配置）和 test_qa_evidence（发现 QA 证据）；特别保留 test_filter_dedupe_backlog_status_and_cross_state_lock 与 test_refresh_only_current_status_without_scanning_and_respects_owner_lock |
| CLI/本地 Git/OS 链（#107） | test_control_cli、test_discovery_cli 不变；test_checkpoints 仅迁出升级测试与改夹具导入 |
| QA 取消/排队、证据、归属与清理 | test_qa_execution、test_qa_evidence、test_qa_resources 保留原 test_qa/test_qa_review 全部函数和参数；Discovery QA 证据核对移入 test_qa_evidence |

收集清单、前后全量日志及迁移/规模统计保存在本次执行的本地证据中，结果与固定 SHA 见 PR。
验收命令为 Ruff check/format、mypy、全量 pytest 和 `python -m qa check --offline`。
本地 Git、Bubblewrap 和 CLI 使用实际执行；GitHub/模型运输仍是离线替身，真实远端验收 NOT_RUN。

The [#55 assertion/parameter audit](test-qa-audit.md) records retained internal risks and related real QA boundaries.
