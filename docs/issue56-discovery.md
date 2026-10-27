# Issue #56：发现、领取和状态同步

最新状态（2026-10-27）：实现 `af363b8` 的双版本 CI 与完整真实 GitHub/Codex 验收通过，
归档复核通过，测试资源已安全清理。[结构化证据](evidence/discovery-af363b8.json)。
实现 PR：[#68](https://github.com/simonjiao/gongcao/pull/68)，待人工审查和合并。

需求来源：https://github.com/simonjiao/gongcao/issues/56 。基于已合并的 PR #66，
起点为 `221ff3f4afeb153e09d3096d08ef63f1f25e1b5e`。不包含 #67 的同秒评论时间优化。

## 文件级复用与估算

| 文件 | 复用边界 | 最初预计新增 |
| --- | --- | ---: |
| `config.py` | 保留质量策略；单独解析显式 discovery 来源，默认关闭 | 65–85 |
| `discovery.py`（新） | 复用 GitHub.pages、Store.register 和现有 API；意图、对账、单条状态评论、同机锁 | 350–460 |
| `store.py` | v3→v4 事务升级；领取记录、稳定 controller ID、任务变化触发待同步 | 35–50 |
| `recovery.py`、`workflow.py`、`remote.py` | 共享远端默认基线获取/刷新规则，保留所有执行与写入检查点 | 30–45 |
| `scheduler.py`、`cli.py` | 现有 jobs/租约/指令轮询；持续模式及时调度新发现任务，status 显示同步告警 | 40–50 |
| 内部及 CLI 测试 | GitHub/SQLite seam 与真实 CLI/OS 沙箱 | 200–310 |
| QA 适配 | 复用现有 Run、受控资源操作、六角色审查/修订和精确 SHA 验证 | 100–120 |

没有第二套业务阶段机、发布路径或服务。扫描与评论同步仅在现有 serve 生命周期内运行；
run/control 等入口持久保留待同步状态，下次 serve 对账后更新。

## 安全与恢复决定

- 以规范仓库/Issue URL 唯一保存本地领取记录。确认前不创建 tasks 行，不可能被现有调度器运行。
  评论 POST 前保存 attempted 和完整正文；中断后按稳定标记和评论 ID 唯一回读，并核验作者。
  未观察到已尝试写入时保留待核对原因，禁止重发。已经确认的领取在禁用发现后仍可恢复。
- 扫描前验证 origin，领取时读取真实远端默认分支并按需 fetch；不 checkout/reset 用户 HEAD。
  精确标签、PR、assignee、历史分配/关闭/重开、关联 PR、其他 Gongcao 标记均有保守过滤。
  无法推断的既有处理不从头执行；跳过原因记录到控制器日志。
- 同用户、同文件系统命名空间下，仓库哈希锁固定在 `/tmp/gongcao-claims-UID/`，
  不随 state-dir 或 HOME 改变。目录须为当前用户私有，文件拒绝符号链接。
  不删除锁文件，不抢占未知拥有者，不声称提供跨机原子领取。
- max_new_per_scan 同时约束每次新增和当前未终结的自动任务积压。暂停、人工作业和待合并 PR
  仍占积压额度，不占执行 jobs；取消或确认合并后释放积压额度。手工登记的任意历史任务均去重。
- 任务 stage/state/SHA/PR/control/原因变化由 SQLite trigger 在同一事务内标记 dirty；
  评论正文不含更新时间，因此静止状态不会按扫描重复 PATCH。写前观察、保存意图、写后回读。
  未确认 PATCH 先对账，不能以新正文覆盖旧未知意图。普通状态同步失败只告警并有界退避。
  同步器按 interval 独立读取无执行租约任务的生命周期，不依赖 copilot operators；
  已确认合并/关闭优先于基线检查，避免合并导致默认分支前进时覆盖终态。
- 未发布且无任何远端意图时，默认分支变化复用 retry(refresh_base) 的失效规则，
  原会话/工作区保留、旧证据失效、回到分析并等待新指示。已有 PR 或远端意图则待核对。
  Workflow 同步与每次 Controlled.before 都执行该检查，避免开发后到发布前的基线漂移。
- 初始策略仍由 #57 决定：互斥模式标签优先于来源 mode，默认为 step；冲突标签暂停。
  领取之后移除发现标签不取消任务；空 operators 禁止 GitHub 评论控制，本地 control 可继续。

## 差异化验证

内部测试覆盖筛选/分页复用、手工与自动去重、积压、跨 state-dir OS 锁、写后丢回复及中断、
未知写入不重放、状态幂等/作者核验、基线刷新与远端意图阻挡、403/429 退避。
旧 v1/v2/v3 数据库升级后保留历史/未知意图，并重复打开验证重启。

两个 CLI 场景使用真实子进程、SQLite、Git 和现有 OS 沙箱；仅外部 GitHub/模型协议替换：
单轮扫描→确认领取→单步暂停；持续 jobs=2 时观察两个 running、第三个 queued，
随后暂停全部任务并重启/禁用，核验没有重复评论、Agent 会话或 PR，用户 HEAD 保持不变。

真实 QA 的 discovery 场景创建两个可领取 Issue（auto/step）、一个无标签 Issue和两个临时标签，
仅在明确授权后运行。主任务沿用既有六角色、一次真实审查修订、完整项目检查和精确 PR CI 证明；
附加 step 任务只运行分析，并验证可信 pause 评论被消费。重复扫描核验任务、评论与 PR 幂等。
归档附加资源与主资源，逐一核验归属和未知意图后，复用 Run.action 清理。

QA 适配超出 Issue 的 80–160 行初估：新增三 Issue/两标签的持久归属与清理、连续 serve 观察、
评论唯一性和独立归档校验占主要增量。已将 Issue 创建扩展为同一受控 helper，复用既有资源操作
和六角色验证；没有复制质量检查或另建测试系统。内部定向测试超过 200 行，主要增量是共用
GitHub 协议夹具、归档验收反例和独立于 operators 的终态回归；CLI 用例在 120 行以内。
双版本可并行测试使用各自唯一的假仓库名，避免真实共享锁正确拦截彼此；没有替换锁路径或 OS 检查。
正式代码仍在 420–710 行估算范围内。
实际接口验收进一步补齐了领取已写入、尚未登记时的只读对账与清理：须精确回读作者、标记、ID
和已有意图正文才能记为已确认；不重发 POST，不登记任务，不启动 Agent。

## Standards

初审发现合并终态被基线前进覆盖、空 operators 的暂停任务缺少终态轮询两项问题；均已修复。
当前工作树复核：硬性违规 0、启发式异味 0。升级事务、真实 OS 锁、未知写入保留、取消 join
和普通同步错误隔离均保留。
CI 首启并发还复现 WAL 初始化竞争，Store 以状态目录内的 OS 锁串行初始化/升级；
持续 CLI 观察暴露协议夹具原地覆盖 JSON 的读取竞争，已复用现有 write_json 原子替换。

## Spec

初审发现上述两项状态同步缺陷，已补 workflow/publisher 两入口回归。
领取门禁、未知写入不重放、同机锁、调度及清理边界符合要求；修复后的最终复核剩余发现 0。

## 当前验收状态

- 正式代码基准提交：`af363b8084b32b62b7b84b758cf7d7e4a32cc0fc`。
  [CI 40467867638](https://github.com/simonjiao/gongcao/actions/runs/40467867638)
  在 Python 3.12/3.13 上均通过 locked sync、Ruff、format、mypy、实际 OS 离线 QA 与全量测试：
  分别 **266 passed / 91.89s**、**266 passed / 90.23s**。
- 本地修复后的状态/升级/CLI 定向回归 42 项通过；最终共享夹具和 jobs 回归 3.12 为 28 项通过，
  3.13 的实际 CLI 回归 3 项通过。本地离线 QA 验证宿主凭证、仓库、外部写入不可访问。
  真实接口修复后，3.12 的发现/CLI/QA 回归 38 项通过，3.13 的发现/CLI 回归 15 项通过。
- 双轴最终复核：Standards 0、Spec 0；初始化锁的补充审查 0。
- 用户明确授权后，真实 Run `25d018afb9d04bf9886a1a105a2f8d95` **passed + cleaned**，
  `qa verify` 重新核验所有归档摘要并通过。真实接口修复亦经两轴复核，无剩余发现。
- 不自动合并，不关闭 #56；功能分支证据供 PR 审查，主干保持 `221ff3f`。

相对基点的最终新增/删除（不含证据与使用文档）：正式 Python **+634/-59**，
内部测试 **+320/-7**，CLI 测试 **+116/-1**，QA 场景及适配 **+385/-22**，
合计 **+1455/-89**。正式代码在估算范围内；测试与 QA 超量原因见上述独立安全边界说明。

## 真实验收证据

来源标签独立领取 auto [Issue #72](https://github.com/simonjiao/gongcao/issues/72) 和 step
[Issue #73](https://github.com/simonjiao/gongcao/issues/73)，无标签的
[Issue #74](https://github.com/simonjiao/gongcao/issues/74) 未登记。两条自有状态评论 ID 为
`6436348010`、`6436353537`，重复扫描后仍各自唯一，待同步和未知意图均为空。
step 只运行一次分析并暂停；可信评论 `6436368631` 的 pause 指令有 consumed 审计记录。

auto 完成六个真实角色会话及一次独立审查修订，最终为 mergeable/completed。
初始 SHA `9c4a9881dc696600e916d3f644d521cdf3a8d52d` 的本地检查虽通过，独立审查仍拒绝其
预埋负数缺陷；修订 SHA `777d38e3072504a07a44538e3e00b113ae2de170` 的检查、复审、真实边界探针、
精确 SHA CI 和验证均通过。[测试 PR #75](https://github.com/simonjiao/gongcao/pull/75) 的
[CI 40468973813](https://github.com/simonjiao/gongcao/actions/runs/40468973813) 具有实际 checkout
日志及 base/head 双父提交证明；旧 SHA 被独立验收器拒绝。重复扫描和重复执行未增加角色会话、PR 或评审。

两轮质量沙箱的完整源码拷贝 tree 均与 GitHub 对应提交一致。目标测试仓库是固定 main `221ff3f`
加动态夹具，因此两轮为 251 项测试及 5/9 个 subtest；它与上面的实现分支 266 项 CI 分别记录。
所有 Run/Thread ID、SHA、来源 tree、归档摘要和清理确认均在结构化证据中。

验收后 72/73/74 三个 Issue 已关闭，PR #75 未合并后关闭，专用分支和两个临时标签已删除，
Run 的 clone/worktree 及模型认证副本已清理；日志、上下文和 SQLite 保留。默认分支未改变。

此前 Run `df2a1929323040a5a0d62d55a7b9da18` 在 `77405f1` 上因 GitHub 列表/详情的
`user.avatar_url` 差异而被作者对象整体比较拒绝，保持未登记且 **0 Agent**。停止后，使用修复版
只读核验评论 ID/作者/标记/正文，确认已存在的 POST，再清理 69/70/71 和其两个临时标签。
该 Run 保留 failed 历史，后续 cleaned=true；没有将其作为通过证据或重放评论写入。
