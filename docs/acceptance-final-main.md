# Issue #1 / #13：最终 main 集成验收

## 固定主线与重建环境

本次在 PR #2、#4、#14、#17 均合并之后验证主线
`e5a6080c03ec4075c98503b9c4f435a9680a3b30`。从 GitHub 全新克隆 `main`，
detach 到此 SHA，在独立虚拟环境执行 `uv sync --locked`；实现克隆保持干净，
每个 QA Run 再创建独立目标 clone、SQLite、日志与资源清单。

```bash
git clone git@github.com:simonjiao/gongcao.git gongcao-final-main
cd gongcao-final-main
git checkout --detach e5a6080c03ec4075c98503b9c4f435a9680a3b30
uv sync --locked
uv run python -m qa check --offline
uv run python -m qa check --real --repo simonjiao/gongcao
uv run python -m qa run cancel loop recover --jobs 2 --real \
  --repo simonjiao/gongcao --model gpt-6.1-sol --cleanup
uv run python -m qa verify-batch BATCH_ID --require-isolation
uv run python -m qa verify RUN_ID
```

ID 使用实际命令输出。前置检查验证 Python 3.12.3、uv 0.11.33、SDK 0.163.0、
Git/gh/Bubblewrap 可用，锁定依赖一致；实际 OS 探测确认宿主凭据/仓库不可读及工作区只读。
账户元数据探针在可信控制器上运行，环境白名单不等同于文件系统隔离；真实 Agent 使用
生产 Sandbox。没有复制旧验收目录或人工操作脚本作为场景实现。

主线 SHA 的 [CI 40177872061](https://github.com/simonjiao/gongcao/actions/runs/40177872061)
为成功：Python 3.12 作业 `121122385572` 和 Python 3.13 作业 `121122385745`
均完成 Ruff、format、mypy、离线 QA 及全部 186 项测试（启用 beartype）。

## 批次和清理记录

首批 `902f1008fa06439588a321b0419b77cf` 保持失败。
正常 Run `c6e2037d0b0c417f81e997ca1d9b242c` 在独立 reviewer 完成之后，
因只读 GitHub Issue 请求返回 `EOF` 安全停止；该读取未被当作成功，也未放宽门禁。
整批已经失败后，剩余恢复 Run 被显式停止，记录原始失败/取消结果。
三个 Run 的资源全部受控清理，Issue #42–#44 关闭，测试 PR #45/#46 关闭且未合并，
专属分支和工作区移除。该批没有覆盖成通过。

第二批在同一 SHA 使用三个全新的 Run、目标 clone、远端对象与证据清单，继续执行完整
`cancel loop recover --jobs 2`。批次 `1760f724184e4eb89b108e940b81a1b7`
三个场景全部通过且清理成功：

| 场景 | QA Run | 测试对象 | 结果 |
| --- | --- | --- | --- |
| cancel | `1760f724184e4eb89b108e940b81a1b7` | [Issue #48](https://github.com/simonjiao/gongcao/issues/48) | 观察真实 SDK 命令后取消，未创建 PR |
| loop | `d2651d5e2bf04736a3953b9af7e66033` | [Issue #47](https://github.com/simonjiao/gongcao/issues/47)、[PR #50](https://github.com/simonjiao/gongcao/pull/50) | 独立审查退回、修订、复审与验证通过 |
| recover | `b22ac151a9114ecb99b9f180a296e5dd` | [Issue #49](https://github.com/simonjiao/gongcao/issues/49)、[PR #51](https://github.com/simonjiao/gongcao/pull/51) | 真实 COMMENT 中断对账后完成修订闭环 |

独立 `verify-batch --require-isolation` 返回 `passed=true`、`peak_runs=2`、
`queued=true`、`real_model_overlap=true`、`cancel_cleanup_isolated=true`；
三个 `qa verify` 均返回 `passed=true`、`cleaned=true`，并复核归档摘要。
全批共 15 个原生 SDK 会话，每个角色使用独立 Thread；运行 ID、上下文与日志摘要见
[结构化证据](evidence/final-main-e5a6080.json)。该文件还保存源文件、场景、配置、
质量策略、CI checkout 与原始归档摘要；原始日志和 SQLite 保留在私有验收目录。

两条完整闭环均先在缺失质量配置时停于 `waiting_environment`，重复执行没有远端写入。
补全配置后首次提交保留授权注入的 `min(value, 100)` 缺陷，独立 reviewer 要求修订，
再次提交使旧 SHA 的证据失效。独立边界探针验证输入
`[-500, -1, 0, 1, 99, 100, 101, 500]` 的结果从
`[-500, -1, 0, 1, 99, 100, 100, 100]` 改为
`[0, 0, 0, 1, 99, 100, 100, 100]`。

- PR #50：初稿 `db1ed40ed06b7c1bf5f938464051c47e337a6720`，
  修订 `ae049c127f4dc984f478f50e4cca397928eff534`；
  [CI 40179650371](https://github.com/simonjiao/gongcao/actions/runs/40179650371) 成功。
- PR #51：初稿 `a8cfb2ede8fbf1c6101d4869d7b0825fe3b78fa4`，
  修订 `94fc734b06511ad9c6401a9c8f782ee479f7f989`；
  [CI 40179718983](https://github.com/simonjiao/gongcao/actions/runs/40179718983) 成功。

每次修订均执行配置中的 Ruff、format、mypy、pytest 和真实边界检查，
成功 CI 的 checkout 日志及合并提交父节点绑定实际 head 与固定 base。
完成后重复原生 CLI，运行、操作和远端 Review ID 均未增加。
恢复场景的操作 `cb99158f5ce6195c382d86164dd29dabf46acc4d6af1a34a2b0fbf2f1ddfe138`
从 `pending` 对账到 `succeeded`，响应仍为 Review `5642405485`，未重复 COMMENT。

两批 Issue #42–#44、#47–#49 均已关闭，测试 PR #45/#46/#50/#51 均关闭且未合并；
逐个远端读取确认专属分支返回 404，`main` 始终保持上述固定 SHA。
各 Run 无活动进程、租约或结果不明操作；原生清理移除专属 clone、worktree 与生产会话
认证副本。独立边界探针目录中的认证副本由本次收尾在进程终止后额外移除，
这一步不计作原生 `--cleanup` 已覆盖的能力。保留的日志、上下文和证据不包含认证文件。

## 验证边界

真实恢复场景中断的是 COMMENT 已确认、尚未本地记账的控制器，要求原生 `serve --once`
按真实 GitHub 状态对账。不会声称本次触发过真实 SDK 开发会话中断；质量阶段、独立子进程
等 OS/协议测试仍单独标识。并发限制仅在单个 QA 批次进程内有效。

[#41](https://github.com/simonjiao/gongcao/issues/41) 独立跟踪短 TTL 心跳测试的时序问题，
不在本次验收中修改生产/测试代码，也不允许把相关失败 CI 标成成功。

本记录只归档固定实现的验收事实；归档提交不改变生产、QA、测试、依赖或工作流配置。
