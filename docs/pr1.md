# PR1 范围与验收

来源：[Issue #1](https://github.com/simonjiao/gongcao/issues/1)。本次仅交付 PR1。

| 要求 | 实现与证据 |
| --- | --- |
| 项目、配置、pytest、最小 CI | pyproject.toml、uv.lock、YAML 角色配置、GitHub Actions |
| CLI 显式登记单个 Issue/PR | register 校验 URL 和本地 origin；幂等登记；sync 只查询登记对象 |
| SQLite 状态转换 | WAL；阶段与执行状态分列；事务领取；版本变化使旧证据失效 |
| Codex 单 Agent 独立上下文 | 官方 openai-codex SDK；每次全新 thread、独立 HOME 和 CODEX_HOME |
| 首次写入使用 Worktree | controller 先创建固定 SHA 的 Worktree；开发使用独立本地分支 |
| 可追溯上下文 | Issue/PR 快照、PR base→head Diff、固定 SHA 的 AGENTS.md、角色配置、已确认分析与上下文哈希 |
| 权限隔离 | Bubblewrap 新根目录、用户/PID/挂载命名空间；真实访问探测；失败禁止启动 |
| 日志与运行记录 | SDK 事件、工具输出、错误、结束时间、耗时、SDK 可提供的 Token 用量 |
| status / logs --follow / inspect / cancel | 本地 CLI；取消停止整个 Agent 进程组，结果不能覆盖取消 |

分析的结构化结果只允许推进到待开发。开发输出保留在分配的 Worktree，执行状态
进入 waiting_dependency；PR、独立审查、测试/CI 和合并证据门禁由 PR2 补全。
没有自动轮询守护进程或自动重试；PR1 由用户显式调用 sync/run，避免提前引入 PR3 调度器。

## 隔离边界

- Linux + Bubblewrap 是本版运行条件，不能验证命名空间和挂载权限时没有无沙箱回退。
- 宿主 HOME、GitHub CLI 授权文件、SSH agent、Git credential helper 配置、宿主 /proc
  和源仓库 .git 均不可见。Agent 环境清空后仅保留显式参数与无认证的联网代理配置。
- 仅挂载只读系统运行时、只读 Gongcao 代码、角色权限下的 Worktree，以及专属运行 HOME。
  /tmp 和专属 HOME 是 Agent 的临时/会话存储；根文件系统只读。
- 分析/审查/验证的工作区只读，只有开发角色允许写入分配的 Worktree；权限不能通过 YAML 更改。
- Agent 使用 OpenAI 专用认证副本，不读取宿主认证目录，不导入宿主 Codex 配置、MCP 或技能。
  副本仅允许 Codex 认证字段。它不是 GitHub 写凭据；本版应用没有任何 GitHub 写操作。
- 网络保持可用以访问模型服务。宿主 IPC/socket 目录和宿主进程不挂载。
  仅传递无认证的 HTTP_PROXY/HTTPS_PROXY/NO_PROXY，带用户名或密码的代理配置会拒绝启动。
- uv 二进制作为锁定的运行依赖提供，只读挂载到 /tools/uv，开发角色可以在分配的
  Worktree 中创建自己的环境并运行 uv 检查，不能访问宿主安装的全局配置和授权。
- 日志对已知凭据、常见 token、Bearer 和敏感字段脱敏。每次运行保留最多两个
  max_log_bytes 大小的日志段与 1000 条 SQLite 事件摘要。会话/Worktree 由操作人保留并清理。

## 自动化测试与真实验收

两类证据分别记录。pytest 的 SDK 协议测试使用替代 worker、真实 Bubblewrap 和
真实 Git Worktree，不能声称它们完成了真实模型调用或 GitHub 端到端验收。
真实模型与只读 GitHub 验收记录见 [acceptance-pr1.md](acceptance-pr1.md)。

PR1 不演练远端写入、自动合并或发布。SDK 流中断、输出错误、目标版本不符或探测失败
都不能判定成功；目标不符需要核对。SIGINT/SIGTERM 和 cancel 有明确终态。
SIGKILL/宿主崩溃后的租约核对和恢复属于 PR3：此时保留 running 记录，不自动重放，
需要操作人核对进程、工作区和远端事实，不能直接修改数据库来重新领取。
