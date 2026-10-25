# QA 工程验收（Issue #13 / PR #17）

后续 PR 审查修订的固定实现为 `c479d72`，验证与失败/单项重跑记录见
[PR #17 审查修订](pr17-review-followup.md)。本文件保留下面 `3c3357c` 的历史验收。

2026-10-25 的分支验收通过。实现固定为
`3c3357cc4413e647fcc78b672a47604cd2ac6f68`，场景版本 2；目标仓库
`simonjiao/gongcao` 的 `main` 固定为
`35ca3609a5c84bd15ed37729a3ecb6563584c455`。使用全新独立克隆安装和运行，
没有复用历史验收脚本或其运行目录。完整结构化摘要见
[qa-3c3357c.json](evidence/qa-3c3357c.json)，运行说明见 [qa/README.md](../qa/README.md)。

这是 QA 分支的验收。**#1 / #13 仍保持开放**：QA 合并后，还须在最终 `main`
固定 SHA 上重新完成集成验收。下述记录不能代替该项最终验收。

## 可复现入口

```bash
git clone git@github.com:simonjiao/gongcao.git gongcao-qa
cd gongcao-qa
git checkout 3c3357cc4413e647fcc78b672a47604cd2ac6f68
uv sync --locked
uv run python -m qa check --offline
uv run python -m qa check --real --repo simonjiao/gongcao
uv run python -m qa run cancel loop recover --jobs 2 --real \
  --repo simonjiao/gongcao --model gpt-6.1-sol --cleanup
# 使用本次命令实际输出的 batch / Run ID：
uv run python -m qa verify-batch BATCH_ID --require-isolation
uv run python -m qa verify RUN_ID
```

准备 Linux/WSL、Python 3.12+、uv、Git、gh、Bubblewrap 及本人模型/GitHub 授权。
检查会实际启动正式 CLI、验证锁定依赖和 OS 沙箱；真实环境检查验证目标仓库权限及 SDK
账户可用性。真正模型执行由下面的 SDK 运行事实证明。默认 CI 不创建远端对象，不使用模型密钥。

## 完整真实批次

批次 `7c81464fa0ec4a67bad79c9fefcbd2c5` 的三个场景均通过，清理均成功。
每个 Run 有独立 clone、SQLite、日志、动态夹具、Issue、控制器分支和资源清单。

| 场景 / Run 前缀 | Issue / PR | 结果 |
| --- | --- | --- |
| cancel / `7c81464fa0ec` | [#30](https://github.com/simonjiao/gongcao/issues/30) / 无 PR | 真实 SDK 命令后取消，确认进程停止，无发布操作，已清理 |
| loop / `942e0369a8f3` | [#29](https://github.com/simonjiao/gongcao/issues/29) / [#32](https://github.com/simonjiao/gongcao/pull/32) | 缺失门禁阻断、独立审查退回、修订、检查/真实检查/CI、待人工合并、重复无新增副作用 |
| recover / `a24c47c8cc8b` | [#31](https://github.com/simonjiao/gongcao/issues/31) / [#33](https://github.com/simonjiao/gongcao/pull/33) | 相同完整闭环，加真实 COMMENT 中断及 `serve --once` 对账 |

UTC 02:24:26 前两个 Run 开始。取消 Run 在 UTC 02:24:52 清理并释放名额，第三个
Run 随后启动；另一个 Run 持续正常执行。批次于 UTC 02:33:51 完成。
`verify-batch --require-isolation` 独立确认 `peak_runs=2`、`queued=true`、
`real_model_overlap=true`、`cancel_cleanup_isolated=true`。15 个 SDK Thread ID 全部不同，
各自的 Run ID、时间、上下文/日志摘要、配置与源文件哈希均记录在 JSON 中。

正常闭环的初稿 SHA 为 `e7e713ba427b8954ffe07a20d89055ddcb5ef244`，
修订 SHA 为 `64419c084b3f690870dd8613bf9035f4e5669fd0`。
恢复闭环的初稿 SHA 为 `d70c0c1e9ce85f1ecddebc2761359564d3625f12`，
修订 SHA 为 `b49daf213d776d095733318a4e26d398ebccda7c`。
两条闭环均实际由 reviewer 给出 `revise`，修订后重新审查；旧 SHA 的角色证据和检查产物
全部失效。独立、无凭据、只读沙箱检查初稿确为 `min(value, 100)` 的下界缺陷，
修订版通过八个负数/边界/区间值检查。差异均仅包含各自的两个夹具文件。

四项项目检查（Ruff、format、mypy、pytest）及真实边界检查全部通过。
正常 Run 的本地检查为 146 tests + 8 subtests，恢复 Run 为 145 tests + 8 subtests；
数量不同来自模型生成测试的组织方式。绑定各自 PR/base/head 的 CI 分别为
[40154675784](https://github.com/simonjiao/gongcao/actions/runs/40154675784) 和
[40154701929](https://github.com/simonjiao/gongcao/actions/runs/40154701929)，均成功，
包含 checkout 日志、实际合并提交父节点及 base retarget 历史证明。
完成后重复原生任务没有新增 SDK Run、操作意图或 GitHub 评论。

## 恢复事实及边界

恢复场景在真实 COMMENT 已被观察到、尚未写入本地 `operation_result` 时 SIGKILL
控制器。操作 `a053ebd00e1cd05dbf2174d3933ffe9afe3ef00590a973c5853e451e62f399a8`
先为 `pending`，`serve --once` 启动对账后为 `succeeded`；前后都指向同一真实评审
`5641173660`，正文哈希、commit ID、操作身份及响应均一致，没有重发评论。
独立核验也检查恢复后最终唯一 COMMENT 及旧证据失效。

这是控制器/远端写入的真实恢复，不声称中断过真实 SDK 开发会话。质量检查中断、
detached 子进程及协议故障仍分别由 `tests/test_stability.py` 的 OS/协议替身回归覆盖；
这些测试没有冒充真实端到端运行。并发限制仅在单个 QA 批次进程内有效。

## 清理和失败记录

完成前两条 PR 曾达到 `mergeable/completed`；归档后 #32 / #33 均关闭、未合并。
三个 Issue 全部关闭，专用分支均不存在，原 clone/worktree 和生产模型认证副本已删除，
无活动子进程或租约。SQLite、脱敏日志、上下文和清单保留在配置的数据目录。
GitHub `main` 仍为 `35ca360`；没有合并测试 PR 或写入主分支。

此前失败尝试单独保留，未计入本批通过结果：

- `2ff3ce5`：创建 Issue 后列表未立即确认结果，按 unknown 停止；只读对账后清理
  #18–#20，没有重发创建请求。随后改为保存编号查询提示，再验证具体 Issue，并仅重试读取。
- `7018c0e`：正式 CLI 入口写错，注册失败；#21–#23 自动清理，没有 SDK 运行。
  随后增加实际 CLI 启动的离线探针和集成测试。
- `8172d03`：正常 Run 的格式修订过早补齐算法，不满足独立审查练习，因此显式取消并清理
  #25 / #27；取消 Run #24 和恢复 Run #26 / #28 仍独立完成并清理。该批整体为失败。
  场景 v2 明确区分技术修正与独立 reviewer 退回，保留严格判定后再完成上面的新批次。

## QA 自身质量

Ruff、format、严格 mypy、离线检查和 QA 自身 23 项回归通过。
固定实现 `3c3357c` 的
[CI 40154096080](https://github.com/simonjiao/gongcao/actions/runs/40154096080)
在 Python 3.12 / 3.13 均通过全部 167 项测试（pytest 启用 Gongcao 和 QA 的 beartype）。
Standards 与 Spec 双轴审查的实现阻塞项均已修复并复核为 0；证据与文档继续参与收尾审查。
生产状态机未改变；QA 包、类型检查范围和默认离线 CI 通过 `pyproject.toml` / `uv.lock`
及现有工作流管理。
