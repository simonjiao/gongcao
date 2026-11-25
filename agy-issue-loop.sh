#!/usr/bin/bash
set -euo pipefail

# 获取脚本所在目录并执行前置依赖检查
SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
"${SCRIPT_DIR}/check-deps.sh"
GH_STATE_BIN="${SCRIPT_DIR}/gh-state.sh"

# 解析所需命令的绝对路径（一律全路径调用）
SEARCH_PATH="${PATH}:/usr/local/bin:/usr/bin:/bin:${HOME}/.local/bin"
resolve_bin() {
  PATH="$SEARCH_PATH" type -P "$1"
}

JQ_BIN="$(resolve_bin jq)"
AGY_BIN="$(resolve_bin agy)"
GIT_BIN="$(resolve_bin git)"
GREP_BIN="$(resolve_bin grep)"
MKDIR_BIN="$(resolve_bin mkdir)"
TOUCH_BIN="$(resolve_bin touch)"
DATE_BIN="$(resolve_bin date)"
SLEEP_BIN="$(resolve_bin sleep)"
TEE_BIN="$(resolve_bin tee)"
CAT_BIN="$(resolve_bin cat)"
FLOCK_BIN="$(resolve_bin flock)"

# ===== 主工作目录与可调配置 =====
GONGCAO_HOME="${GONGCAO_HOME:-${HOME}/.gongcao}"
REPOS_ROOT="${REPOS_ROOT:-${GONGCAO_HOME}/repos}"
STATE_BASE="${STATE_BASE:-${GONGCAO_HOME}/state}"

REPO="${REPO:-}"                       # 目标 GitHub 仓库 "owner/repo"（留空默认从本地仓库识别）
REPO_NAME="${REPO_NAME:-}"             # 可选：直接指定 ~/.gongcao/repos/<REPO_NAME>
REPO_DIR="${REPO_DIR:-}"               # 可选：显式指定本地仓库路径；留空时按 REPO/REPO_NAME 定位到 ~/.gongcao/repos/
AUTO_CLONE="${AUTO_CLONE:-1}"          # 指定 REPO 且本地尚未克隆时，是否自动 clone 到 ~/.gongcao/repos/（1=是，0=否）
BASE_BRANCH="${BASE_BRANCH:-}"         # 创建 worktree/PR 的基准分支，留空自动探测 origin/HEAD 或当前 HEAD
BRANCH_PREFIX="${BRANCH_PREFIX:-agy/issue-}" # 仅作历史遗留分支兼容识别与清理使用；新分支统一使用无 Issue 编号的语义命名 <type>/<slug>
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
GIT_FETCH="${GIT_FETCH:-1}"            # 创建或同步 worktree 前是否尝试 git fetch origin（1=是，0=否）
AUTO_SYNC_BASE="${AUTO_SYNC_BASE:-1}"  # 启动/续跑前是否自动合并最新基准分支并把冲突交给 agy 解决（1=是，0=否）
GH_SYNC_ENABLED="${GH_SYNC_ENABLED:-1}" # 是否启用 GitHub 状态机与置顶评论（1=是，0=纯本地模式）
INIT_LABELS="${INIT_LABELS:-1}"        # 启动时是否幂等初始化 agy:* 标签（1=是，0=否）
AUTO_PUSH_PR="${AUTO_PUSH_PR:-1}"      # 有新 commit 时是否自动 push 分支并创建/更新 Draft PR（1=是，0=仅维护 Issue 状态）
DRY_RUN="${DRY_RUN:-0}"                # 1=演练模式（不修改远端 GitHub、不执行 git push）
ISSUE_STATE="${ISSUE_STATE:-open}"     # open | closed | all
ISSUE_LIMIT="${ISSUE_LIMIT:-20}"       # 每次拉取的最大 issue 数量
# 启用 GitHub 状态机时默认只拉取人工放行的 agy:todo；显式传 FILTER_LABEL="" 可关闭标签过滤
if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
  FILTER_LABEL="${FILTER_LABEL-${LABEL_PREFIX}todo}"
else
  FILTER_LABEL="${FILTER_LABEL-}"
fi
HANDLE_CHANGES_REQUESTED="${HANDLE_CHANGES_REQUESTED:-1}" # 是否自动接回评审/E2E/终审打回的 agy:changes-requested（1=是，0=否）
REVIEW_COMMENT_MARKER="${REVIEW_COMMENT_MARKER:-<!-- codex-review-comment -->}"
E2E_COMMENT_MARKER="${E2E_COMMENT_MARKER:-<!-- codex-e2e-comment -->}"
FINAL_GATE_COMMENT_MARKER="${FINAL_GATE_COMMENT_MARKER:-<!-- codex-final-gate-comment -->}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"   # 无新 issue 时的轮询间隔（秒）
MAX_BACKOFF="${MAX_BACKOFF:-900}"      # 连续拉取失败时的最大退避上限（秒，默认 15 分钟）
PRINT_TIMEOUT="${PRINT_TIMEOUT:-40m}"  # xhigh 模型推理更深且需覆盖后端编译测试，默认 40 分钟
MAX_TIMEOUT_RETRIES="${MAX_TIMEOUT_RETRIES:-2}" # 触发 --print-timeout 超时后自动续接原会话重试次数上限（共最多 1+N 次）
MAX_QUOTA_RETRIES="${MAX_QUOTA_RETRIES:-6}"     # 触发 429/RESOURCE_EXHAUSTED 配额限流或可重试 API 报错时的自动等待重试次数上限
QUOTA_RETRY_BUFFER_SEC="${QUOTA_RETRY_BUFFER_SEC:-15}" # 配额重置倒计时额外缓冲秒数
QUOTA_DEFAULT_WAIT_SEC="${QUOTA_DEFAULT_WAIT_SEC:-120}" # 未解析出 Resets in 时的默认冷却等待秒数
QUOTA_INLINE_WAIT_MAX_SEC="${QUOTA_INLINE_WAIT_MAX_SEC:-300}" # 短冷却（<=300s）原地等待续接；超过则写入全局冷却文件并退回原队列
MAX_QUOTA_WAIT_SEC="${MAX_QUOTA_WAIT_SEC:-86400}"      # 自动冷却等待上限（默认 24 小时，仅超上限才转 blocked）
AGY_MODE="${AGY_MODE:-accept-edits}"   # accept-edits | auto | plan（默认 accept-edits 避免账号无 auto 权限告警）
AGY_SKIP_PERMISSIONS="${AGY_SKIP_PERMISSIONS:-1}" # 在 --sandbox 内免本地交互确认自动推进（1=启用，0=关闭）
AGY_MODEL="${AGY_MODEL:-gemini-4-hydrogen-xhigh}" # 默认使用 Gemini 4 Hydrogen (XHigh)；也可切为 gemini-4-neon-xhigh
AGY_EFFORT="${AGY_EFFORT:-}" # 可选：显式传递 --effort (low|medium|high|xhigh|max)

"$MKDIR_BIN" -p "$GONGCAO_HOME" "$REPOS_ROOT" "$STATE_BASE"

# 解析目标仓库目录（优先使用 ~/.gongcao/repos/）
if [[ -z "$REPO_DIR" ]]; then
  if [[ -n "$REPO" ]]; then
    _slug="${REPO//\//__}"
    _slug="${_slug//[^a-zA-Z0-9._-]/_}"
    _short="${REPO##*/}"
    _short="${_short//[^a-zA-Z0-9._-]/_}"
    if [[ -e "${REPOS_ROOT}/${_slug}/.git" ]]; then
      REPO_DIR="${REPOS_ROOT}/${_slug}"
    elif [[ -e "${REPOS_ROOT}/${_short}/.git" ]]; then
      REPO_DIR="${REPOS_ROOT}/${_short}"
    else
      REPO_DIR="${REPOS_ROOT}/${_slug}"
      if [[ "$AUTO_CLONE" == "1" ]]; then
        # clone 属于只读远端操作，即使在 DRY_RUN=1 演练模式下也需要本地仓库副本才能继续
        if [[ "$DRY_RUN" == "1" ]]; then
          printf '提示：DRY_RUN=1 仅跳过远端写操作，将先只读克隆 %s 到 %s 用于本地演练。\n' "$REPO" "$REPO_DIR" >&2
        fi
        GONGCAO_HOME="$GONGCAO_HOME" REPOS_ROOT="$REPOS_ROOT" REPO="$REPO" DRY_RUN=0 \
          "$GH_STATE_BIN" clone-repo "$REPO" "$REPO_DIR" >/dev/null
      fi
    fi
  elif [[ -n "$REPO_NAME" ]]; then
    REPO_DIR="${REPOS_ROOT}/${REPO_NAME}"
  else
    REPO_DIR="$(pwd)"
  fi
