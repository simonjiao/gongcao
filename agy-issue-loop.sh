#!/usr/bin/env bash
set -euo pipefail

# ===== 可调配置 =====
REPO="${REPO:-}"                    # 留空默认当前目录的 git 仓库，也可填 "owner/repo"
ISSUE_STATE="${ISSUE_STATE:-open}"  # open | closed | all
FILTER_LABEL="${FILTER_LABEL:-}"    # 可选：只拉取带指定标签的 issue，如 "ready"
POLL_INTERVAL="${POLL_INTERVAL:-60}" # 无新 issue 时的轮询间隔（秒）
PRINT_TIMEOUT="${PRINT_TIMEOUT:-15m}"
STATE_FILE="${STATE_FILE:-/tmp/agy_processed_issues.txt}"
LOG_DIR="${LOG_DIR:-/tmp/agy_issue_logs}"

mkdir -p "$LOG_DIR"
touch "$STATE_FILE"

gh_args=(issue list --state "$ISSUE_STATE" --limit 20 --json number,title,body,labels,state,url)
[[ -n "$REPO" ]] && gh_args+=(--repo "$REPO")
[[ -n "$FILTER_LABEL" ]] && gh_args+=(--label "$FILTER_LABEL")

while true; do
  # 获取 issue 列表
  issues_json="$(gh "${gh_args[@]}")"

  # 找出第一个尚未处理过的 issue 编号
  next_issue_json=""
  while IFS= read -r row; do
    num="$(jq -r '.number' <<<"$row")"
    if ! grep -qx "$num" "$STATE_FILE"; then
      next_issue_json="$row"
      break
    fi
  done < <(jq -c '.[]' <<<"$issues_json")

  if [[ -z "$next_issue_json" ]]; then
    echo "[$(date '+%F %T')] 没有待处理的 issue，${POLL_INTERVAL}s 后重试..."
    sleep "$POLL_INTERVAL"
    continue
  fi

  # 提取 issue 字段（编号、状态、标签、标题、内容、链接）
  number="$(jq -r '.number' <<<"$next_issue_json")"
  state="$(jq -r '.state' <<<"$next_issue_json")"
  title="$(jq -r '.title' <<<"$next_issue_json")"
  url="$(jq -r '.url' <<<"$next_issue_json")"
  labels="$(jq -r '([.labels[].name] | join(", ")) // "(none)"' <<<"$next_issue_json")"
  body="$(jq -r '.body // "(empty)"' <<<"$next_issue_json")"

  log_file="${LOG_DIR}/issue-${number}.log"
  echo "[$(date '+%F %T')] 开始处理 Issue #${number}: ${title}"

  prompt=$(cat <<EOF
请处理以下 GitHub Issue：

- 编号: #${number}
- 链接: ${url}
- 状态: ${state}
- 标签: ${labels}
- 标题: ${title}

### Issue 内容
${body}

### 处理要求
1. 先阅读相关代码并分析问题根因或需求范围。
2. 给出并实施最小必要改动，运行相关测试验证。
3. 最后总结改动文件、验证结果与未覆盖风险；如果被阻塞，明确说明原因。
EOF
)

  if agy -p "$prompt" --mode auto --sandbox --print-timeout "$PRINT_TIMEOUT" | tee "$log_file"; then
    echo "$number" >> "$STATE_FILE"
    echo "[$(date '+%F %T')] Issue #${number} 处理完成，日志：${log_file}"

    # 可选：如果需要自动在 GitHub 上标记已处理，取消下面注释
    # gh issue edit "$number" ${REPO:+--repo "$REPO"} --add-label "agy-done"
  else
    echo "[$(date '+%F %T')] Issue #${number} 执行失败（未标记完成），详见：${log_file}"
  fi

  sleep 5
done
