# 项目私有 E2E 环境配置模板
# 复制为 ~/.gongcao/e2e/<owner>__<repo>.md（例如 ~/.gongcao/e2e/simonjiao__airdb.md）
# 该文件只保存在本机 ~/.gongcao/e2e/，不会提交到 GitHub；codex-e2e-loop.sh 会自动读取并注入 Prompt。

## 目标验收环境
- Docker / 远端验收主机：`<填写连接方式，例如本机直连 docker / docker context use zapto / ssh zapto>`
- 首选验收入口：`<例如优先按仓库 qa/README.md 使用 ./qa/env.sh，或按 qa/dind/README.md 使用 qa/dind/run.py>`
- 已有基线 `QA_ROOT`：`<例如 /home/simon/.local/state/workspace-qa（已含 base 基线时优先复用）>`

## Windows 原生浏览器驱动配置（如仓库需要 Edge Guest 验收）
- `QA_WINDOWS_NODE`：`<例如 C:\Program Files\nodejs\node.exe>`
- `QA_PLAYWRIGHT`：`<例如 C:\Users\simon\AppData\Local\.../@playwright/test>`
- `QA_BROWSER_PARENT`：`<例如 C:\Users\simon\AppData\Local\Temp\qa-browser>`
- WSL 发行版名称（`distribution`）：`<例如 Ubuntu>`

## 清理要求
- 验收结束后必须按仓库规范 `stop`/`destroy` 本次拉起的临时测试实例与浏览器进程（严禁执行全局 `docker prune`）。
- 原始截图、服务端日志和报告汇总写入外层指定的 `artifacts` 目录（注意脱敏，勿保存 `secrets.json` 或明文口令）。

## 快速 Blocked 条件（满足任一条即直接返回 verdict=blocked，不要长时间重试）
- 目标 Docker daemon / 远端 SSH 主机不可达
- 缺少必需的基线镜像、Windows Node 或 Playwright 依赖
- 验收依赖的外部数据库/服务未启动且当前权限不允许自动拉起
