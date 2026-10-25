# Jobs 配置的风险与验证

对应 [Issue #53](https://github.com/simonjiao/gongcao/issues/53) 和
[PR #54 的测试调整意见](https://github.com/simonjiao/gongcao/pull/54#pullrequestreview-5642725918)。
本轮只调整测试组织；生产配置/CLI、调度、租约、恢复、远端写入和 QA 批次实现不变。

| 风险 | 保留的内部边界 | 离线命令路径及新增价值 |
| --- | --- | --- |
| 默认值、缺省字段、两侧额度串用 | 无配置/空映射的 1、2 默认值；正式 3 与 QA 7 独立；额度不改变质量策略 hash | QA 实际默认 2、YAML 1、CLI 覆盖 2；正式实际默认 1、YAML 2、CLI 覆盖 3 |
| 无效 YAML 值被隐式转换 | 两个 section 均保留 true/false、浮点、0、负数、字符串、null、列表、映射负例 | 正式布尔值和 QA 非正数经 CLI 直接退出 1；没有 GH API 调用、正式任务或 QA Run |
| section 结构或字段写错 | 两侧均保留 null、标量、列表、错拼 jobs、额外字段负例 | 复用共享加载器，按输入类别组织，消除 section × 输入的参数化排列 |
| 两侧边界不同或旧参数仍被接受 | 正式上界 3、QA 接受 4/5/7；CLI 非正数/浮点/布尔拒绝；正式拒绝 --concurrency | 三次真实 serve 命令各登记四个本地任务，用 GH 读取屏障证明峰值 1/2/3，剩余任务须等槽位释放 |
| QA 误用生产门禁 | QA loader 忽略无效生产 scheduler/roles/quality | smoke 命令在带无效生产 quality 的统一 YAML 下完成；没有远端资源或写入意图 |
| 批次结果只看摘要、证据未核验 | 原 QA 篡改/队列/取消等安全回归保持不变 | 真实 verify-batch 核对每批 Run、峰值、排队、档案；篡改自有 verdict 后必须退出 1 |

`tests/test_jobs.py` 现有 **22 个内部用例 + 3 条离线 E2E 路径**：

1. QA 默认/YAML/覆盖 → 3 个批次、各 3 个 smoke Run → verify-batch → 篡改证据被拒绝。
2. 正式默认/YAML/覆盖 → 实际 serve 进程、SQLite 和既有调度器 → 释放屏障前由实际 status 核验活动租约数及控制器 PID → 1–3 并发及排队 → 关闭目标阻断 Agent。
3. 两 CLI 的非法配置 → 明确错误和退出码 → 无 GH API 请求、无正式任务、无 QA 批次。

三个 E2E 测试共用一次本地干净 clone，使用现有命令入口，没有新增测试框架。
仅外部 `gh` 使用本地协议替身：允许版本查询和指定目标的只读 API，读取屏障由测试释放，
随后返回关闭的目标。真实沙箱能力检查仍由 smoke 执行；正式流程不会启动模型或写 GitHub。
这验证的是离线配置、命令、调度和证据路径，不构成 GitHub/Codex 真实验收。

原提交 `6b8104a` 在本 PR 新增 54 个 pytest item（47 个内部用例、7 个相似单 smoke CLI 用例）；
调整后新增 25 个，完整套件从 240 项变为 211 项。内部负例按共享校验器的输入类别合并，
不同边界的断言保留。完整 checkout 的准备次数从 7 次降到 1 次；E2E 增加实际命令和证据检查，
不以 item 数减少推断运行提速。定向耗时、固定实现 SHA 与最新 CI 结果记录在 PR 正文。

更丰富的真实 SHA 变化、质量失败恢复和远端结果不明场景由
[Issue #55](https://github.com/simonjiao/gongcao/issues/55) 独立跟踪。
