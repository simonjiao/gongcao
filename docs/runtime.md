# 运行与恢复

当前命令与配置见 [README](../README.md)，验证门禁见
[验证与证据归档](validation-evidence.md)。阶段表示业务进度，状态表示当前执行情况；
只有控制器能改变二者，Agent 报告不代替审查、检查或人工合并。

`serve` 在一个专属 state-dir 中调度，正式并发默认 1、上限 3；
共享 SQLite 租约和 OS 锁同时约束任务、仓库/分支及 GitHub 对象占用。
取消优先于迟到结果；暂停在安全点收束当前执行，未知写入保留占用。

`status / inspect / diagnose / logs --follow` 从本地查看状态、证据与日志。
中断后先用 `recover TASK` 核对进程身份、工作区、上下文、会话引用和远端事实，
再用 `retry TASK` 显式重试；旧工作保留，新执行使用新线程与 Worktree。
未知启动、后代清理不明或远端写入不明时，保留待核对，不能靠清空目录或数据库推进。
依赖须确认已合并；未发布任务可显式 `retry --refresh-base`，未知写入不能借此换基线。

成果交付与验收分开：已完成的开发可在控制器安全核验后交付唯一草稿 PR，
后续缺项仍阻断 Review/Validation。领取锚点不覆盖，进度追加评论，未知发送只读对账。
细节见 [交付边界](issue100-delivery.md) 与 [待验收交付和进度](issue103-delivery-progress.md)。

[pr1](pr1.md)、[pr2](pr2.md)、[stage3](stage3.md)、`acceptance-*.md` 和
`evidence/` 是历史实现/验收记录；其中固定 SHA 和结果不代表当前版本已验收。
