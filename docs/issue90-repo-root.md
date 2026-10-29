# #90：仓库准备与 serve 运行摘要

配置解析后仍提供完整的 `Source.path`：显式 path 优先，否则由绝对 repo_root 和
规范化 owner/repo 推导。不迁移历史任务；路径检查拒绝遍历、符号链接和不同仓库
共用目录。配置读取只做校验，不执行 clone，因此只读诊断命令无需副作用。

Discovery 在领取容量判断之前准备所有来源，沿用现有同机仓库锁。有效仓库只读
校验；缺失仓库通过宿主 gh credential helper clone 到唯一私有临时目录。逐级
O_NOFOLLOW 打开父目录并固定目录描述符；验证 origin 后用 Linux renameat2 的
RENAME_NOREPLACE 原子发布，连并发创建的空目录也不会覆盖。失败/取消只清理
当前调用创建且 inode 身份仍一致的临时目录；无法确认归属的资源不删除。
这沿用项目 Linux/WSL 运行边界，没有引入兼容层。硬中断遗留目录不自动认领。

仓库准备失败分别记录初始化结果并按既有指数退避尝试，单个失败不阻断其余来源。
旧任务仍使用登记路径；恢复失败保留待核对状态、租约及意图，不让它使整个 serve
退出。首次准备/扫描完成后输出一次概览；未校验来源明确标记未初始化或失败。

终端复用 Python logging，输出到 stderr；stdout JSON 契约不变。阶段摘要读取既有
状态，在每个 Workflow 阶段边界和调度循环按变化输出；Journal 只有控制器明确
标记的开始/结束事件可进入摘要，Agent 原始事件不能伪造控制器通知。质量结果仅
输出数量，提示词、完整报告和 SDK 输出仍留在原有私有日志。空闲心跳为约 300 秒，
不随 poll 频率刷屏。没有新服务、日志数据库或流程状态机。

验收复用已有完整多阶段 Workflow、质量失败/缺环境、GitHub retry 及 CLI 夹具。
新增路径/clone/竞争/取消/故障隔离测试；CLI 单次用例从无本地仓库、只有 repo_root
开始，连续模式保留显式 path，均检查启动概览、stderr/stdout 分离和重启不重复领取。
固定 SHA 的 Python 3.12/3.13 全量结果与复审结论记录在关联 PR。

真实定向验证命令（仅在隔离的新目录 clone/复用，不领取 Issue、不启动 Agent 或 serve）：

```sh
uv run python -m qa.repo_root --real --directory /absolute/new-qa-directory \
  --repo simonjiao/airdb --repo simonjiao/gongcao
```

结果保存为该目录的 evidence.json，包含实现 SHA、账户、实际仓库 SHA、复用后
HEAD/本地修改保持不变的验证。故障和破坏性边界只在离线夹具中演练，不对业务
仓库执行。不改远程开发/PR 目标分支解析策略，不自动合并或部署。
