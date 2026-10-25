# PR #17 审查意见修订

对应 [review 5641367715](https://github.com/simonjiao/gongcao/pull/17#pullrequestreview-5641367715)，
基线为 `74c80f6b377076a114f05d330ddbdf4f460fb71b`；修订实现固定为
`c479d725d6e9c92418e909e196f7a692508d73f9`。范围为两项 QA 边界与账户探针说明，
生产状态机、租约逻辑、SQLite schema 及调度器均未改变。

## 取消边界

`cancel RUN_ID` 重新读取持久化终态，已结束的 Run 返回
`cancel_requested=false`。排队 Run 在进入场景前检查标记，smoke 同样遵守；
准备过程在创建远端 Issue 前、登记/启动原生执行前重新检查。异步实现校验返回后，
spawn 前也会再次检查。运行中的准备门禁及主循环通过统一原生执行入口转交正式 `cancel`。

用户取消使 QA Run 进入 `cancelled`，不算通过。`--cleanup` 继续通过原受控路径清理已创建
资源；未请求清理则保留清单和证据供 `cleanup RUN_ID`。异常进程/写入仍停在待核对。
这不改变专门 `cancel` 场景对一次真实 SDK 取消的预期判定。

## 清理边界

已登记 PR 按编号直接读取，列表滞后不能使其消失；404、错误分支或已确认发布尚未关联
任务时拒绝清理并交由现有恢复处理。关闭确认、删除分支前及清理结束均检查 PR 未合并，
并重新核对默认分支名称与固定 SHA。结束时再次确认远端关闭/分支删除事实，再归档
`cleanup-confirmed`，最后删除本地工作区并报告 `cleaned`。

已合并、主分支变化或其他矛盾观察进入 `needs_reconciliation`，保留本地文件及清单，
不重发未知写入。GitHub 状态按观察时刻核验；没有引入跨操作事务或锁服务。

## 探针边界

`model_authorized()` 是可信控制器上的 SDK 账户元数据检查，没有 Agent tools/turns。
白名单清除 GitHub/SSH 环境变量，保留 HOME/CODEX_HOME 的宿主文件系统访问以完成正常授权。
函数、README 及结果中的 `model_authorization_probe.filesystem_isolated=false` 均明确该点。
真实 Agent 的隔离仍由生产 Sandbox 的实际 OS 探测证明。

## 定向及 CI 验证

`uv run pytest -q tests/test_qa.py tests/test_qa_review.py`：42 项通过，其中本轮新增 19 项。
覆盖第三个排队 loop/smoke 取消后不进入准备/Issue/SDK、五种已结束状态取消不误报、
准备阶段三个取消窗口、准备中转交真实原生 cancel CLI、实现校验中的取消、关闭确认前被合并、
清理结束时被合并、主分支变化、列表遗漏已知 PR、PR 404 及发布/关联未完成。
竞争注入使用离线 GitHub/执行协议替身，没有真的合并测试 PR，不冒充模型端到端证据。

Ruff、format、严格 mypy、离线环境检查通过。固定实现的
[CI 40160780065](https://github.com/simonjiao/gongcao/actions/runs/40160780065)
在 Python 3.12 / 3.13 分别通过全部 186 项测试；pytest 对 `gongcao` 与 `qa` 启用 beartype。
双轴代码复核剩余阻塞均为 0。

## 受影响真实复测

首个新批次 `b57b127a35ca452d8aeb56b2452f83a3` 按 `cancel loop recover --jobs 2 --real --cleanup`
执行。取消 Run #34 通过并清理，恢复 Run #36 / PR #38 通过并清理。正常 Run #35 / PR #37
因目标仓库既有 `test_heartbeat_renews_and_late_results_require_the_original_owner` 在
0.15 秒 TTL 的 CI 用例中出现 `CancelledError` 而失败；对应
[CI 40161131263](https://github.com/simonjiao/gongcao/actions/runs/40161131263)
的 Python 3.12 失败，3.13 通过。模型未改无关文件，控制器在“无改动”处停止；
该批整体保持失败，原始记录保留，PR #37 已关闭未合并并完成清理。

同一固定实现仅重跑失败的正常场景：Run `ee9de5cd2aee4913a1463b2ffc9645b2`、
Issue #39 / PR #40 通过；独立审查退回、修订、真实边界检查、
[绑定 SHA 的 CI 40161718598](https://github.com/simonjiao/gongcao/actions/runs/40161718598)、
validator 和重复执行核验均通过。`qa verify` 与单项 `verify-batch` 复核通过，
PR #40 已关闭未合并，专用分支及本地工作区清理完成。

本次固定实现的取消、恢复及正常场景各自均有通过记录；首个批次整体仍为失败，
单项重跑批次为通过，两份清单分别保留。首批还证明两个真实 SDK Run 重叠、第三个排队，
失败 Run 的清理未影响恢复 Run 完成。所有本轮资源已清理，没有合并测试 PR。
目标 `main` 仍为 `35ca3609a5c84bd15ed37729a3ecb6563584c455`。

完整的来源哈希、各 Run/Thread、关闭未合并/固定主分支确认、失败与重跑记录见
[pr17-review-c479d72.json](evidence/pr17-review-c479d72.json)。持久化清单中的账户探针描述
因字段名含 `authorization` 被现有脱敏器整体遮盖；摘要中的无敏感边界字段取自同 SHA 的
独立 `qa check --real` 输出，未放宽脱敏规则。历史 [3c3357c 验收](acceptance-qa.md)
保留，和本次修订验证分别标识。

#13 / #1 继续 Open；合并后最终 `main` 的集成验收仍单独进行。