fi

# 校验目标仓库目录并获取主仓库根目录
if ! REPO_ROOT="$("$GIT_BIN" -C "$REPO_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  printf '错误：REPO_DIR (%s) 不是一个有效的 Git 仓库。\n' "$REPO_DIR" >&2
  printf '提示：可先克隆到 %s/<repo> 或传入 REPO=owner/repo 自动克隆。\n' "$REPOS_ROOT" >&2
  exit 1
fi

# 生成仓库标识，用于隔离不同仓库的状态、worktree 和会话记录
if [[ -n "$REPO" ]]; then
  REPO_SLUG="${REPO//\//__}"
else
  REPO_SLUG="${REPO_ROOT##*/}"
fi
REPO_SLUG="${REPO_SLUG//[^a-zA-Z0-9._-]/_}"

# 持久化目录布局（统一位于 ~/.gongcao/state/<repo_slug>/）
STATE_ROOT="${STATE_ROOT:-${STATE_BASE}/${REPO_SLUG}}"
WORKTREE_ROOT="${WORKTREE_ROOT:-${STATE_ROOT}/worktrees}"
SESSIONS_ROOT="${SESSIONS_ROOT:-${STATE_ROOT}/sessions}"
STATE_FILE="${STATE_FILE:-${STATE_ROOT}/processed_issues.txt}"
REPO_GIT_LOCK="${STATE_ROOT}/repo-git.lock"

"$MKDIR_BIN" -p "$STATE_ROOT" "$WORKTREE_ROOT" "$SESSIONS_ROOT"
"$TOUCH_BIN" "$STATE_FILE" "$REPO_GIT_LOCK"

# 判断是否完全以 GitHub 状态标签作为队列真相源（人工把标签改回 agy:todo 时可自动续接）
USE_LOCAL_DEDUP=1
if [[ "$GH_SYNC_ENABLED" == "1" && "$DRY_RUN" != "1" && "$FILTER_LABEL" == "${LABEL_PREFIX}todo" ]]; then
  USE_LOCAL_DEDUP=0
fi

gh_state() {
  GONGCAO_HOME="$GONGCAO_HOME" \
  REPOS_ROOT="$REPOS_ROOT" \
  REPO_DIR="$REPO_ROOT" \
  REPO="$REPO" \
  LABEL_PREFIX="$LABEL_PREFIX" \
  DRY_RUN="$DRY_RUN" \
  "$GH_STATE_BIN" "$@"
}

printf '[%s] 启动 agy-issue-loop\n' "$("$DATE_BIN" '+%F %T')"
printf '  工作主目录 : %s\n' "$GONGCAO_HOME"
printf '  主仓库目录 : %s\n' "$REPO_ROOT"
printf '  状态根目录 : %s\n' "$STATE_ROOT"
printf '  Worktree 根: %s\n' "$WORKTREE_ROOT"
printf '  会话记录根 : %s\n' "$SESSIONS_ROOT"
printf '  过滤标签   : %s\n' "${FILTER_LABEL:-(无)}"
printf '  运行模型   : %s (effort=%s, mode=%s, timeout=%s, timeout_retries=%s, quota_retries=%s, skip_permissions=%s)\n' "${AGY_MODEL:-(agy 默认)}" "${AGY_EFFORT:-(随模型默认)}" "$AGY_MODE" "$PRINT_TIMEOUT" "$MAX_TIMEOUT_RETRIES" "$MAX_QUOTA_RETRIES" "$AGY_SKIP_PERMISSIONS"
printf '  GitHub同步 : %s (AUTO_PUSH_PR=%s, DRY_RUN=%s)\n' "$GH_SYNC_ENABLED" "$AUTO_PUSH_PR" "$DRY_RUN"

LABELS_READY=0
if [[ "$GH_SYNC_ENABLED" == "1" && "$INIT_LABELS" == "1" ]]; then
  if gh_state init-labels; then
    LABELS_READY=1
  else
    printf '[%s] 警告：初始化状态标签失败（将在后续轮询中自动重试）\n' "$("$DATE_BIN" '+%F %T')" >&2
  fi
fi

calc_backoff() {
  local errors="$1"
  local shift=$(( errors > 0 ? errors - 1 : 0 ))
  (( shift > 4 )) && shift=4
  local wait_sec=$(( POLL_INTERVAL * (1 << shift) ))
  (( wait_sec > MAX_BACKOFF )) && wait_sec="$MAX_BACKOFF"
  printf '%s' "$wait_sec"
}

resolve_base_ref() {
  if [[ -n "$BASE_BRANCH" ]]; then
    printf '%s' "$BASE_BRANCH"
    return 0
  fi
  local origin_head=""
  if origin_head="$("$GIT_BIN" -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    printf '%s' "$origin_head"
    return 0
  fi
  "$GIT_BIN" -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD
}

# 将 origin/main 转成 PR 使用的裸分支名 main
strip_origin_prefix() {
  local ref="$1"
  printf '%s' "${ref#origin/}"
}

# 解析已有 worktree / 会话 / 遗留分支名（未找到时返回空）
resolve_existing_issue_branch() {
  local issue_num="$1"
  local session_dir="$2"
  local wt_dir="$3"
  local b=""

  if [[ -e "${wt_dir}/.git" ]]; then
    b="$("$GIT_BIN" -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    if [[ -n "$b" && "$b" != "HEAD" ]]; then
      printf '%s' "$b"
      return 0
    fi
  fi

  if [[ -s "${session_dir}/branch_name" ]]; then
    IFS= read -r b < "${session_dir}/branch_name" || true
    if [[ -n "$b" ]]; then
      printf '%s' "$b"
      return 0
    fi
  fi

  if [[ -s "${session_dir}/meta.json" ]]; then
    b="$("$JQ_BIN" -r '.branch // empty' "${session_dir}/meta.json" 2>/dev/null || true)"
    if [[ -n "$b" ]]; then
      printf '%s' "$b"
      return 0
    fi
  fi

  if "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${BRANCH_PREFIX}${issue_num}" \
    || "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${BRANCH_PREFIX}${issue_num}"; then
    printf '%s' "${BRANCH_PREFIX}${issue_num}"
    return 0
  fi
}

