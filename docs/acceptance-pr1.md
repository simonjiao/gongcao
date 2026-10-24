# PR1 验收记录

本轮实现、测试、审查与真实开发验收基线：
`c5a83435809265ccb91e37a4e668ae108c4e9380`。
后续证据文档提交不改变此版本的生产代码。本轮完成
[PR #2 复核意见](https://github.com/simonjiao/gongcao/pull/2) 要求的精准修补；
范围仍为 Issue #1 的 PR1，PR2/PR3 继续独立交付。

## 自动化验证

- `uv lock --check`、Ruff 检查与格式、mypy：通过。
- `uv run pytest -q`：**61 passed**，18.73 秒；对 gongcao 启用 beartype。
- 新增 18 项回归：head 不变时 base SHA/目标分支/仓库变化，领取前及运行中版本变化，
  关闭、重新打开、取消优先和旧结果禁止推进。既有隔离、日志和错误路径继续通过。
- 固定实现 SHA 的 [GitHub Actions](https://github.com/simonjiao/gongcao/actions/runs/40101514511)：
  Python 3.12/3.13 锁定安装、Ruff、mypy、pytest + beartype 全部通过。

## 独立审查

- Standards：发现 1 项领取前快照竞态；通过事务内 expected_snapshot 核对及两项回归测试修复。
  `c5a8343` 已复核，原发现关闭，无剩余发现。
- Spec：本轮范围及快照竞态修复增量均无剩余发现；另行只读核对 SQLite、日志/上下文哈希、
  Worktree 和源目录，真实验收证据无阻塞问题。
- 两轴均为独立 Agent 静态审查，不代表 GitHub 独立账号批准。测试和真实验收单独记录。

## 真实 SDK 开发验收

2026-10-24，在以上实现 SHA 使用官方 Python SDK/Codex 0.163.0，
对临时可信本地测试仓库执行 Analyst → Developer。通过真实只读 GitHub API 登记 Issue #1；
角色配置将任务限定为测试夹具中的加法修复。夹具 origin 仅用于只读对象查找，夹具未推送。

夹具目标 SHA：`2987f9ccfb65460053f6234f7ed56d0c017e90f4`，与 Gongcao 实现 SHA 分开记录。
原始 add 错将相加实现为相减；控制器先确认 3 项测试中 2 失败、1 通过。

| 角色 | Run | Thread | 耗时 / SDK 事件 |
| --- | --- | --- | --- |
| Analyst | `1fcd8cc5f5ce4fab97e85e1ce523847a` | `01a16e41-f1a7-7ad3-b87a-f60b2c63be99` | 17.080 秒 / 142 |
| Developer | `06b8cc63a0c849cd9d2e85a57c4dc152` | `01a16e42-37ac-7472-8ccb-1be68b77b411` | 32.519 秒 / 197 |

- 两个角色具有不同线程、Worktree、上下文哈希；开发仅接收已确认的分析结果。
- 每次启动前真实 Bubblewrap 探测通过：实际存在的宿主 GitHub/Codex 授权文件与源仓库不可读、
  外部目录不可写；分析工作区只读，开发工作区可写。
- Developer 在分配的 Worktree 中仅修改 calculator.py 一行，从 left - right 改为 left + right；
  其他受版本管理的文件哈希一致。Worktree 内创建 .venv，并执行以下命令：

  ```bash
  UV_CACHE_DIR=/tmp/pr1-uv-cache uv run --offline --locked --python /usr/bin/python3.12 python -m unittest discover -s tests -v
  ```

  SDK 工具事件记录 exit 0、3 tests / OK；控制器另行运行同一套 unittest，全部通过。
- 源目录全部工作文件的前后 SHA256 一致、Git 工作区干净、未创建源目录 .venv。
  控制器创建了预期的本地分支及 Worktree Git 元数据。
- logs --follow 在开发运行中启动，回放并跟随到 ended，共 202 条事件。
- 运行 completed，任务停在 pending_development / waiting_dependency，等待 PR2 门禁。
  Agent 的 git status 因 .git 刻意隐藏而返回 128；控制器独立核实固定 HEAD、精确补丁和源目录哈希。

版本、夹具完整文件与提交信息、角色配置、目标 SHA、Run/Thread、上下文/日志哈希、
权限探测、工具输出、Token 用量及结构化结果见
[证据 JSON](evidence/pr1-developer-c5a8343.json)。完整 SQLite、上下文、会话与脱敏日志
保留在 `/tmp/gongcao-pr1-developer-c5a8343`，认证内容不提交到仓库。

```bash
uv run gongcao --state-dir /tmp/gongcao-pr1-developer-c5a8343/state status 1
uv run gongcao --state-dir /tmp/gongcao-pr1-developer-c5a8343/state inspect 1
uv run gongcao --state-dir /tmp/gongcao-pr1-developer-c5a8343/state logs 1
```

## 使用边界与后续验收

必须使用 Linux + Bubblewrap；无法验证隔离则拒绝启动。首版仅面向可信任务代码：
沙箱内仍可读取专属模型认证副本且允许联网，不能宣称可安全执行任意不可信 PR 代码。
本次检查不替代目标仓库实际需要的检查，也不代表 PR2 的审查/修订/CI 或 PR3 的恢复链路。

本轮已补齐 PR1 新增复核项，可提交人工审查合并；父 Issue #1 保持开放。
此前 `4199f97` 的 [只读 Analyst 证据](evidence/pr1-4199f97.json) 与
`ee7d97b` 的 [实时日志跟随证据](evidence/pr1-ee7d97b.json) 仅保留为历史记录。
