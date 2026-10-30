# Gongcao

Gongcao 是单机运行、状态机驱动的本地 Agent 调度器。任务可由 CLI 显式登记，或按配置发现领取，
GitHub 是 Issue、PR、Commit、Review、CI 和合并事实的权威来源。

实现计划与验收边界见 [Issue #1](https://github.com/simonjiao/gongcao/issues/1)。

基础阶段已在 [PR #2](https://github.com/simonjiao/gongcao/pull/2) 合并；
第二阶段已在 [PR #4：GitHub 工作闭环与质量门禁](https://github.com/simonjiao/gongcao/pull/4) 合并。
支持 Issue→开发/PR→独立审查/有限修订→项目检查、CI/真实验证→待人工合并。
第三阶段在 [PR #14](https://github.com/simonjiao/gongcao/pull/14) 补充前台轮询、有限并发、依赖与安全恢复，
见 [执行契约](docs/stage3.md) 和 [验收记录](docs/acceptance-stage3.md)。

## 安装与检查

需要 Linux、Python 3.12+、uv、Git、已登录的 GitHub CLI、Bubblewrap，以及 Codex 模型认证。
在 Ubuntu/WSL 中可通过 `sudo apt-get install bubblewrap` 安装 Bubblewrap。
首版仅面向可信任务代码：沙箱内仍有模型认证副本并允许联网，不能用它安全执行任意不可信 PR 代码。

```bash
uv sync --locked
uv run gongcao --help
uv run ruff check .
uv run ruff format --check .
uv run mypy
uv run pytest -q
```

`pyproject.toml` 管理项目、开发依赖和所有检查配置，`uv.lock` 固定版本。
Ruff 检查代码和格式，mypy 严格检查静态类型，pytest 执行行为测试并通过
[beartype](https://beartype.readthedocs.io/en/latest/api_claw/)
对 `gongcao` 函数启用运行时类型检查。CI 在 Python 3.12/3.13 上执行同样的检查。

本仓库的 GitHub Actions 仅手动触发，推送提交或更新 PR 不会自动运行 CI。
需要检查时，在 GitHub 的 **Actions → CI → Run workflow** 中选择待检查分支，
或执行 `gh workflow run ci.yml --repo simonjiao/gongcao --ref <branch>`。
新增工作流也应仅使用 `workflow_dispatch`。
调度器的 CI 门禁目前只接受绑定当前 PR/base/head 的 `pull_request` 运行；
手动运行不能满足该门禁，因此使用调度器处理本仓库任务时，必需的 CI 门禁会保持等待。

## 运行单个任务

先用 `gh auth login` 登录 GitHub。SDK 默认读取 `~/.codex/auth.json` 的模型认证，
也支持 `OPENAI_API_KEY`。首次使用可先运行 `codex login`，或在 YAML 中配置 auth_file。
Agent 不继承宿主 Codex 配置。项目默认 `model: gpt-6.1-sol`、
`reasoning_effort: xhigh`，两项均可在 YAML 显式覆盖，并显式传给 SDK。
启动时检查模型目录支持的强度，并核对 SDK 返回的实际模型/强度；不可用或发生路由回退时报错。
每次 Run 保留配置来源和 SDK 确认值，GitHub 状态显示该次会话的证据；历史缺失值不推断、不追记。
SDK 和随附 Codex 运行时已固定版本，无须 Node.js。

```bash
# 当前仓库须已有提交，origin 须匹配 URL。只登记这个对象，不自动领取其他 Issue。
uv run gongcao register https://github.com/OWNER/REPO/issues/1 --repo /path/to/repo
# PR 使用 https://github.com/OWNER/REPO/pull/NUMBER；只抓取该 PR 的确切 head。
uv run gongcao sync 1
uv run gongcao run 1 --config gongcao.example.yaml
uv run gongcao status 1
uv run gongcao inspect 1
uv run gongcao logs 1 --follow
uv run gongcao cancel 1

# 只轮询已登记的任务；最多 1–3 个并发，共享同一个 state-dir。
uv run gongcao serve --config gongcao.example.yaml --jobs 2
uv run gongcao serve --config gongcao.example.yaml --once
uv run gongcao depend 2 --on 1
uv run gongcao diagnose 2
uv run gongcao recover 2
uv run gongcao retry 2
uv run gongcao logs 2 --run RUN_ID --kind error --contains TEXT
```

命令返回 JSON；任务编号由 register 返回，示例中的 1 需替换为实际编号。
run 在前台推进已登记任务，直到外部依赖未满足、人工介入或可合并；不运行后台守护进程。
它会由控制器提交/推送分支、创建草稿 PR、发布 COMMENT 评审并转为可审查；不会合并或发布。
可在另一个终端观察日志或取消；没有新日志不代表超时，配置期限约束每次 Agent/检查执行。

验证计划按目标版本的 AGENTS.md、构建入口、Issue 和实际 PR 差异生成，不配置全局质量命令，
也不依赖 GitHub CI。每项记录 build/internal/e2e、入口、范围、必要性、原因和环境；缺少必需
入口或真实环境会阻断验收。普通检查在固定 SHA、无凭据 Bubblewrap 中执行。

`gongcao quality TASK` 查看计划；把输出保存后修改 items，用 `--plan FILE` 确认当前版本计划。
`--run` 执行普通检查；真实 QA 需明确选择 `--run --real --real-check INDEX --plan-hash HASH`，
且入口必须属于目标版本已有 qa/ 脚本。Agent 建议不是通过证据。
同 SHA 修改计划也会使旧检查及 Reviewer/Validator 结论失效。

`gongcao quality TASK --archive --real` 把当前执行结果追加到独立证据分支，并在 Issue/PR
记录固定 commit 链接；失败结果同样保留，原始日志/SQLite/会话留在本地。
详见 [#79 验证与归档](docs/validation-evidence.md)。

每个角色使用独立上下文/线程；审查只读。修订最多 max_revisions 次，超限转人工。
缺环境时可在补齐证据后再次 run，不重复发布已确认的远端对象。
同身份 Agent 的 COMMENT 不算 GitHub 正式批准，GitHub 的保护规则仍必须满足。
GitHub PR head、base SHA/目标分支或请求正文/标题变化会使旧证据失效。
关闭的对象进入 needs_human，重新打开也不会自动恢复；旧结果不能继续推进。
recover 先核对进程、会话引用、工作区和远端事实；无法确认时仍待核对，不重放副作用。
retry 是显式人工重试，检查/审查证据重新建立，旧工作区保留；不要修改数据库绕过状态。
serve 启动时核对遗留执行，连续三次执行/环境失败后转人工处理，外部依赖等待不计失败。
并行数统一使用 `--jobs`；正式 `serve` 取命令行显式值、YAML `scheduler.jobs`、默认 1
中优先级最高的一项，且只接受整数 1–3。旧选项 `--concurrency` 已移除。
同一 YAML 的 `qa.jobs` 只控制 QA 批次，默认 2，接受任意正整数；两类任务额度独立。
例如 `scheduler: {jobs: 2}` 和 `qa: {jobs: 3}` 可分别配置正式与 QA 并行数。
依赖须由 GitHub 确认已合并。未发布 Issue 基线过旧时，可用 retry --refresh-base 从当前默认分支重建计划；
仅显式 retry --reset-revisions 重置修订预算。未知启动/后代清理不明时不会只凭 PID 或日志静默恢复。
Issue 初始代码基线为登记时本地 HEAD；首次发布时须仍匹配远端默认分支。PR 使用 GitHub head SHA。
未提交修改不会进入初始上下文；开发内容仅在分配的 Worktree 中产生。

默认本地数据目录是 `~/.local/state/gongcao`，可通过 `--state-dir PATH` 或
`GONGCAO_STATE_DIR` 指定。目录包含 SQLite、结构化日志、上下文、SDK 会话和 Worktree；
请使用专属目录。inspect 包含按版本绑定的检查结果及远端写入意图/确认记录。
旧 SQLite 在事务内依次升级到模式版本 4；更高版本数据库会被拒绝打开，不静默降级。
运行边界见 [第一阶段说明](docs/pr1.md) 和 [第二阶段说明](docs/pr2.md)，
验证结果见 [第二阶段验收记录](docs/acceptance-pr2.md)。

## 自动发现与状态同步

在现有质量配置中加入以下来源，再执行 `gongcao serve --config gongcao.yaml`：

```yaml
discovery:
  enabled: true
  repo_root: /absolute/repositories
  interval_seconds: 60
  max_new_per_scan: 10
  sources:
    - repo: OWNER/REPO
      # path: /absolute/local/checkout  # 可选：覆盖 repo_root 推导的路径
      label: agent-ready
      mode: step
```

默认关闭发现。`agent-ready` 只允许发现与领取；默认 `step` 在完成一个阶段后等待指示，
来源显式配置 `auto` 才连续推进。互斥的 `gongcao:*` 模式标签优先于来源模式，
标签冲突会暂停。GitHub 评论控制还须配置下文的 `copilot.operators`，默认为空；
本地 `gongcao control` 始终可用。

未显式设置来源 `path` 时使用 `<repo_root>/<owner>/<repo>`；两者不能同时缺失。
路径必须为绝对路径，不允许 `.`/`..`、符号链接或不同仓库共用一个目录。
扫描前独立准备全部配置仓库，不受领取积压上限影响：缺失仓库由宿主通过现有
GitHub 授权 clone 到临时目录，校验 origin 后原子发布；已有目录仅校验，不覆盖、
不 pull、不改 HEAD。准备失败按现有有界退避重试，其他仓库仍可扫描。
历史任务保留原登记路径，不自动迁移；失效路径进入待核对/待处理。

`serve` 在支持 ANSI 的交互式终端（包括 SSH/WSL TTY）默认显示顶部任务概览和底部最近日志，
每秒按终端尺寸刷新。运行时长来自当前 Agent Run；最近事件仅表示本地已记录的活动，
检查阶段等未创建 Agent Run 的执行会明确显示时长未记录；没有事件时显示“暂无新事件”，
不推算完成百分比或判断卡死。日志保留最近 150 条，退出后回显。
`--no-tui`、`--once`、stderr 重定向或 `TERM=dumb` 使用普通日志：首次准备/扫描后输出
中文启动概览，随后输出阶段、结果、已确认 PR、阻塞/恢复等变化及约五分钟空闲心跳。
stdout 始终保持原有 JSON；UI 刷新不改变调度/远端轮询，详情可用 `status / inspect / logs --follow`。
SDK 原始输出、提示词及详细诊断继续保存在私有状态目录；`--state-dir` 与仓库根目录独立。

`serve --once` 扫描一次并完成一次调度周期，周期内仍遵守各任务的 step/until/auto 策略。
每轮新增数和未终结的自动领取积压均以 `max_new_per_scan` 为上限（1–100）。
已登记对象、PR、已分配给他人、历史处理或关联 PR、其他控制器标记均跳过并记录原因。
领取时核验 origin 并使用远端默认分支 SHA，只按需 fetch，不移动用户 checkout 的 HEAD。

控制器先保存领取意图，再创建和回读唯一状态评论，确认作者、标记、评论 ID 后才登记任务。
中断或写入结果不明时先对账；无法确认则保留记录并告警，禁止盲目重发或启动 Agent。
任务变更会持久标记待同步，`serve` 维护同一条评论；`status` 的 `status_sync` 显示同步状态。
普通进度同步失败不打断 Agent。停用发现只停止新领取，已领取任务继续调度、同步。

同用户、同文件系统命名空间内，以 `/tmp/gongcao-claims-UID/仓库哈希.lock` 跨 state-dir
互斥领取与状态发布。首版不支持无协调的多机抢单，GitHub 评论不提供跨主机原子锁。
默认分支变化时，未发布且没有远端意图的任务失效旧证据、刷新基线并等待新指示；
已有 PR 或远端意图则进入待核对。始终由 GitHub 确认终态，不自动合并或关闭 Issue。
设计、规模和验收记录见 [Issue #56 实施记录](docs/issue56-discovery.md)。

## 按指示推进

在已登记任务上设置持久策略，再运行 `run` 或 `serve`：

```bash
uv run gongcao control 1 --step --config gongcao.example.yaml
uv run gongcao run 1 --config gongcao.example.yaml
uv run gongcao control 1 --until review --config gongcao.example.yaml
uv run gongcao control 1 --auto --config gongcao.example.yaml
uv run gongcao control 1 --pause
```

`step` 完成当前一个业务阶段及其受控写入后，在下一阶段入口进入
`waiting_instruction`；审查退回修订也消耗一次授权。等待 CI 或依赖时授权保留。
`until development/review/validation` 在目标入口暂停，已到目标立即暂停，拒绝倒退；
`until mergeable` 完成现有验证门禁后等待人工合并。`auto` 推进到现有阻断或待人工合并。
已有 PR 的分析直接进入审查，因此拒绝不可达的 `until development`。
`pause` 持久请求在安全检查点停止，当前 Agent/写入先收束，结果不明仍待核对。
切换至 `step`、`until` 或 `auto` 恢复。本地 CLI 在执行中可请求 pause，其余本地切换需等待安全暂停。
`run` 不绕过暂停，暂停任务不占 `jobs`；`serve --once` 仍然只是一次调度周期。
`status/inspect` 提供阶段、状态、策略/目标、PR/SHA、等待原因及指令受理/消费记录。

手工登记默认 `auto`。可在首次 `register --config FILE` 时设置
`copilot.mode: step`，或用互斥的 `gongcao:step`、`gongcao:auto`、
`gongcao:until-review`、`gongcao:until-validation` 标签覆盖初始策略；冲突标签暂停。
标签只在首次登记消费，后续改标签或重复登记不会重新授权。供 #56 使用的
`Store.register(..., source="discovery")` 默认 `step`，显式 mode 才覆盖。

远端指令默认禁用。配置 `copilot.operators: [GITHUB_LOGIN]` 后，控制器只读取
原 Issue 的顶层评论：`/gongcao step`、`/gongcao until review`（亦支持其余确定目标）、
`/gongcao auto`、`/gongcao pause`、`/gongcao retry`。信任 API 返回的登录账户，不信任正文自报身份。
`retry` 用于同一版本的可恢复阻塞/失败：补齐原计划需要的材料后，新发一条仅含
`/gongcao retry` 的评论。编辑旧评论不能授权；需求/SHA 改变、未知写入或清理不明须先对账。
它继续尚未完成的阶段，创建新 SDK 会话，不重放已完成阶段，也不重置修订预算。
标签使用独立分页读取；后台评论读取不申请 jobs 或 Agent 租约。运行中收到的指令先登记为
pending，在下一安全点核验并应用；任务暂停时 serve 仍会读取评论并按授权唤醒。
普通评论和 PR Review 不作控制指令；编辑旧评论不能重新授权，请发新评论。
按评论 ID 持久去重，时间只供审计；同秒及首次读到的历史评论均按当前阶段、SHA 和需求基线核验。
待消费或仍有效的评论发生编辑、作者或内容指纹变化即失效，不重新受理；已拒绝、消费或替代
的历史指令保留原审计状态。多条冲突指令保守暂停。
待消费或仍授权后续执行的评论若从完整分页中缺失，控制器会按 ID 直读核验；403、404 或查询失败
保留待核对原因并在安全点暂停，禁止旧许可继续启动阶段或写入。404 不单独证明已删除。
对已开始的操作按原安全边界收束，不回滚已完成的工作；已终结任务不会重新激活。
请用新评论重新授权。待消费评论尚无法核对时，评论 ID 更新且通过操作者、阶段、SHA 和需求
基线核验的新指令，可在同一事务中替代旧待核对记录并生效；旧记录不会因恢复可见而重新执行。
未通过核验的新评论不能撤销旧待核对记录。本地 CLI 也可显式替代旧指令。
授权评论首行之后的补充要求作为注明来源的任务数据输入，并重建分析/审查证据。
外部变更请求、PR/SHA 或执行策略使显式旧授权失效，需重新指示；未知写入和人工门禁优先。
移出 `copilot.operators` 的操作者，其旧远端授权也会暂停并要求重新指示。
本功能不发现/领取 Issue、不发布状态评论、不自动合并；#56 负责发现与统一状态评论。
