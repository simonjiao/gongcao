# Gongcao

Gongcao 是单机运行、状态机驱动的本地 Agent 调度器。任务由 CLI 显式登记，
GitHub 是 Issue、PR、Commit、Review、CI 和合并事实的权威来源。

实现计划与验收边界见 [Issue #1](https://github.com/simonjiao/gongcao/issues/1)。

当前交付 **PR1：可运行基础**。支持显式登记、只读同步、Codex 分析/本地开发、
Worktree 与真实 OS 沙箱隔离，以及状态/日志/取消。GitHub 工作闭环与恢复能力分属 PR2/PR3。

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
```

命令返回 JSON；任务编号由 register 返回，示例中的 1 需替换为实际编号。
run 在前台执行一次当前阶段。可在另一个终端观察日志或取消；无新日志不会触发超时判断，
只有配置中的绝对执行期限会停止任务。

分析完成后任务进入 pending_development/queued，可再次 run 启动新的开发会话。
开发完成后保留本地分支和 Worktree，停在 waiting_dependency，等待 PR2 的远端门禁。
GitHub PR head、base SHA/目标分支或请求正文/标题变化会使旧证据失效。
关闭的对象进入 needs_human，重新打开也不会自动恢复；旧结果不能继续推进。
PR1 尚无人工恢复命令，核对后可用新的专属 state-dir 显式登记以开始新任务，保留原记录；不要改数据库。
Issue 的代码基线固定为登记时的本地 HEAD，
未提交修改不会进入 Agent 上下文。PR 使用 GitHub head SHA。

默认本地数据目录是 `~/.local/state/gongcao`，可通过 `--state-dir PATH` 或
`GONGCAO_STATE_DIR` 指定。目录包含 SQLite、结构化日志、上下文、SDK 会话和 Worktree；
请使用专属目录。隔离边界、停止条件和后续能力见 [PR1 说明](docs/pr1.md)。
