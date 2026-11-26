# 评审 / E2E / 终审循环共享的精确提交检出助手。
# 严格按声明的 head_sha 检出 detached worktree，禁止静默回退 FETCH_HEAD，
# 并在仓库锁内断言实际 HEAD == head_sha。

checkout_exact_pr_worktree() {
  local wt_dir="$1"
  local pr_num="$2"
  local head_branch="$3"
  local head_sha="$4"

  if [[ -z "$head_sha" ]]; then
    printf '错误：PR #%s 缺少目标提交 SHA，拒绝检出。\n' "$pr_num" >&2
    return 1
  fi

  (
    "$FLOCK_BIN" -x 9 || exit 1
    "$GIT_BIN" -C "$REPO_ROOT" worktree prune >/dev/null 2>&1 || true
    "$GIT_BIN" -C "$REPO_ROOT" fetch --prune origin >&2 || true

    if ! "$GIT_BIN" -C "$REPO_ROOT" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
      "$GIT_BIN" -C "$REPO_ROOT" fetch origin "pull/${pr_num}/head" >&2 || \
        "$GIT_BIN" -C "$REPO_ROOT" fetch origin "$head_branch" >&2 || \
        "$GIT_BIN" -C "$REPO_ROOT" fetch origin "$head_sha" >&2 || true
    fi

    if ! "$GIT_BIN" -C "$REPO_ROOT" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
      printf '错误：远端未找到 PR #%s 声明的提交 %s，拒绝回退 FETCH_HEAD。\n' "$pr_num" "$head_sha" >&2
      exit 1
    fi

    if [[ -e "${wt_dir}/.git" ]]; then
      "$GIT_BIN" -C "$wt_dir" checkout --detach --force "$head_sha" >&2 || exit 1
      "$GIT_BIN" -C "$wt_dir" clean -fd >/dev/null 2>&1 || exit 1
    else
      "$GIT_BIN" -C "$REPO_ROOT" worktree add --detach "$wt_dir" "$head_sha" >&2 || exit 1
    fi

    local actual_sha=""
    actual_sha="$("$GIT_BIN" -C "$wt_dir" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$actual_sha" != "$head_sha" ]]; then
      printf '错误：PR #%s 工作树实际 HEAD (%s) 与目标提交 (%s) 不一致。\n' "$pr_num" "${actual_sha:-空}" "$head_sha" >&2
      exit 1
    fi
  ) 9>"$REPO_GIT_LOCK" || return 1

  printf '%s' "$wt_dir"
}
