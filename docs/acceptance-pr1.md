# PR1 验收记录

当前实现、审查、测试与真实 SDK 验收基线：
`42d4b6c30d14c7324e3dd324bc2f95fc95fe8153`。
后续证据文档提交不改变已验收生产代码。本轮处理
[PR #2 最新复核](https://github.com/simonjiao/gongcao/pull/2) 中 Python 3.12 子进程收尾告警，
范围保持在 Issue #1 的 PR1。

## 子进程问题定位与修复

旧 CI 的告警位置在 remote-read-failure 测试附近，但析构时间不能确定泄漏来自该测试。
在独立脚本中用“父进程退出，继承 stdout/stderr 的子进程继续运行”稳定复现完全相同的
BaseSubprocessTransport.__del__ / Event loop is closed；原始 4 项回归全部失败。

对照脚本分别加载 c1b582d 与当前实现，各启动并关闭事件循环 20 次：

| 指标 | c1b582d | 42d4b6c |
| --- | --- | --- |
| 两个输出管道均已 EOF | 0/20 | 20/20 |
| Event loop is closed | 20 | 0 |
| ResourceWarning | 140 | 0 |

修复取消/join 管道读者、进程组停止、分块排空 stdout/stderr、stdin.wait_closed 的完整顺序。
returncode 不能代替管道释放；[Python 3.12 文档](https://docs.python.org/3.12/library/asyncio-subprocess.html)
分别说明了进程等待、读取到 EOF 和关闭 stdin 的语义。

TERM 等待 3 秒，必要时 KILL 后再等 1 秒。若另建会话的后代仍持有管道，关闭本地 transport，
最终等待最多 1 秒并报告 CleanupError，不声称已终止逃逸后代。紧急关闭使用 CPython 的
私有 Process transport，仅在上述失败路径触发，并由 Python 3.12/3.13 CI 实际验证。
重复取消仍等待有限清理完成；Runner 在收尾后才提交终态，无法确认时保留原阶段并待核对。

## 自动化验证与独立审查

- uv 锁文件检查、Ruff 检查/格式、mypy：通过。
- Python 3.12.3：**70 passed**，28.69 秒；beartype 继续启用。
- 新增 9 项回归覆盖组长先退出、TERM 拒绝、命令取消/超时、脱离会话的后代、重复取消、
  Worker 立即退出/坏 JSON 加大量输出、收尾未确认时禁止推进。原有状态和隔离测试继续通过。
- pytest 将 ResourceWarning 和 PytestUnraisableExceptionWarning 作为错误，不屏蔽告警。
- [固定实现 SHA 的 CI](https://github.com/simonjiao/gongcao/actions/runs/40104037452)：
  Python **3.12.15 / 3.13.16** 各通过 70 项测试；两份完整 job 日志均无资源泄漏或循环关闭告警。
- Standards：1 项 KILL 后无界收尾发现，修复并复核关闭，无剩余发现。
- Spec：1 项相同收尾缺口，修复并复核关闭，无新回归或 PR2/PR3 范围扩张。
  两轴为独立 Agent 静态审查，不代表 GitHub 独立账号批准。

## 当前 SHA 的真实 SDK 验收

2026-10-24，用官方 Python SDK/Codex 0.163.0 对临时可信本地夹具重新执行 Analyst → Developer。
夹具目标 SHA 为 `2987f9ccfb65460053f6234f7ed56d0c017e90f4`，与 Gongcao 实现 SHA 分开记录。
真实 GitHub API 只读登记 Issue #1；夹具 origin 仅用于元数据查找，夹具未推送。

| 角色 | Run | Thread | 耗时 |
| --- | --- | --- | --- |
| Analyst | `dd1f6643c9084bf3baf245b0476c1393` | `01a16e61-1a22-7f41-97cd-c853e0f0a188` | 15.099 秒 |
| Developer | `c3e8fb19361b4034b2a4932ece6510ae` | `01a16e61-5907-70e3-9708-9176e391e339` | 22.114 秒 |

- 两个独立线程、Worktree、上下文哈希，开发仅接收已确认分析；角色权限与宿主授权隔离探测通过。
- Developer 仅将 calculator.py 的相减改为相加，保持测试及配置不变，在 Worktree 内执行
  uv 离线 unittest：3 tests / OK、exit 0；控制器独立检查同样通过。
- 源工作文件前后 SHA256 一致、Git 工作区干净、没有源目录 .venv；分支和 Worktree 元数据由控制器创建。
- 在 PYTHONWARNINGS=error::ResourceWarning 下执行真实 CLI；登记、分析、开发和 inspect 的 stderr 均为空。
- 最新 logs --follow 为完成后回放，共 196 条，观察到 ended；实时跟随已由前次 c5a8343 验收。
- 最终停在 pending_development / waiting_dependency。Agent 的 git status 因 .git 隐藏返回 128，
  固定 HEAD、精确补丁与源文件完整性由控制器核实。成功 uv 检查显式使用 /tmp 缓存。

[结构化证据](evidence/pr1-process-cleanup-42d4b6c.json) 包含原始复现脚本、红/绿对照、CI job 标识、
完整夹具、工具输出、上下文/日志哈希、Token 用量、源文件哈希及结构化结果。
完整本地运行数据保留在 `/tmp/gongcao-pr1-developer-42d4b6c`，认证内容不提交。

## 使用边界与后续

Linux + Bubblewrap 为前提；无法验证隔离时拒绝启动。首版仅运行可信任务代码：
沙箱内仍有可读模型认证副本并允许联网，不能宣称安全运行任意不可信 PR 代码。
本轮不实现 PR2 的远端闭环或 PR3 的完整进程树恢复；不确定回收安全停止，等待人工核对。

父 Issue #1 保持开放，PR1 交由人工决定合并。此前
[c5a8343 开发验收](evidence/pr1-developer-c5a8343.json)、
[4199f97 只读验收](evidence/pr1-4199f97.json) 和
[ee7d97b 实时日志](evidence/pr1-ee7d97b.json) 保留为历史记录。
