# Gongcao

Gongcao 是单机运行、状态机驱动的本地 Agent 调度器。任务由 CLI 显式登记，
GitHub 是 Issue、PR、Commit、Review、CI 和合并事实的权威来源。

实现计划与验收边界见 [Issue #1](https://github.com/simonjiao/gongcao/issues/1)。

基础阶段已在 [PR #2](https://github.com/simonjiao/gongcao/pull/2) 合并；
第二阶段已在 [PR #4：GitHub 工作闭环与质量门禁](https://github.com/simonjiao/gongcao/pull/4) 合并。
支持 Issue→开发/PR→独立审查/有限修订→项目检查、CI/真实验证→待人工合并。
第三阶段补充前台轮询、有限并发、依赖与安全恢复，见 [执行契约](docs/stage3.md)。

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

## 运行单个任务

先用 `gh auth login` 登录 GitHub。SDK 默认读取 `~/.codex/auth.json` 的模型认证，
也支持 `OPENAI_API_KEY`。首次使用可先运行 `codex login`，或在 YAML 中配置 auth_file。
Agent 不继承宿主 Codex 配置；可在 YAML 中显式指定可用的 model。
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
uv run gongcao serve --config gongcao.example.yaml --concurrency 2
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

YAML 的 quality 必须按目标仓库配置：checks 为命令参数列表，ci_workflows 为必须成功的
GitHub Actions workflow 文件名；需要真实验证时设置 require_real_checks 并提供 real_checks。
缺少配置会等待环境，不执行 GitHub 写入。示例文件中的 Ruff/mypy/pytest 只适用于 Gongcao。
检查使用独立 Worktree、没有模型认证的沙箱，不继承 Gongcao 的 Python 导入路径。

每个角色使用独立上下文/线程；审查只读。修订最多 max_revisions 次，超限转人工。
等待 CI 时可稍后再次 run；只读重新核验当前 SHA 的事实，不重复发布已确认的远端对象。
同身份 Agent 的 COMMENT 不算 GitHub 正式批准，GitHub 的保护规则仍必须满足。
GitHub PR head、base SHA/目标分支或请求正文/标题变化会使旧证据失效。
关闭的对象进入 needs_human，重新打开也不会自动恢复；旧结果不能继续推进。
recover 先核对进程、会话引用、工作区和远端事实；无法确认时仍待核对，不重放副作用。
retry 是显式人工重试，检查/审查证据重新建立，旧工作区保留；不要修改数据库绕过状态。
serve 启动时核对遗留执行，连续三次执行/环境失败后转人工处理，普通 CI 等待不计失败。
依赖须由 GitHub 确认已合并。未发布 Issue 基线过旧时，可用 retry --refresh-base 从当前默认分支重建计划；
仅显式 retry --reset-revisions 重置修订预算。未知启动/后代清理不明时不会只凭 PID 或日志静默恢复。
Issue 初始代码基线为登记时本地 HEAD；首次发布时须仍匹配远端默认分支。PR 使用 GitHub head SHA。
未提交修改不会进入初始上下文；开发内容仅在分配的 Worktree 中产生。

默认本地数据目录是 `~/.local/state/gongcao`，可通过 `--state-dir PATH` 或
`GONGCAO_STATE_DIR` 指定。目录包含 SQLite、结构化日志、上下文、SDK 会话和 Worktree；
请使用专属目录。inspect 包含按版本绑定的检查结果及远端写入意图/确认记录。
旧 SQLite 在事务内依次升级到模式版本 2；更高版本数据库会被拒绝打开，不静默降级。
运行边界见 [第一阶段说明](docs/pr1.md) 和 [第二阶段说明](docs/pr2.md)，
验证结果见 [第二阶段验收记录](docs/acceptance-pr2.md)。
