#!/usr/bin/bash
set -euo pipefail

# 获取脚本所在目录并执行前置依赖检查
SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
"${SCRIPT_DIR}/check-deps.sh"

# 解析所需命令的绝对路径（一律全路径调用）
SEARCH_PATH="${PATH}:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin"
resolve_bin() {
  PATH="$SEARCH_PATH" type -P "$1"
}

GH_BIN="$(resolve_bin gh)"
JQ_BIN="$(resolve_bin jq)"
AGY_BIN="$(resolve_bin agy)"
GREP_BIN="$(resolve_bin grep)"
MKDIR_BIN="$(resolve_bin mkdir)"
TOUCH_BIN="$(resolve_bin touch)"
DATE_BIN="$(resolve_bin date)"
SLEEP_BIN="$(resolve_bin sleep)"
TEE_BIN="$(resolve_bin tee)"
CAT_BIN="$(resolve_bin cat)"

# ===== 可调配置 =====
REPO="${REPO:-}"                     # 留空默认当前目录的 git 仓库，也可填 "owner/repo"
ISSUE_STATE="${ISSUE_STATE:-open}"   # open | closed | all
FILTER_LABEL="${FILTER_LABEL:-}"     # 可选：只拉取带指定标签的 issue，如 "ready"
POLL_INTERVAL="${POLL_INTERVAL:-60}" # 无新 issue 时的轮询间隔（秒）
PRINT_TIMEOUT="${PRINT_TIMEOUT:-15m}"
STATE_FILE="${STATE_FILE:-/tmp/agy_processed_issues.txt}"
LOG_DIR="${LOG_DIR:-/tmp/agy_issue_logs}"

"$MKDIR_BIN" -p "$LOG_DIR"
"$TOUCH_BIN" "$STATE_FILE"

gh_args=(issue list --state "$ISSUE_STATE" --limit 20 --json number,title,body,labels,state,url)
[[ -n "$REPO" ]] && gh_args+=(--repo "$REPO")
[[ -n "$FILTER_LABEL" ]] && gh_args+=(--label "$FILTER_LABEL")

while true; do
  # 获取 issue 列表
  issues_json="$("$GH_BIN" "${gh_args[@]}")"

  # 找出第一个尚未处理过的 issue 编号
  next_issue_json=""
  while IFS= read -r row; do
    num="$("$JQ_BIN" -r '.number' <<<"$row")"
    if ! "$GREP_BIN" -qx "$num" "$STATE_FILE"; then
      next_issue_json="$row"
      break
    fi
  done < <("$JQ_BIN" -c '.[]' <<<"$issues_json")

  if [[ -z "$next_issue_json" ]]; then
    printf '[%s] 没有待处理的 issue，%ss 后重试...\n' "$("$DATE_BIN" '+%F %T')" "$POLL_INTERVAL"
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  # 提取 issue 字段（编号、状态、标签、标题、内容、链接）
  number="$("$JQ_BIN" -r '.number' <<<"$next_issue_json")"
  state="$("$JQ_BIN" -r '.state' <<<"$next_issue_json")"
  title="$("$JQ_BIN" -r '.title' <<<"$next_issue_json")"
  url="$("$JQ_BIN" -r '.url' <<<"$next_issue_json")"
  labels="$("$JQ_BIN" -r '([.labels[].name] | join(", ")) // "(none)"' <<<"$next_issue_json")"
  body="$("$JQ_BIN" -r '.body // "(empty)"' <<<"$next_issue_json")"

  log_file="${LOG_DIR}/issue-${number}.log"
  printf '[%s] 开始处理 Issue #%s: %s\n' "$("$DATE_BIN" '+%F %T')" "$number" "$title"

  prompt="$("$CAT_BIN" <<EOF
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
)"

  if "$AGY_BIN" -p "$prompt" --mode auto --sandbox --print-timeout "$PRINT_TIMEOUT" | "$TEE_BIN" "$log_file"; then
    printf '%s\n' "$number" >> "$STATE_FILE"
    printf '[%s] Issue #%s 处理完成，日志：%s\n' "$("$DATE_BIN" '+%F %T')" "$number" "$log_file"

    # 可选：如果需要自动在 GitHub 上标记已处理，取消下面注释
    # "$GH_BIN" issue edit "$number" ${REPO:+--repo "$REPO"} --add-label "agy-done"
  else
    printf '[%s] Issue #%s 执行失败（未标记完成），详见：%s\n' "$("$DATE_BIN" '+%F %T')" "$number" "$log_file"
  fi

  "$SLEEP_BIN" 5
done
