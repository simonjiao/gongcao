# #79 动态验证与证据归档

按目标 SHA 的 AGENTS.md、构建文件、Issue 要求、PR diff 生成三类验证项；
分析候选只提供建议，控制器执行结果才是证据。支持 Python、Maven、npm 和 Make 入口。
未知入口保留 blocked；人工确认可给出有理由的 not_applicable，不能用 Agent 报告充当通过。

计划和结果绑定 repository、Issue/PR、base_sha、target_sha、request_hash、plan_hash 和运行环境。
同 SHA 更换计划使旧质量结果、Reviewer、Validator 失效；旧格式仅保留为历史记录。
已删除 quality YAML、必经 CI gate 和 Actions 结果读取，无兼容或迁移路径。

```sh
uv run gongcao quality TASK                   # 查看含版本绑定的计划
uv run gongcao quality TASK --plan plan.json  # 当前版本的人工确认
uv run gongcao quality TASK --run             # 普通检查和本地 E2E
uv run gongcao quality TASK --run --real --real-check INDEX --plan-hash HASH
uv run gongcao quality TASK --archive --real
```

普通检查在无模型/GitHub 凭据的 Bubblewrap 内执行；改写跟踪源码或新增未忽略文件会拒绝 SHA 证据。
真实 QA 只接受当前版本 qa/ 脚本或 npm test:e2e，以明确授权的计划哈希执行；每项使用独立干净工作树，
避免普通检查把产物当作宿主代码执行。退出 77/127 记录环境 blocked，其他非零退出记录 failed。
项目 QA 入口负责其真实环境预检、资源清理及不明远端操作处理；这里不增加第二套 QA 平台。

REVIEW 使用必需 build/internal 的真实结果；VALIDATION 核对全部必需项后才调用 Validator。
PR 头版本、审查/合并保护、租约、暂停和人工合并仍由原控制器核验。无 CI 不构成新阻塞。

原始 stdout/stderr、SQLite 和会话留在本地私有目录。归档只发布新格式脱敏清单和摘要：
`qa/issue-N-evidence` 分支的 `qa/acceptance/issue-N/TARGET_SHA/RUN_ID/`，包括
README.md、manifest.json、SHA256SUMS。独立孤立提交起步，后续追加保留失败历史，不合并业务 PR。
通过受控意图→push→固定 commit 逐文件哈希回读，结果不明不重放，先由 recover 对账。
成功后任务及 Issue/PR 保存固定 commit 链接；归档失败不宣称远端保存成功。

验证包括真实 Git/Bubblewrap、无 CI 的完整工作流、计划失效、缺环境、受控入口约束、
沙箱检查污染源码与宿主隔离、追加归档、脱敏/哈希及发布响应丢失后的回读。
离线协议替身不冒充真实引擎/浏览器验收；真实 GitHub 归档须另获明确授权。

分工按最新 Issue 正文执行：#78 负责 doctor/示例配置；本次仅删除失效 quality 示例段。
#80 随后整理剩余 test_pr2/跨文件夹具/长期文档；#55 再做 E2E 去重和扩展，本次不搬迁剩余测试。