is_placeholder_or_legacy_branch() {
  local branch_name="$1"
  [[ "$branch_name" == _gongcao-wip/* || "$branch_name" == "${BRANCH_PREFIX}"* ]]
}

infer_branch_type() {
  local labels_text="$1"
  local title_text="$2"
  local commit_text="$3"

  local re_commit='^[[:space:]]*([a-zA-Z]+)(\([^)]*\))?:'
  if [[ "$commit_text" =~ $re_commit ]]; then
    local ctype="${BASH_REMATCH[1],,}"
    case "$ctype" in
      fix|feat|docs|refactor|test|chore|perf)
        printf '%s' "$ctype"
        return 0
        ;;
    esac
  fi

  local combined="${labels_text} ${title_text}"
  local low="${combined,,}"
  if [[ "$low" =~ (bug|修复|漏报|误报|缺陷|崩溃|错误|异常) ]]; then
    printf 'fix'
  elif [[ "$low" =~ (docs?|文档|手册|指南) ]]; then
    printf 'docs'
  elif [[ "$low" =~ (refactor|重构) ]]; then
    printf 'refactor'
  elif [[ "$low" =~ (test|测试|vitest|qa) ]]; then
    printf 'test'
  elif [[ "$low" =~ (perf|性能|优化) ]]; then
    printf 'perf'
  elif [[ "$low" =~ (chore|ci|build|依赖|配置) ]]; then
    printf 'chore'
  elif [[ "$low" =~ (feat|feature|新增|支持|能力) ]]; then
    printf 'feat'
  else
    printf 'fix'
  fi
}

sanitize_branch_slug() {
  local raw_text="$1"
  local issue_num="$2"

  local lower="${raw_text,,}"
  local normalized="${lower//[^a-z0-9]/-}"
  local -a parts=()
  local -a kept=()
  IFS='-' read -r -a parts <<<"$normalized"

  local i=0 tok="" next_tok=""
  while (( i < ${#parts[@]} )); do
    tok="${parts[$i]}"
    next_tok=""
    (( i + 1 < ${#parts[@]} )) && next_tok="${parts[$((i + 1))]}"

    if [[ -z "$tok" ]]; then
      i=$((i + 1))
      continue
    fi
    if [[ "$tok" == "issue" || "$tok" == "pr" ]] && [[ "$next_tok" =~ ^[0-9]+$ ]]; then
      i=$((i + 2))
      continue
    fi
    if [[ "$tok" =~ ^[0-9]+$ || "$tok" =~ ^issue[0-9]+$ || "$tok" =~ ^pr[0-9]+$ ]]; then
      i=$((i + 1))
      continue
    fi
    if [[ -n "$issue_num" && "$tok" == *"$issue_num"* ]]; then
      i=$((i + 1))
      continue
    fi
    kept+=("$tok")
    i=$((i + 1))
  done

  local joined=""
  local k
  for k in "${kept[@]}"; do
    if [[ -n "$joined" ]]; then
      joined+="-${k}"
    else
      joined="$k"
    fi
  done

  joined="${joined:0:48}"
  joined="${joined%-}"
  printf '%s' "$joined"
}

derive_semantic_branch() {
  local proposed="$1"
  local commit_msg="$2"
  local title="$3"
  local labels_text="$4"
  local issue_num="$5"
  local wt_dir="$6"
  local base_ref="$7"

  # 清理引号、反引号、空白及误带的前缀
  proposed="${proposed#refs/heads/}"
  proposed="${proposed//\`/}"
  proposed="${proposed//\"/}"
  proposed="${proposed//\'/}"
  proposed="${proposed#"${proposed%%[![:space:]]*}"}"
  proposed="${proposed%"${proposed##*[![:space:]]}"}"

  local btype="" raw_slug=""
  if [[ "$proposed" =~ ^([a-zA-Z]+)/(.+)$ ]]; then
    local ptype="${BASH_REMATCH[1],,}"
    local prest="${BASH_REMATCH[2]}"
    case "$ptype" in
      fix|feat|docs|refactor|test|chore|perf)
        btype="$ptype"
        raw_slug="$prest"
        ;;
      *)
        btype="$(infer_branch_type "$labels_text" "$title" "$commit_msg")"
        raw_slug="$proposed"
        ;;
    esac
  elif [[ -n "$proposed" ]]; then
    btype="$(infer_branch_type "$labels_text" "$title" "$commit_msg")"
    raw_slug="$proposed"
  else
    btype="$(infer_branch_type "$labels_text" "$title" "$commit_msg")"
    local re_desc='^[[:space:]]*[a-zA-Z]+(\(([^)]*)\))?:[[:space:]]*(.+)$'
    if [[ "$commit_msg" =~ $re_desc ]]; then
      local cscope="${BASH_REMATCH[2]}"
      local cdesc="${BASH_REMATCH[3]}"
      raw_slug="${cscope:+${cscope} }${cdesc}"
    else
      raw_slug="$title"
    fi
  fi

  local slug=""
  slug="$(sanitize_branch_slug "$raw_slug" "$issue_num")"

  if (( ${#slug} < 3 )) && [[ -n "$title" && "$raw_slug" != "$title" ]]; then
    slug="$(sanitize_branch_slug "$title" "$issue_num")"
  fi

  # 若标题/提交仍无可用英文词素（如纯中文标题且模型未输出分支名），则从改动文件名提取语义 slug
  if (( ${#slug} < 3 )); then
    local files_text="" f="" base_f="" f_count=0
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      base_f="${f##*/}"
      base_f="${base_f%.*}"
      files_text+=" ${base_f}"
      f_count=$((f_count + 1))
      (( f_count >= 3 )) && break
    done < <("$GIT_BIN" -C "$wt_dir" diff --name-only "${base_ref}..HEAD" 2>/dev/null || true)
    if [[ -n "$files_text" ]]; then
      slug="$(sanitize_branch_slug "$files_text" "$issue_num")"
    fi
  fi

  local short_sha=""
  short_sha="$("$GIT_BIN" -C "$wt_dir" rev-parse --short=6 HEAD 2>/dev/null || printf 'update')"
  if (( ${#slug} < 3 )); then
    slug="change-${short_sha}"
  fi

  local cand="${btype}/${slug}"
  local cur_branch=""
  cur_branch="$("$GIT_BIN" -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ "$cand" != "$cur_branch" ]] && {
    "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${cand}" \
      || "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${cand}"
  }; then
    local short4="${short_sha:0:4}"
    [[ -z "$short4" ]] && short4="alt"
    cand="${btype}/${slug:0:43}"
    cand="${cand%-}-${short4}"
  fi

  if ! "$GIT_BIN" -C "$REPO_ROOT" check-ref-format --branch "$cand" >/dev/null 2>&1; then
    cand="${btype}/update-${short_sha}"
  fi

  printf '%s' "$cand"
}

ensure_worktree() {
  local issue_num="$1"
  local branch="$2"
  local base_ref="$3"
  local wt_dir="${WORKTREE_ROOT}/issue-${issue_num}"

  # 使用文件锁保护主仓库 fetch/worktree 操作，防止与 review/e2e/cleanup 循环并发冲突
  (
    "$FLOCK_BIN" -x 9
    "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true

    if [[ "$GIT_FETCH" == "1" ]] && "$GIT_BIN" -C "$REPO_ROOT" remote get-url origin >/dev/null 2>&1; then
      "$GIT_BIN" -C "$REPO_ROOT" fetch --prune origin >&2 || true
    fi

    if [[ ! -e "${wt_dir}/.git" ]]; then
      if "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/${branch}"; then
        "$GIT_BIN" -C "$REPO_ROOT" worktree add "$wt_dir" "$branch" >&2
      elif "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
        "$GIT_BIN" -C "$REPO_ROOT" worktree add --track -b "$branch" "$wt_dir" "origin/${branch}" >&2
      else
        "$GIT_BIN" -C "$REPO_ROOT" worktree add -b "$branch" "$wt_dir" "$base_ref" >&2
      fi
    fi
  ) 9>"$REPO_GIT_LOCK"

  printf '%s' "$wt_dir"
}

# 同步主干基准分支到当前 worktree；若发生冲突则保留冲突标记，输出冲突文件清单交给 agy 解决
prepare_base_merge() {
  local wt_dir="$1"
  local base_ref="$2"
  local conflict_list_file="$3"

  : > "$conflict_list_file"
  [[ "$AUTO_SYNC_BASE" == "1" ]] || return 0

  # 若上次残留未完成的 merge 状态，先中止回退再基于最新主干重新合并
  if "$GIT_BIN" -C "$wt_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    "$GIT_BIN" -C "$wt_dir" merge --abort >/dev/null 2>&1 || true
  fi

  # 如果目标基准分支已包含在当前 HEAD 历史中，无需合并
  if "$GIT_BIN" -C "$wt_dir" merge-base --is-ancestor "$base_ref" HEAD 2>/dev/null; then
    return 0
  fi

  # 若工作区已有未提交改动，暂不自动 merge 以免覆盖现场
  local dirty=""
  dirty="$("$GIT_BIN" -C "$wt_dir" status --porcelain 2>/dev/null || true)"
  if [[ -n "$dirty" ]]; then
    printf '[%s] 提示：worktree 存在未提交改动，暂跳过自动合并 %s\n' "$("$DATE_BIN" '+%F %T')" "$base_ref" >&2
    return 0
  fi

  printf '[%s] 检测到主干 %s 有新提交，尝试自动合并到当前分支...\n' "$("$DATE_BIN" '+%F %T')" "$base_ref" >&2
  if "$GIT_BIN" -C "$wt_dir" merge --no-edit "$base_ref" >&2; then
    printf '[%s] 已干净合并主干 %s\n' "$("$DATE_BIN" '+%F %T')" "$base_ref" >&2
    return 0
  fi

  # 发生合并冲突：保留冲突现场，收集未合并文件清单交给 agy 解决
  "$GIT_BIN" -C "$wt_dir" diff --name-only --diff-filter=U > "$conflict_list_file" 2>/dev/null || true
  if [[ -s "$conflict_list_file" ]]; then
    printf '[%s] 合并 %s 产生冲突，将交由 agy 解决（冲突文件已记录）\n' "$("$DATE_BIN" '+%F %T')" "$base_ref" >&2
    return 0
  fi

  # 非典型 merge 失败且无冲突清单时回退，避免遗留异常状态
  "$GIT_BIN" -C "$wt_dir" merge --abort >/dev/null 2>&1 || true
  return 1
}

extract_conversation_id() {
  local events_file="$1"
  local id=""
  while IFS= read -r line; do
    [[ -n "$line" ]] && id="$line"
  done < <("$JQ_BIN" -R -r 'fromjson? | (.conversation_id // .conversationId // .session_id // .sessionId // .step_update.conversation_id // .result.conversation_id // empty)' "$events_file" 2>/dev/null || true)
  printf '%s' "$id"
}

parse_reset_wait_seconds() {
  local raw="" dur="" h=0 m=0 s=0
  raw="$("$GREP_BIN" -hoiE 'resets in[[:space:]]+[0-9]+[hms]([0-9]+[ms])*' "$@" 2>/dev/null | "$GREP_BIN" -m 1 -oiE '[0-9]+[hms]([0-9]+[ms])*$' || true)"
  [[ -n "$raw" ]] || return 1
  dur="$raw"
  if [[ "$dur" =~ ([0-9]+)[hH] ]]; then h=$((10#${BASH_REMATCH[1]})); fi
  if [[ "$dur" =~ ([0-9]+)[mM] ]]; then m=$((10#${BASH_REMATCH[1]})); fi
  if [[ "$dur" =~ ([0-9]+)[sS] ]]; then s=$((10#${BASH_REMATCH[1]})); fi
  local total=$(( h * 3600 + m * 60 + s ))
  (( total > 0 )) || return 1
  printf '%s' "$total"
}

write_session_meta() {
  local meta_file="$1"
  local issue_num="$2"
  local title="$3"
  local url="$4"
  local issue_state="$5"
  local labels="$6"
  local branch="$7"
  local wt_dir="$8"
  local conv_id="$9"
  local pr_url="${10}"
  local run_status="${11}"
  local updated_at="${12}"

  local transcript_hint=""
  local resume_cmd=""
  if [[ -n "$conv_id" ]]; then
    transcript_hint="${HOME}/.gemini/antigravity-cli/brain/${conv_id}/.system_generated/logs/transcript.jsonl"
    resume_cmd="cd '${wt_dir}' && '${AGY_BIN}' --conversation '${conv_id}'"
  fi

  "$JQ_BIN" -n \
    --argjson number "$issue_num" \
    --arg title "$title" \
    --arg url "$url" \
    --arg state "$issue_state" \
    --arg labels "$labels" \
    --arg repo_root "$REPO_ROOT" \
    --arg branch "$branch" \
    --arg worktree "$wt_dir" \
    --arg model "$AGY_MODEL" \
    --arg conversation_id "$conv_id" \
    --arg pr_url "$pr_url" \
    --arg transcript_hint "$transcript_hint" \
    --arg resume_command "$resume_cmd" \
    --arg status "$run_status" \
    --arg updated_at "$updated_at" \
    '{
      issue_number: $number,
      title: $title,
      url: $url,
      issue_state: $state,
      labels: $labels,
      repo_root: $repo_root,
      branch: $branch,
      worktree: $worktree,
      model: $model,
      conversation_id: $conversation_id,
      pr_url: $pr_url,
      transcript_hint: $transcript_hint,
      resume_command: $resume_command,
      status: $status,
      updated_at: $updated_at
    }' > "$meta_file"
}

post_status_comment() {
  local kind="$1"
  local target_num="$2"
  local status_label="$3"
  local branch="$4"
  local conv_id="$5"
  local pr_url="$6"
  local detail="$7"
  local now_ts
  now_ts="$("$DATE_BIN" --iso-8601=seconds)"

  [[ "$GH_SYNC_ENABLED" == "1" ]] || return 0

  local comment_body
  comment_body="$("$CAT_BIN" <<EOF
### agy 自动开发状态

| 字段 | 值 |
| --- | --- |
| 状态 | \`${LABEL_PREFIX}${status_label}\` |
| 分支 | \`${branch}\` |
| PR | ${pr_url:-"(暂未创建)"} |
| 会话 ID | \`${conv_id:-"(待生成)"}\` |
| 更新时间 | ${now_ts} |

${detail}
EOF
)"
  printf '%s\n' "$comment_body" | gh_state comment "$kind" "$target_num" - || true
}

consecutive_poll_errors=0
idle_announced=0
quota_wait_announced=0
ACTIVITY_LOG="${STATE_ROOT}/activity.log"
QUOTA_COOLDOWN_FILE="${STATE_ROOT}/quota_reset_until"

while true; do
  # 若启动时初始化标签失败，在网络恢复后补初始化一次
  if [[ "$GH_SYNC_ENABLED" == "1" && "$INIT_LABELS" == "1" && "$LABELS_READY" == "0" ]]; then
    if gh_state init-labels; then
      LABELS_READY=1
    fi
  fi

  # 若处于持久化全局 429 配额冷却期内，暂停认领任何 Issue，到期后自动恢复队列续接
  if [[ -s "$QUOTA_COOLDOWN_FILE" ]]; then
    IFS= read -r reset_epoch < "$QUOTA_COOLDOWN_FILE" || true
    reset_epoch="${reset_epoch#"${reset_epoch%%[![:space:]]*}"}"
    reset_epoch="${reset_epoch%"${reset_epoch##*[![:space:]]}"}"
    now_epoch="$("$DATE_BIN" '+%s')"
    if [[ "$reset_epoch" =~ ^[0-9]+$ ]] && (( reset_epoch > now_epoch )); then
      remain=$(( reset_epoch - now_epoch ))
      reset_human="$("$DATE_BIN" -d "@${reset_epoch}" '+%F %T' 2>/dev/null || printf '%s' "$reset_epoch")"
      if (( quota_wait_announced == 0 )); then
        printf '[%s] 空闲等待中（全局配额冷却至 %s，剩余 %ss）：到期后将自动恢复认领与续接...\n' \
          "$("$DATE_BIN" '+%F %T')" "$reset_human" "$remain"
        quota_wait_announced=1
      fi
      idle_announced=0
      chunk=$(( remain < POLL_INTERVAL ? remain : POLL_INTERVAL ))
      (( chunk < 1 )) && chunk=1
      "$SLEEP_BIN" "$chunk"
      continue
    else
      : > "$QUOTA_COOLDOWN_FILE"
      printf '[%s] 全局配额冷却已到期，恢复自动认领与续接队列...\n' "$("$DATE_BIN" '+%F %T')"
      quota_wait_announced=0
      idle_announced=0
    fi
  fi

  # 通过 gh-state.sh 拉取待处理 issue 列表（优先接回评审打回的 changes-requested，再拉取 todo）
  issues_json="[]"
  picked_from_changes_requested=0
  poll_failed=0

  if [[ "$GH_SYNC_ENABLED" == "1" && "$HANDLE_CHANGES_REQUESTED" == "1" ]]; then
    cr_json=""
    if cr_json="$(gh_state list-issues "$ISSUE_STATE" "${LABEL_PREFIX}changes-requested" "$ISSUE_LIMIT")" \
      && "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$cr_json"; then
      if "$JQ_BIN" -e 'length > 0' >/dev/null 2>&1 <<<"$cr_json"; then
        issues_json="$cr_json"
        picked_from_changes_requested=1
      fi
    else
      poll_failed=1
    fi
  fi

  if (( poll_failed == 0 && picked_from_changes_requested == 0 )); then
    if ! issues_json="$(gh_state list-issues "$ISSUE_STATE" "$FILTER_LABEL" "$ISSUE_LIMIT")" \
      || ! "$JQ_BIN" -e 'type == "array"' >/dev/null 2>&1 <<<"$issues_json"; then
      poll_failed=1
    fi
  fi

  if (( poll_failed == 1 )); then
    consecutive_poll_errors=$((consecutive_poll_errors + 1))
    wait_sec="$(calc_backoff "$consecutive_poll_errors")"
    printf '[%s] 警告：拉取 issue 列表失败（连续第 %d 次），%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$consecutive_poll_errors" "$wait_sec" >&2
    "$SLEEP_BIN" "$wait_sec"
    continue
  fi
  consecutive_poll_errors=0

  # 按编号升序（FIFO）找出第一条待处理的 issue
  next_issue_json=""
  while IFS= read -r row; do
    num="$("$JQ_BIN" -r '.number' <<<"$row")"
    if (( picked_from_changes_requested == 1 || USE_LOCAL_DEDUP == 0 )) || ! "$GREP_BIN" -qx "$num" "$STATE_FILE"; then
      next_issue_json="$row"
      break
    fi
  done < <("$JQ_BIN" -c 'sort_by(.number) | .[]' <<<"$issues_json")

  if [[ -z "$next_issue_json" ]]; then
    if (( idle_announced == 0 )); then
      printf '[%s] 空闲等待中：暂无待处理 issue（每 %ss 后台轮询一次）...\n' "$("$DATE_BIN" '+%F %T')" "$POLL_INTERVAL"
      idle_announced=1
    fi
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi
  idle_announced=0
  task_start_sec=$SECONDS

  # 提取 issue 字段
  number="$("$JQ_BIN" -r '.number' <<<"$next_issue_json")"
  state="$("$JQ_BIN" -r '.state' <<<"$next_issue_json")"
  title="$("$JQ_BIN" -r '.title' <<<"$next_issue_json")"
  url="$("$JQ_BIN" -r '.url' <<<"$next_issue_json")"
  labels="$("$JQ_BIN" -r '([.labels[].name] | join(", ")) // "(none)"' <<<"$next_issue_json")"
  body="$("$JQ_BIN" -r '.body // "(empty)"' <<<"$next_issue_json")"

  wt_dir_expected="${WORKTREE_ROOT}/issue-${number}"
  session_dir="${SESSIONS_ROOT}/issue-${number}"
  "$MKDIR_BIN" -p "$session_dir"

  run_ts="$("$DATE_BIN" '+%Y%m%d-%H%M%S')"
  iso_now="$("$DATE_BIN" --iso-8601=seconds)"
  branch_name_file="${session_dir}/branch_name"
  branch="$(resolve_existing_issue_branch "$number" "$session_dir" "$wt_dir_expected")"
  if [[ -z "$branch" ]]; then
    branch="_gongcao-wip/work-${run_ts}"
  fi

  prompt_file="${session_dir}/prompt.md"
  run_prompt_file="${session_dir}/prompt-${run_ts}.md"
  summary_file="${session_dir}/summary.md"
  blocked_file="${session_dir}/blocked.md"
  commit_msg_file="${session_dir}/commit-message.txt"
  # 沙箱内 agy 默认可写 /tmp 与当前 worktree；元信息文件写到 /tmp 避免污染 worktree 的 git status
  summary_tmp="/tmp/agy-summary-${REPO_SLUG}-${number}-${run_ts}.md"
  blocked_tmp="/tmp/agy-blocked-${REPO_SLUG}-${number}-${run_ts}.md"
  commit_msg_tmp="/tmp/agy-commit-msg-${REPO_SLUG}-${number}-${run_ts}.txt"
  branch_name_tmp="/tmp/agy-branch-name-${REPO_SLUG}-${number}-${run_ts}.txt"
  pr_body_file="${session_dir}/pr-body.md"
  events_file="${session_dir}/events.jsonl"
  run_events_file="${session_dir}/events-${run_ts}.jsonl"
  cli_log_file="${session_dir}/agy-cli-${run_ts}.log"
  conv_id_file="${session_dir}/conversation_id"
  meta_file="${session_dir}/meta.json"

  # 清空上一轮的缓存，避免误复用旧状态
  : > "$summary_file"
  : > "$blocked_file"
  : > "$commit_msg_file"
  : > "$summary_tmp"
  : > "$blocked_tmp"
  : > "$commit_msg_tmp"
  : > "$branch_name_tmp"

  base_ref="$(resolve_base_ref)"
  pr_base_branch="$(strip_origin_prefix "$base_ref")"

  printf '[%s] 准备 Issue #%s 的独立 worktree (base=%s, branch=%s)...\n' "$("$DATE_BIN" '+%F %T')" "$number" "$base_ref" "$branch"
  if ! wt_dir="$(ensure_worktree "$number" "$branch" "$base_ref")"; then
    printf '[%s] 警告：为 Issue #%s 准备 worktree 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$number" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi
  if ! is_placeholder_or_legacy_branch "$branch"; then
    printf '%s\n' "$branch" > "$branch_name_file"
  fi

  # 同步最新基准分支到当前 worktree；若产生合并冲突，保留冲突标记并交给 agy 解决
  conflict_list_file="${session_dir}/merge-conflicts-${run_ts}.txt"
  if ! prepare_base_merge "$wt_dir" "$base_ref" "$conflict_list_file"; then
    printf '[%s] 警告：为 Issue #%s 同步主干 %s 失败，%ss 后重试...\n' \
      "$("$DATE_BIN" '+%F %T')" "$number" "$base_ref" "$POLL_INTERVAL" >&2
    "$SLEEP_BIN" "$POLL_INTERVAL"
    continue
  fi

  merge_conflict_section=""
  if [[ -s "$conflict_list_file" ]]; then
    conflict_files_md=""
    while IFS= read -r cf; do
      [[ -z "$cf" ]] && continue
      conflict_files_md+="- \`${cf}\`"$'\n'
    done < "$conflict_list_file"
    merge_conflict_section=$'\n\n'"### 必须先解决的 Git 合并冲突（合入 ${base_ref} 产生）"$'\n'"当前 worktree 正在合并最新基准分支 \`${base_ref}\`，以下文件存在冲突标记（\`<<<<<<<\` / \`=======\` / \`>>>>>>>\`）："$'\n'"${conflict_files_md}请完整解决全部冲突标记（同时保留主干 \`${base_ref}\` 的新变更与本 Issue 的有效修复），完成后再继续处理反馈并运行内部验证；不要执行 \`git commit\`，外层宿主机脚本会在你解决完毕后自动完成合并提交。"
  fi

  # 读取已有会话 ID（若存在则自动续接）
  existing_conv_id=""
  if [[ -s "$conv_id_file" ]]; then
    IFS= read -r existing_conv_id < "$conv_id_file" || true
  fi

  # 1. 认领 Issue：将远端状态切为 in-progress 并更新置顶评论
  if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    if ! gh_state set-state issue "$number" in-progress; then
      printf '[%s] 警告：认领 Issue #%s（切换 in-progress）失败，%ss 后重试...\n' \
        "$("$DATE_BIN" '+%F %T')" "$number" "$POLL_INTERVAL" >&2
      "$SLEEP_BIN" "$POLL_INTERVAL"
      continue
    fi
    post_status_comment issue "$number" "in-progress" "$branch" "$existing_conv_id" "" \
      "Agent 已认领该 Issue，正在独立 worktree 中分析与开发。"
  fi

  # 若本轮是评审、E2E 或终审打回（changes-requested），拉取最新反馈注入 prompt
  review_feedback_section=""
  if (( picked_from_changes_requested == 1 )) && [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    review_feedback="$(gh_state get-comment issue "$number" "$REVIEW_COMMENT_MARKER" 2>/dev/null || true)"
    e2e_feedback="$(gh_state get-comment issue "$number" "$E2E_COMMENT_MARKER" 2>/dev/null || true)"
    final_gate_feedback="$(gh_state get-comment issue "$number" "$FINAL_GATE_COMMENT_MARKER" 2>/dev/null || true)"
    if [[ -n "$review_feedback" ]]; then
      review_feedback_section+=$'\n\n'"### 独立代码评审反馈（请优先逐项修复以下阻塞问题）"$'\n'"${review_feedback}"
    fi
    if [[ -n "$e2e_feedback" ]]; then
      review_feedback_section+=$'\n\n'"### 独立 E2E 验收反馈（请重点修复以下端到端失败项）"$'\n'"${e2e_feedback}"
    fi
    if [[ -n "$final_gate_feedback" ]]; then
      review_feedback_section+=$'\n\n'"### 终审合入门禁反馈（请优先修复以下终审阻塞项）"$'\n'"${final_gate_feedback}"
    fi
  fi

  branch_prompt_line=""
  if is_placeholder_or_legacy_branch "$branch"; then
    branch_prompt_line=$'\n'"   - **务必**生成一个简短有意义的英文语义 Git 分支名（格式 \`<type>/<kebab-slug>\`，type 仅限 \`fix|feat|docs|refactor|test|chore|perf\`，例如 \`fix/pg-zero-column-compare\`、\`docs/sync-offline-user-guide\`；**严禁包含任何 Issue 或 PR 编号**，仅用小写字母、数字和 \`-\`，总长不超过 60 字符），仅写一行到 ${branch_name_tmp}。"
  fi

  prompt="$("$CAT_BIN" <<EOF
请处理以下 GitHub Issue：

- 编号: #${number}
- 链接: ${url}
- 状态: ${state}
- 标签: ${labels}
- 标题: ${title}
- 工作分支: ${branch}
- Worktree 目录: ${wt_dir}

### Issue 内容
${body}${merge_conflict_section}${review_feedback_section}

### 处理要求
1. 你当前运行在专属 git worktree（分支 ${branch}）的沙箱中，先阅读相关代码并分析问题根因或需求范围。
2. 仅完成开发实现和相关内部验证（如类型检查、构建检查、改动相关的单元测试或模块级测试）。
3. **不需要执行 E2E（端到端）验证**（例如浏览器自动化 E2E、启动完整外部依赖服务或全链路集成环境测试）；不要在 E2E 环境准备上耗费时间。
   - **可复用 E2E 入口资产沉淀**：若本次 Issue 引入**新的用户可见页面流程**、目标仓库维护了可复用的 QA/E2E 入口（如 \`qa/README.md\` 登记的 action 目录或维护中的 Playwright spec）、且原始 Issue 未禁止改动 \`qa/\`，当既有入口尚未覆盖时，应按仓库 \`REUSE / EXTEND\` 规范在当前 PR 中对既有入口/驱动做**最小可复用扩展**（不另建新 QA 框架），开发期仅执行其静态/语法/入口守卫/路由单测或类型检查（不要启动真实引擎或浏览器实跑），并在总结中写明供下游 \`codex-e2e\` 直接调用的命令；若已有入口覆盖、属纯后端/文档/小修，或 Issue 明确要求不改动 \`qa/\`，则保持不动。
4. **不要执行 git add / git commit / git push，也不要修改 GitHub Issue/PR 状态**：沙箱内 .git 为只读，代码提交、推送与 PR 创建全部由外层宿主机脚本自动完成。
5. 正常完成开发与内部验证后：
   - 将本次改动的简明中文总结（改动文件、已执行的内部验证结果、显式标注 E2E 未执行，以及潜在风险）写入 ${summary_tmp}；
   - 可选：将一行简明的英文/中文 commit message 写入 ${commit_msg_tmp}。${branch_prompt_line}
6. **如果工作遇到阻塞无法继续**（例如需求不明确、缺少必要凭证/依赖、内部验证无法通过且无法在当前范围内修复）：
   - 立即停止修改，不要强行凑合；
   - 将具体的阻塞原因与需要人工提供的信息写入 ${blocked_tmp}（外层脚本会据此停止推进并自动更新 Issue/PR 为 blocked 状态）。
7. 不要把 /tmp 下的总结或状态文件复制到仓库目录中。
EOF
)"

  printf '%s\n' "$prompt" > "$prompt_file"
  printf '%s\n' "$prompt" > "$run_prompt_file"

  write_session_meta "$meta_file" "$number" "$title" "$url" "$state" "$labels" \
    "$branch" "$wt_dir" "$existing_conv_id" "" "in-progress" "$iso_now"

  # 2. 在独立 worktree 内执行 agy，若触发 --print-timeout 超时或 429 配额限流则在上限内自动续接原会话重试
  agy_start_sec=$SECONDS
  run_ok=0
  timed_out=0
  timeout_retries=0
  quota_hit=0
  quota_deferred=0
  quota_wait_exceeded=0
  quota_retries=0
  last_quota_wait=0
  quota_reset_epoch=0
  quota_reset_human=""
  attempt=0
  max_t_retries=0
  [[ "$MAX_TIMEOUT_RETRIES" =~ ^[0-9]+$ ]] && max_t_retries="$MAX_TIMEOUT_RETRIES"
  max_q_retries=0
  [[ "$MAX_QUOTA_RETRIES" =~ ^[0-9]+$ ]] && max_q_retries="$MAX_QUOTA_RETRIES"
  current_conv_id="$existing_conv_id"
  current_prompt="$prompt"

  while true; do
    attempt=$((attempt + 1))
    attempt_events_file="${session_dir}/events-${run_ts}-try${attempt}.jsonl"
    attempt_stderr_file="${session_dir}/stderr-${run_ts}-try${attempt}.log"
    attempt_cli_log="${session_dir}/agy-cli-${run_ts}-try${attempt}.log"

    agy_args=(
      -p "$current_prompt"
      --mode "$AGY_MODE"
      --sandbox
      --print-timeout "$PRINT_TIMEOUT"
      --output-format stream-json
      --log-file "$attempt_cli_log"
    )
    if [[ "$AGY_SKIP_PERMISSIONS" == "1" ]]; then
      agy_args+=(--dangerously-skip-permissions)
    fi
    if [[ -n "$AGY_MODEL" ]]; then
      agy_args+=(--model "$AGY_MODEL")
    fi
    if [[ -n "$AGY_EFFORT" ]]; then
      agy_args+=(--effort "$AGY_EFFORT")
    fi
    if [[ -n "$current_conv_id" ]]; then
      agy_args=(--conversation "$current_conv_id" "${agy_args[@]}")
      printf '[%s] 续接 Issue #%s 历史会话 (%s, 第 %d 次尝试)，worktree: %s\n' \
        "$("$DATE_BIN" '+%F %T')" "$number" "$current_conv_id" "$attempt" "$wt_dir"
    else
      printf '[%s] 启动 Issue #%s 新会话 (第 %d 次尝试)，worktree: %s\n' \
        "$("$DATE_BIN" '+%F %T')" "$number" "$attempt" "$wt_dir"
    fi

    attempt_ok=0
    if (cd -- "$wt_dir" && "$AGY_BIN" "${agy_args[@]}" 2>"$attempt_stderr_file") | "$TEE_BIN" "$attempt_events_file" >> "$events_file"; then
      attempt_ok=1
    fi

    if (( attempt_ok == 0 )) && [[ -s "$attempt_stderr_file" ]]; then
      "$CAT_BIN" "$attempt_stderr_file" >&2
    fi

    # 每次尝试后立即提取并持久化 conversation_id（供超时续接或人工接管）
    new_conv_id="$(extract_conversation_id "$attempt_events_file")"
    if [[ -n "$new_conv_id" ]]; then
      current_conv_id="$new_conv_id"
      printf '%s\n' "$current_conv_id" > "$conv_id_file"
    fi

    if (( attempt_ok == 1 )); then
      run_ok=1
      break
    fi

    # 若 Agent 已主动写入 blocked 文件，不再重试
    if [[ -s "$blocked_tmp" ]]; then
      break
    fi

    is_timeout=0
    if "$GREP_BIN" -qE '"reason":"print_timeout"|"status":"DEADLINE_EXCEEDED"|print timeout after' "$attempt_stderr_file" "$attempt_events_file" 2>/dev/null; then
      is_timeout=1
      timed_out=1
    fi

    is_quota_error=0
    if "$GREP_BIN" -qiE 'RESOURCE_EXHAUSTED|"error_code":429|code 429|Individual quota reached|rate limit' "$attempt_stderr_file" "$attempt_events_file" 2>/dev/null; then
      is_quota_error=1
      quota_hit=1
    fi

    is_retryable_api_error=0
    if (( is_quota_error == 0 && is_timeout == 0 )) && "$GREP_BIN" -qE '"retryable":true' "$attempt_stderr_file" "$attempt_events_file" 2>/dev/null; then
      is_retryable_api_error=1
    fi

    if (( is_timeout == 1 && timeout_retries < max_t_retries )); then
      timeout_retries=$((timeout_retries + 1))
      printf '[%s] 警告：Issue #%s 第 %d 次执行触发 --print-timeout (%s) 超时，3s 后自动续接原会话 (%s) 重试（第 %d/%d 次重试）...\n' \
        "$("$DATE_BIN" '+%F %T')" "$number" "$attempt" "$PRINT_TIMEOUT" "${current_conv_id:-new}" "$timeout_retries" "$max_t_retries" >&2
      if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
        post_status_comment issue "$number" "in-progress" "$branch" "$current_conv_id" "" \
          "第 ${attempt} 次执行触发 ${PRINT_TIMEOUT} 超时，已保留全部代码进度并自动续接原会话重试（第 ${timeout_retries}/${max_t_retries} 次重试）。"
      fi
      current_prompt="$("$CAT_BIN" <<EOF
上一次执行因达到 ${PRINT_TIMEOUT} 超时限制（--print-timeout）被中断，这是第 ${timeout_retries}/${max_t_retries} 次自动续接重试。

### 重要续接要求
1. 你仍在原 worktree（\`${wt_dir}\`）及分支（\`${branch}\`）中，**前面已完成的代码修改全部保留在工作区**，不要从头推倒重做。
2. 请先运行 \`git status\` 和 \`git diff --stat\` 核对已有改动，从中断处继续完成剩余修改与必要的内部验证（不要运行 E2E，也不要执行 \`git add / git commit / git push\`）。
3. 完成后将简明中文总结写入 ${summary_tmp}（可选：commit message 写入 ${commit_msg_tmp}）；若确有阻塞无法继续，将阻塞原因写入 ${blocked_tmp}。${branch_prompt_line}
EOF
)"
      "$SLEEP_BIN" 3
      continue
    fi

    if (( is_quota_error == 1 )); then
      wait_sec="$QUOTA_DEFAULT_WAIT_SEC"
      if parsed_wait="$(parse_reset_wait_seconds "$attempt_stderr_file" "$attempt_events_file")"; then
        wait_sec=$(( parsed_wait + QUOTA_RETRY_BUFFER_SEC ))
      fi
      last_quota_wait="$wait_sec"
      if (( wait_sec > MAX_QUOTA_WAIT_SEC )); then
        quota_wait_exceeded=1
        printf '[%s] 警告：Issue #%s 触发配额限流，预计冷却 %ss 超过自动等待上限 %ss，停止自动等待并转 blocked。\n' \
          "$("$DATE_BIN" '+%F %T')" "$number" "$wait_sec" "$MAX_QUOTA_WAIT_SEC" >&2
        break
      elif (( wait_sec > QUOTA_INLINE_WAIT_MAX_SEC || quota_retries >= max_q_retries )); then
        quota_deferred=1
        now_epoch="$("$DATE_BIN" '+%s')"
        quota_reset_epoch=$(( now_epoch + wait_sec ))
        quota_reset_human="$("$DATE_BIN" -d "@${quota_reset_epoch}" '+%F %T' 2>/dev/null || printf '%s' "$quota_reset_epoch")"
        if [[ "$DRY_RUN" != "1" ]]; then
          printf '%s\n' "$quota_reset_epoch" > "$QUOTA_COOLDOWN_FILE"
        fi
        printf '[%s] 警告：Issue #%s 触发配额限流（预计冷却 %ss -> 至 %s），已登记全局冷却并自动退回原队列等待到期续接。\n' \
          "$("$DATE_BIN" '+%F %T')" "$number" "$wait_sec" "$quota_reset_human" >&2
        break
      else
        quota_retries=$((quota_retries + 1))
        printf '[%s] 警告：Issue #%s 第 %d 次执行触发 HTTP 429 / RESOURCE_EXHAUSTED 配额限流，等待 %ss 后自动续接原会话 (%s) 重试（第 %d/%d 次配额等待）...\n' \
          "$("$DATE_BIN" '+%F %T')" "$number" "$attempt" "$wait_sec" "${current_conv_id:-new}" "$quota_retries" "$max_q_retries" >&2
        if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
          post_status_comment issue "$number" "in-progress" "$branch" "$current_conv_id" "" \
            "第 ${attempt} 次执行触发配额限流（HTTP 429 / RESOURCE_EXHAUSTED），已保留全部进度与会话，等待 ${wait_sec}s 后自动续接重试（第 ${quota_retries}/${max_q_retries} 次配额等待）。"
        fi
        "$SLEEP_BIN" "$wait_sec"
        continue
      fi
    fi

    if (( is_retryable_api_error == 1 && quota_retries < max_q_retries )); then
      quota_retries=$((quota_retries + 1))
      wait_sec=$(( 30 * quota_retries ))
      (( wait_sec > 300 )) && wait_sec=300
      printf '[%s] 警告：Issue #%s 第 %d 次执行遇到可重试接口异常，%ss 后自动续接原会话 (%s) 重试（第 %d/%d 次）...\n' \
        "$("$DATE_BIN" '+%F %T')" "$number" "$attempt" "$wait_sec" "${current_conv_id:-new}" "$quota_retries" "$max_q_retries" >&2
      "$SLEEP_BIN" "$wait_sec"
      continue
    fi

    break
  done

  final_conv_id="$current_conv_id"
  agy_elapsed=$((SECONDS - agy_start_sec))
  printf '[%s] Issue #%s agy 执行结束 (ok=%d, 超时重试=%d/%d, 限流重试=%d/%d, 耗时 %ds)，开始后处理（commit / push / 更新状态）...\n' \
    "$("$DATE_BIN" '+%F %T')" "$number" "$run_ok" "$timeout_retries" "$max_t_retries" "$quota_retries" "$max_q_retries" "$agy_elapsed"

  summary_text=""
  if [[ -s "$summary_tmp" ]]; then
    "$CAT_BIN" "$summary_tmp" > "$summary_file"
    summary_text="$("$CAT_BIN" "$summary_file")"
  fi

  blocked_reason=""
  if [[ -s "$blocked_tmp" ]]; then
    "$CAT_BIN" "$blocked_tmp" > "$blocked_file"
    blocked_reason="$("$CAT_BIN" "$blocked_file")"
  fi

  commit_msg=""
  if [[ -s "$commit_msg_tmp" ]]; then
    "$CAT_BIN" "$commit_msg_tmp" > "$commit_msg_file"
    IFS= read -r commit_msg < "$commit_msg_file" || true
  fi
  [[ -z "$commit_msg" ]] && commit_msg="fix(#${number}): ${title}"

  # 3. 根据执行结果：阻塞则立即停止并更新 Issue/PR；正常则由宿主机自动 commit -> push -> Draft PR
  pr_url=""
  existing_pr_num=""
  existing_pr_url=""
  if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    pr_lookup="$(gh_state find-pr "$branch" 2>/dev/null || true)"
    if [[ -n "$pr_lookup" ]]; then
      existing_pr_num="${pr_lookup%%$'\t'*}"
      existing_pr_url="${pr_lookup#*$'\t'}"
      pr_url="$existing_pr_url"
    fi
  fi

  final_status="blocked"
  status_detail=""
  merge_in_progress=0
  if "$GIT_BIN" -C "$wt_dir" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
    merge_in_progress=1
  fi

  if (( run_ok == 0 )); then
    (( merge_in_progress == 1 )) && "$GIT_BIN" -C "$wt_dir" merge --abort >/dev/null 2>&1 || true
    final_status="blocked"
    if (( quota_deferred == 1 )); then
      if (( picked_from_changes_requested == 1 )); then
        final_status="changes-requested"
      else
        final_status="todo"
      fi
      status_detail="Agent 触发配额限流（HTTP 429 / RESOURCE_EXHAUSTED），预计冷却 ${last_quota_wait}s；已登记全局冷却至 ${quota_reset_human} 并保留 worktree 与会话记录（${final_conv_id:-new}），已自动退回 \`${LABEL_PREFIX}${final_status}\` 队列，配额恢复到期后将自动续接原会话继续执行。${blocked_reason:+$'\n\n'"### 阻塞原因"$'\n'"${blocked_reason}"}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
    elif (( quota_wait_exceeded == 1 )); then
      status_detail="Agent 触发配额限流（HTTP 429 / RESOURCE_EXHAUSTED），预计重置等待 ${last_quota_wait}s 超过自动等待上限（${MAX_QUOTA_WAIT_SEC}s），已暂停并保留 worktree 与会话记录；配额恢复后将标签改回 \`${LABEL_PREFIX}todo\` 可自动续接原会话。${blocked_reason:+$'\n\n'"### 阻塞原因"$'\n'"${blocked_reason}"}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
    elif (( quota_hit == 1 )); then
      status_detail="Agent 多次触发配额限流（HTTP 429 / RESOURCE_EXHAUSTED）并已耗尽自动冷却重试（${quota_retries}/${max_q_retries} 次），已暂停并保留 worktree 与会话记录；配额恢复后将标签改回 \`${LABEL_PREFIX}todo\` 可自动续接原会话。${blocked_reason:+$'\n\n'"### 阻塞原因"$'\n'"${blocked_reason}"}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
    elif (( timed_out == 1 )); then
      status_detail="Agent 执行多次触及 ${PRINT_TIMEOUT} 超时限制并已耗尽自动重试（${timeout_retries}/${max_t_retries} 次），已停止推进并保留 worktree 与会话记录；可将标签改回 \`${LABEL_PREFIX}todo\` 从当前进度继续续接。${blocked_reason:+$'\n\n'"### 阻塞原因"$'\n'"${blocked_reason}"}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
    else
      status_detail="Agent 执行异常退出，已停止推进并保留 worktree 与会话记录；排查或补充信息后将标签改回 \`${LABEL_PREFIX}todo\` 可自动续接原会话。${blocked_reason:+$'\n\n'"### 阻塞原因"$'\n'"${blocked_reason}"}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
    fi
  elif [[ -n "$blocked_reason" ]]; then
    (( merge_in_progress == 1 )) && "$GIT_BIN" -C "$wt_dir" merge --abort >/dev/null 2>&1 || true
    final_status="blocked"
    status_detail="Agent 报告工作阻塞并已主动停止，未自动提交或推送。补充信息后将标签改回 \`${LABEL_PREFIX}todo\` 可自动续接原会话。"$'\n\n'"### 阻塞原因"$'\n'"${blocked_reason}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
  else
    # 若存在正在进行的合并，先校验所有冲突文件中不再残留冲突标记
    unresolved_conflicts=""
    if (( merge_in_progress == 1 )) && [[ -s "$conflict_list_file" ]]; then
      while IFS= read -r cf; do
        [[ -z "$cf" ]] && continue
        if [[ -f "${wt_dir}/${cf}" ]] && "$GREP_BIN" -qE '^(<<<<<<< |=======$|>>>>>>> )' "${wt_dir}/${cf}"; then
          unresolved_conflicts+="- \`${cf}\`"$'\n'
        fi
      done < "$conflict_list_file"
    fi

    if [[ -n "$unresolved_conflicts" ]]; then
      "$GIT_BIN" -C "$wt_dir" merge --abort >/dev/null 2>&1 || true
      final_status="blocked"
      status_detail="合并 \`${base_ref}\` 后仍存在未解决的冲突标记，已自动中止合并并停止推送："$'\n'"${unresolved_conflicts}${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
    else
      # 正常完成：若处于合并状态或有文件改动，由宿主机自动暂存并提交到当前分支
      dirty_files="$("$GIT_BIN" -C "$wt_dir" status --porcelain 2>/dev/null || true)"
      commit_ok=1
      if (( merge_in_progress == 1 )); then
        if ! "$GIT_BIN" -C "$wt_dir" add -A >&2 || ! "$GIT_BIN" -C "$wt_dir" commit --no-edit >&2; then
          "$GIT_BIN" -C "$wt_dir" merge --abort >/dev/null 2>&1 || true
          commit_ok=0
        fi
      elif [[ -n "$dirty_files" ]]; then
        if ! "$GIT_BIN" -C "$wt_dir" add -A >&2 || ! "$GIT_BIN" -C "$wt_dir" commit -m "$commit_msg" >&2; then
          commit_ok=0
        fi
      fi

      if (( commit_ok == 0 )); then
        final_status="blocked"
        status_detail="Agent 已修改代码，但宿主机自动 \`git commit\` 失败（请检查 git user.name/email 或 pre-commit hook），已停止推送。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
      else
        commits_ahead="$("$GIT_BIN" -C "$wt_dir" rev-list --count "${base_ref}..HEAD" 2>/dev/null || printf '0')"
        if (( commits_ahead > 0 )); then
          proposed_branch=""
          if [[ -s "$branch_name_tmp" ]]; then
            while IFS= read -r _bline; do
              _bline="${_bline#"${_bline%%[![:space:]]*}"}"
              _bline="${_bline%"${_bline##*[![:space:]]}"}"
              if [[ -n "$_bline" ]]; then
                proposed_branch="$_bline"
                break
              fi
            done < "$branch_name_tmp"
          fi

          # 仅在首次推送前且尚未关联远端 PR/分支时，将临时占位或遗留 agy/issue-* 分支规范命名为无编号语义分支
          if is_placeholder_or_legacy_branch "$branch" && [[ -z "$existing_pr_num" ]] \
            && ! "$GIT_BIN" -C "$REPO_ROOT" show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
            semantic_branch="$(derive_semantic_branch "$proposed_branch" "$commit_msg" "$title" "$labels" "$number" "$wt_dir" "$base_ref")"
            if [[ -n "$semantic_branch" && "$semantic_branch" != "$branch" ]]; then
              if [[ "$DRY_RUN" == "1" ]]; then
                printf '[DRY_RUN] %s -C %q branch -m %q %q\n' "$GIT_BIN" "$wt_dir" "$branch" "$semantic_branch" >&2
                branch="$semantic_branch"
              else
                (
                  "$FLOCK_BIN" -x 9
                  "$GIT_BIN" -C "$wt_dir" branch -m "$branch" "$semantic_branch" >&2
                ) 9>"$REPO_GIT_LOCK"
                branch="$semantic_branch"
                printf '%s\n' "$branch" > "$branch_name_file"
                printf '[%s] Issue #%s 分支已规范命名为语义分支: %s\n' "$("$DATE_BIN" '+%F %T')" "$number" "$branch"
              fi
            fi
          fi

          if [[ "$GH_SYNC_ENABLED" == "1" && "$AUTO_PUSH_PR" == "1" ]]; then
            push_ok=0
            if [[ "$DRY_RUN" == "1" ]]; then
              printf '[DRY_RUN] %s -C %q push -u origin %q\n' "$GIT_BIN" "$wt_dir" "$branch" >&2
              push_ok=1
            elif "$GIT_BIN" -C "$wt_dir" push -u origin "$branch" >&2; then
              push_ok=1
            fi

            if (( push_ok == 1 )); then
              "$CAT_BIN" > "$pr_body_file" <<EOF
## Summary

${summary_text:-"Automated changes for issue #${number}."}

## Metadata
- Issue: #${number}
- Branch: \`${branch}\`
- Conversation ID: \`${final_conv_id:-"(none)"}\`
- Verification Scope: 仅完成开发实现与内部验证（未执行 E2E 验证）

Closes #${number}
EOF
              pr_title="fix(#${number}): ${title}"
              if pr_url="$(gh_state ensure-pr "$number" "$branch" "$pr_base_branch" "$pr_title" "$pr_body_file")"; then
                final_status="in-review"
                status_detail="已完成开发实现与内部验证，并自动提交推送、创建/更新 Draft PR（${commits_ahead} 个提交），等待人工 Review。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
              else
                final_status="blocked"
                status_detail="分支 \`${branch}\` 已推送，但创建/更新 Draft PR 失败，请人工检查。"
              fi
            else
              final_status="blocked"
              status_detail="本地已自动生成 ${commits_ahead} 个提交，但 \`git push origin ${branch}\` 失败，请人工检查权限或远端冲突。"
            fi
          else
            final_status="in-review"
            status_detail="本地 worktree 已自动生成 ${commits_ahead} 个提交（未启用自动推送/建 PR）。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
          fi
        else
          final_status="blocked"
          status_detail="Agent 执行结束但未产生任何代码改动或新提交，已停止建 PR；请人工确认后将标签改回 \`${LABEL_PREFIX}todo\`。${summary_text:+$'\n\n'"### 摘要"$'\n'"${summary_text}"}"
        fi
      fi
    fi
  fi

  finish_iso="$("$DATE_BIN" --iso-8601=seconds)"
  if [[ "$GH_SYNC_ENABLED" == "1" ]]; then
    post_status_comment issue "$number" "$final_status" "$branch" "$final_conv_id" "$pr_url" "$status_detail"
    gh_state set-state issue "$number" "$final_status" || true
    # 若阻塞且该分支已有对应 open PR，同步将 PR 标记为 blocked 并更新 PR 评论
    if [[ "$final_status" == "blocked" && -n "$existing_pr_num" ]]; then
      post_status_comment pr "$existing_pr_num" blocked "$branch" "$final_conv_id" "$existing_pr_url" "$status_detail"
      gh_state set-state pr "$existing_pr_num" blocked || true
    fi
  fi

  if [[ "$final_status" == "in-review" ]]; then
    if ! "$GREP_BIN" -qx "$number" "$STATE_FILE"; then
      printf '%s\n' "$number" >> "$STATE_FILE"
    fi
  fi

  write_session_meta "$meta_file" "$number" "$title" "$url" "$state" "$labels" \
    "$branch" "$wt_dir" "$final_conv_id" "$pr_url" "$final_status" "$finish_iso"

  total_elapsed=$((SECONDS - task_start_sec))
  end_ts="$("$DATE_BIN" '+%F %T')"
  printf '\n============================================================\n'
  printf '[%s] [DONE] Issue #%s 本轮处理结束 (耗时 %ds)\n' "$end_ts" "$number" "$total_elapsed"
  printf '  最终状态 : %s%s\n' "$LABEL_PREFIX" "$final_status"
  printf '  标题     : %s\n' "$title"
  printf '  Worktree : %s (分支 %s)\n' "$wt_dir" "$branch"
  [[ -n "$pr_url" ]] && printf '  Draft PR : %s\n' "$pr_url"
  printf '  会话记录 : %s\n' "$session_dir"
  if [[ -n "$final_conv_id" ]]; then
    printf '  人工接管 : cd %q && %q --conversation %q\n' "$wt_dir" "$AGY_BIN" "$final_conv_id"
  fi
  printf '============================================================\n\n'
  printf '[%s] [agy-dev] Issue #%s -> %s%s (%ds) %s\n' \
    "$end_ts" "$number" "$LABEL_PREFIX" "$final_status" "$total_elapsed" "${pr_url:-$branch}" >> "$ACTIVITY_LOG"

  "$SLEEP_BIN" 5
done
