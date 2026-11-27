#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin"

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

cat > "$fixture/bin/tmux" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
case "$1" in
  display-message)
    case "$*" in
      *'#{pane_pid}'*)
        if [[ -f "$MOCK_DIR/respawned" ]]; then printf '2002\n'; else printf '1001\n'; fi
        ;;
      *'#{pane_dead}'*)
        printf '0\n'
        ;;
    esac
    ;;
  capture-pane)
    cat "$MOCK_DIR/pane.txt"
    ;;
  respawn-pane)
    : > "$MOCK_DIR/respawned"
    printf 'respawn\n' >> "$MOCK_DIR/calls"
    ;;
  *) exit 99 ;;
esac
EOF

cat > "$fixture/bin/ps" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
cat "$MOCK_DIR/children.txt"
EOF

cat > "$fixture/bin/sleep" <<'EOF'
#!/usr/bin/bash
exit 0
EOF

chmod +x "$fixture/bin/"*
export MOCK_DIR="$fixture"
export PATH="$fixture/bin:$PATH"

run_expect_restart() {
  local name="$1"
  rm -f "$fixture/respawned" "$fixture/calls"
  HOT_RESTART_POLL_SEC=1 timeout 5s bash "$repo_dir/hot-restart-pane.sh" demo:dev 3 > "$fixture/out.log" 2>&1 \
    || { cat "$fixture/out.log" >&2; fail "$name 预期触发热重启但失败"; }
  [[ -f "$fixture/respawned" ]] || fail "$name 未执行 respawn-pane"
}

run_expect_wait() {
  local name="$1" rc=0
  rm -f "$fixture/respawned" "$fixture/calls"
  HOT_RESTART_POLL_SEC=1 timeout 5s bash "$repo_dir/hot-restart-pane.sh" demo:dev 2 > "$fixture/out.log" 2>&1 || rc=$?
  [[ "$rc" == "124" && ! -f "$fixture/respawned" ]] || { cat "$fixture/out.log" >&2; fail "$name 不应触发热重启 (rc=$rc)"; }
}

printf 'sleep\n' > "$fixture/children.txt"

# 1. 长期空闲后被 40 行 gh-state EOF 与拉取列表失败刷屏，仍应判定为安全空闲并热重启
{
  printf '[2026-11-26 18:00:00] 空闲等待中：暂无待处理 issue（每 60s 后台轮询一次）...\n'
  for _ in $(seq 1 20); do
    printf 'Post "https://api.github.com/graphql": EOF\n'
    printf '[gh-state] 警告：gh 调用失败 (exit=1, 第 1/3 次)，2s 后重试...\n'
  done
  printf '[2026-11-26 18:30:00] 警告：拉取待评审 PR 列表失败（连续第 1 次），60s 后重试...\n'
} > "$fixture/pane.txt"
run_expect_restart "idle-with-gh-eof-noise"

# 2. [DONE] 收尾期 -> 安全重启
cat > "$fixture/pane.txt" <<'EOF'
[2026-11-26 18:00:00] [DONE] PR #465 Codex 评审完成
  评审结论 : approve -> agy:approved
  评审报告 : /tmp/review.md
============================================================
EOF
run_expect_restart "done-boundary"

# 3. 任务中途触发配额限流原地等待（即使当前子进程是 sleep）-> 绝不能误重启
cat > "$fixture/pane.txt" <<'EOF'
[2026-11-26 18:00:00] 空闲等待中：暂无待处理 issue...
[2026-11-26 18:05:00] 启动 Issue #470 新会话 (第 1 次尝试)
[2026-11-26 18:06:00] 警告：Issue #470 第 1 次执行触发 HTTP 429 / RESOURCE_EXHAUSTED 配额限流，等待 120s 后自动续接原会话...
EOF
run_expect_wait "mid-task-quota-wait"

# 4. 任务中途评审交接失败等待重试 -> 绝不能误重启
cat > "$fixture/pane.txt" <<'EOF'
[2026-11-26 18:00:00] [DONE] PR #465 Codex 评审完成
[2026-11-26 18:10:00] 开始 Codex 独立评审 PR #468...
[2026-11-26 18:12:00] 警告：PR #468 评审交接失败，60s 后重试已保存的报告。
EOF
run_expect_wait "mid-task-handoff-retry"

# 5. 有非 sleep 子进程（如 codex / timeout）-> 绝不能误重启
printf 'timeout\n' > "$fixture/children.txt"
printf '[2026-11-26 18:00:00] 空闲等待中：暂无待处理 issue...\n' > "$fixture/pane.txt"
run_expect_wait "busy-child-process"

printf 'hot restart pane tests passed\n'
