#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/workflow/lib" "$fixture/home/codex" "$fixture/home/agy"
cp "$repo_dir"/*.sh "$fixture/workflow/"
cp "$repo_dir"/lib/*.sh "$fixture/workflow/lib/"

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

# 准备测试仓库与远端 bare origin
git init -q -b main "$fixture/repo"
git -C "$fixture/repo" config user.name Test
git -C "$fixture/repo" config user.email test@example.invalid
printf 'base\n' > "$fixture/repo/app.txt"
git -C "$fixture/repo" add app.txt
git -C "$fixture/repo" commit -qm initial
git clone -q --bare "$fixture/repo" "$fixture/origin"
git -C "$fixture/repo" remote add origin "$fixture/origin"
git -C "$fixture/repo" fetch -q origin

export MOCK_DIR="$fixture"
export REPO_DIR="$fixture/repo"
export REPO=example/issue-fixture
export GONGCAO_HOME="$fixture/home"
export INIT_LABELS=0
export POLL_INTERVAL=1
export PATH="$fixture/bin:$PATH"

cat > "$fixture/workflow/gh-state.sh" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
case "$*" in
  'list-issues '*'agy:changes-requested'*)
    printf '[]\n'
    ;;
  'list-issues '*'ready-for-agent'*)
    if [[ -f "$MOCK_DIR/ready-issues.json" ]]; then
      cat "$MOCK_DIR/ready-issues.json"
    else
      printf '[]\n'
    fi
    ;;
  'list-issues '*)
    cat "$MOCK_DIR/issues.json"
    ;;
  'set-state issue '*)
    printf '%s\n' "$*" >> "$MOCK_DIR/calls"
    ;;
  'comment issue '*)
    cat >/dev/null
    ;;
  'find-pr '*)
    ;;
  'ensure-pr '*)
    printf '%s\n' "$*" >> "$MOCK_DIR/calls"
    printf 'https://example.invalid/pull/99\n'
    ;;
  *)
    printf 'Unexpected gh-state call: %s\n' "$*" >&2
    exit 98
    ;;
esac
EOF

cat > "$fixture/bin/gh" <<'EOF'
#!/usr/bin/bash
case "$1" in
  --version) printf 'gh version 2.60.0-mock\n' ;;
  auth) exit 0 ;;
  *) exit 0 ;;
esac
EOF

cat > "$fixture/bin/codex" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'codex-cli 0.172.0-mock\n'
  exit 0
fi
printf '%s\n' "$*" >> "$MOCK_DIR/codex-args.log"
printf '%s\n' "${TMPDIR:-}" >> "$MOCK_DIR/codex-tmpdir.log"
if [[ -z "${TMPDIR:-}" || ! -d "${TMPDIR:-}" ]]; then
  printf 'Missing writable TMPDIR=%q\n' "${TMPDIR:-}" >&2
  exit 96
fi
out_file=""
while (( $# > 0 )); do
  if [[ "$1" == "-o" ]]; then
    out_file="$2"
    shift 2
  else
    shift
  fi
done
count=0
[[ -f "$MOCK_DIR/codex-count" ]] && count="$(<"$MOCK_DIR/codex-count")"
count=$((count + 1))
printf '%s\n' "$count" > "$MOCK_DIR/codex-count"
cat > "$MOCK_DIR/prompt-${count}.txt"
printf '{"type":"thread.started","thread_id":"thread-abc-123"}\n'

mode="$(<"$MOCK_DIR/codex-mode")"
case "$mode" in
  complete)
    printf 'change-%s\n' "$count" >> app.txt
    printf '{"status":"completed","summary":"已完成开发","blocked_reason":"","commit_message":"feat: mock change","branch_name":"feat/mock-codex"}\n' > "$out_file"
    ;;
  schema-retry)
    if (( count == 1 )); then
      printf 'schema-fix\n' >> app.txt
      printf '{"status":"completed","summary":"","blocked_reason":"","commit_message":"","branch_name":""}\n' > "$out_file"
    else
      printf '{"status":"completed","summary":"修正输出后完成","blocked_reason":"","commit_message":"feat: schema retry","branch_name":"feat/schema-retry"}\n' > "$out_file"
    fi
    ;;
  blocked)
    printf '{"status":"blocked","summary":"","blocked_reason":"缺少需求澄清","commit_message":"","branch_name":""}\n' > "$out_file"
    ;;
  timeout-then-ok)
    if (( count == 1 )); then
      printf 'partial-work\n' >> app.txt
      exit 124
    else
      printf '{"status":"completed","summary":"超时续接完成","blocked_reason":"","commit_message":"feat: timeout resume","branch_name":"feat/timeout-resume"}\n' > "$out_file"
    fi
    ;;
  quota-worded)
    printf 'Rate limit reached. Please try again in 10 minutes.\n' >&2
    exit 1
    ;;
  *)
    printf 'Unknown mode: %s\n' "$mode" >&2
    exit 99
    ;;
esac
EOF

cat > "$fixture/bin/agy" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf '1.5.18-mock\n'
  exit 0
fi
printf '%s\n' "agy-invoked" >> "$MOCK_DIR/calls"
printf '{"conversation_id":"conv-agy-1"}\n'
exit 1
EOF

cat > "$fixture/bin/sleep" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
if [[ "${1:-}" == "--version" ]]; then
  printf 'sleep 9.4-mock\n'
  exit 0
fi
count=0
[[ -f "$MOCK_DIR/sleep-count" ]] && count="$(<"$MOCK_DIR/sleep-count")"
count=$((count + 1))
printf '%s\n' "$count" > "$MOCK_DIR/sleep-count"
if (( count >= MOCK_SLEEPS )); then exit 91; fi
EOF

chmod +x "$fixture/workflow/gh-state.sh" "$fixture/bin/"*

run_dev_loop() {
  local engine="$1" sleeps="${2:-1}" rc=0
  shift 2 || true
  printf '0\n' > "$fixture/sleep-count"
  MOCK_SLEEPS="$sleeps" "$@" timeout 20s bash "$fixture/workflow/${engine}-issue-loop.sh" > "$fixture/loop.log" 2>&1 || rc=$?
  [[ "$rc" == "91" ]] || { cat "$fixture/loop.log" >&2; fail "$engine exit $rc"; }
}

set_issue() {
  local num="$1" title="$2" body="$3"
  jq -n --argjson n "$num" --arg t "$title" --arg b "$body" \
    '[{number:$n, title:$t, body:$b, url:("https://example.invalid/issues/" + ($n|tostring)), state:"OPEN", labels:[{name:"agy:todo"}]}]' \
    > "$fixture/issues.json"
}

assert_calls() {
  local expected="$1" call="$2" actual
  actual="$(grep -Fxc -- "$call" "$fixture/calls" || true)"
  [[ "$actual" == "$expected" ]] || { [[ -f "$fixture/loop.log" ]] && cat "$fixture/loop.log" >&2; fail "$call 执行 $actual 次，预期 $expected 次"; }
}

state_dir="$GONGCAO_HOME/state/example__issue-fixture"

# 1. check-deps.sh --engine codex 在没有 agy 时应通过
mkdir -p "$fixture/bin-no-agy"
for f in "$fixture/bin/"*; do
  [[ "$(basename "$f")" == "agy" ]] && continue
  ln -sf "$f" "$fixture/bin-no-agy/$(basename "$f")"
done
PATH="$fixture/bin-no-agy:/usr/bin:/bin" bash "$fixture/workflow/check-deps.sh" --engine codex > "$fixture/deps.log" 2>&1 \
  || { cat "$fixture/deps.log" >&2; fail 'check-deps.sh --engine codex 在缺少 agy 时失败'; }

# 2. 正常 completed 流程 + CODEX_REASONING_EFFORT="" 不传非法 -c 参数 + 独立非 Git TMPDIR 注入与清理
printf 'complete' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
: > "$fixture/codex-tmpdir.log"
set_issue 10 "测试正常开发" "完整需求描述-10"
run_dev_loop codex 1 env CODEX_REASONING_EFFORT=""
assert_calls 1 'set-state issue 10 in-review'
if grep -Fq 'model_reasoning_effort' "$fixture/codex-args.log"; then
  fail 'CODEX_REASONING_EFFORT 为空时仍传入了 model_reasoning_effort'
fi
used_tmpdir="$(head -n 1 "$fixture/codex-tmpdir.log")"
[[ "$used_tmpdir" == "$state_dir/tmp/dev-issue-10-"* ]] || fail "codex-dev 未使用独立 TMPDIR: $used_tmpdir"
grep -Fq -- "--add-dir $used_tmpdir" "$fixture/codex-args.log" || fail 'codex-dev 未通过 --add-dir 开放独立 TMPDIR'
[[ ! -e "$used_tmpdir" ]] || fail "codex-dev 结束后未清理临时目录: $used_tmpdir"
grep -Fq '反例或边界场景' "$fixture/prompt-1.txt" || fail 'codex-dev 提示词缺少 QA 反例纳入维护入口指引'

# 3. Codex JSON Schema 偶发不合规 -> 自动续接原会话修正一次并成功
printf 'schema-retry' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
: > "$fixture/codex-args.log"
set_issue 11 "测试 Schema 自动重试" "完整需求描述-11"
run_dev_loop codex 2
assert_calls 1 'set-state issue 11 in-review'
[[ "$(<"$fixture/codex-count")" == "2" ]] || fail 'Schema 重试次数不符合预期'
grep -Fq 'resume thread-abc-123' "$fixture/codex-args.log" || fail 'Schema 重试未续接原会话'

# 4. Codex 返回 status=blocked -> 标为 blocked 且不创建 PR
printf 'blocked' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
set_issue 12 "测试主动阻塞" "完整需求描述-12"
run_dev_loop codex 1
assert_calls 1 'set-state issue 12 blocked'
if grep -Fq 'ensure-pr 12 ' "$fixture/calls"; then
  fail 'blocked 状态不应创建 PR'
fi

# 5. 超时重试 -> 续接原会话并使用精简提示词（不重复粘贴原 Issue 正文）
printf 'timeout-then-ok' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
set_issue 13 "测试超时续接" "UNIQUE_ISSUE_BODY_MARKER_13"
run_dev_loop codex 2
assert_calls 1 'set-state issue 13 in-review'
grep -Fq 'UNIQUE_ISSUE_BODY_MARKER_13' "$fixture/prompt-1.txt" || fail '首轮提示词缺少 Issue 正文'
if grep -Fq 'UNIQUE_ISSUE_BODY_MARKER_13' "$fixture/prompt-2.txt"; then
  fail '超时续接原会话时不应重复粘贴整段原始 prompt'
fi

# 6. Codex 英文时长限流（try again in 10 minutes）-> 写入 codex 独立冷却文件且不阻塞 agy
printf 'quota-worded' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
set_issue 14 "测试按引擎隔离冷却" "完整需求描述-14"
run_dev_loop codex 1
assert_calls 1 'set-state issue 14 todo'
[[ -s "$state_dir/quota_reset_until.codex" ]] || fail '未写入按引擎隔离的 quota_reset_until.codex'
[[ ! -f "$state_dir/quota_reset_until" ]] || fail '不应继续写入共享的 quota_reset_until'
# agy 应不受 quota_reset_until.codex 影响，能够立即认领并调用 agy
run_dev_loop agy 1
assert_calls 1 agy-invoked

# 7. 验证 parse_reset_wait_seconds 对多种格式解析正确
bash -euo pipefail -c '
  GREP_BIN="$(command -v grep)"
  DATE_BIN="$(command -v date)"
  eval "$(sed -n "/^parse_reset_wait_seconds()/,/^}/p" "'"$fixture"'/workflow/lib/issue-loop.sh")"
  f="'"$fixture"'/rate.log"
  printf "resets in 1h2m3s\n" > "$f"
  [[ "$(parse_reset_wait_seconds "$f")" == "3723" ]]
  printf "Please try again in 2 hours 15 minutes.\n" > "$f"
  [[ "$(parse_reset_wait_seconds "$f")" == "8100" ]]
  printf "Please try again in 1.5 seconds.\n" > "$f"
  [[ "$(parse_reset_wait_seconds "$f")" == "2" ]]
  printf "{\"retry_after\": 90}\n" > "$f"
  [[ "$(parse_reset_wait_seconds "$f")" == "90" ]]
  future_iso="$(date -u -d "+180 seconds" "+%Y-%m-%dT%H:%M:%SZ")"
  printf "Usage limit resets at %s\n" "$future_iso" > "$f"
  got="$(parse_reset_wait_seconds "$f")"
  (( got >= 170 && got <= 190 ))
'

# 8. 锁互斥：持有 issue-loop.lock 时第二个实例立即退出
(
  flock -x 9
  if MOCK_SLEEPS=1 timeout 10s bash "$fixture/workflow/codex-issue-loop.sh" > "$fixture/lock.log" 2>&1; then
    fail '持有锁时第二个开发循环不应启动成功'
  fi
  grep -Fq '已有开发循环运行' "$fixture/lock.log" || fail '锁互斥报错信息不符合预期'
) 9>"$state_dir/issue-loop.lock"

# 9. P0-1: 复用已有开发 worktree 与远端同名分支对账（干净落后快进 / 脏树保护 / 分叉保护）
rm -f "$state_dir/quota_reset_until.codex"
git clone -q "$fixture/origin" "$fixture/peer"
git -C "$fixture/peer" config user.name Peer
git -C "$fixture/peer" config user.email peer@example.invalid

# 9a. 干净落后远端 2 个提交 -> 自动 ff-only 快进后继续开发
git -C "$fixture/peer" checkout -q -b feat/sync-ff main
printf 'r0\n' > "$fixture/peer/sync.txt"
git -C "$fixture/peer" add sync.txt && git -C "$fixture/peer" commit -qm 'remote-0'
git -C "$fixture/peer" push -q origin feat/sync-ff
git -C "$fixture/repo" fetch -q origin
git -C "$fixture/repo" worktree add -q -b feat/sync-ff "$state_dir/worktrees/issue-15" origin/feat/sync-ff
mkdir -p "$state_dir/sessions/issue-15"
printf 'feat/sync-ff\n' > "$state_dir/sessions/issue-15/branch_name"
printf 'r1\n' >> "$fixture/peer/sync.txt" && git -C "$fixture/peer" commit -qam 'remote-1'
printf 'r2\n' >> "$fixture/peer/sync.txt" && git -C "$fixture/peer" commit -qam 'remote-2'
git -C "$fixture/peer" push -q origin feat/sync-ff
expected_ff_parent="$(git -C "$fixture/peer" rev-parse HEAD)"

printf 'complete' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
set_issue 15 "测试干净落后快进" "需求-15"
run_dev_loop codex 1
assert_calls 1 'set-state issue 15 in-review'
git -C "$state_dir/worktrees/issue-15" merge-base --is-ancestor "$expected_ff_parent" HEAD \
  || fail '干净落后的开发 worktree 未快进到远端最新提交'

# 9b. 落后远端且工作区存在脏改动 -> 保留脏改动不覆盖，不调用 Codex，直接转 blocked
git -C "$fixture/peer" checkout -q -b feat/sync-dirty main
printf 'd0\n' > "$fixture/peer/dirty.txt"
git -C "$fixture/peer" add dirty.txt && git -C "$fixture/peer" commit -qm 'dirty-base'
git -C "$fixture/peer" push -q origin feat/sync-dirty
git -C "$fixture/repo" fetch -q origin
git -C "$fixture/repo" worktree add -q -b feat/sync-dirty "$state_dir/worktrees/issue-16" origin/feat/sync-dirty
mkdir -p "$state_dir/sessions/issue-16"
printf 'feat/sync-dirty\n' > "$state_dir/sessions/issue-16/branch_name"
printf 'local-unsaved\n' >> "$state_dir/worktrees/issue-16/dirty.txt"
printf 'd1\n' >> "$fixture/peer/dirty.txt" && git -C "$fixture/peer" commit -qam 'dirty-remote-1'
git -C "$fixture/peer" push -q origin feat/sync-dirty

printf '0\n' > "$fixture/codex-count"
set_issue 16 "测试脏树保护" "需求-16"
run_dev_loop codex 1
assert_calls 1 'set-state issue 16 blocked'
[[ "$(<"$fixture/codex-count")" == "0" ]] || fail '脏树落后场景不应启动 Codex'
grep -Fq 'local-unsaved' "$state_dir/worktrees/issue-16/dirty.txt" || fail '脏树本地改动被破坏'

# 9c. 与远端历史分叉 -> 保留现场，不调用 Codex，直接转 blocked
git -C "$fixture/peer" checkout -q -b feat/sync-diverge main
printf 'v0\n' > "$fixture/peer/diverge.txt"
git -C "$fixture/peer" add diverge.txt && git -C "$fixture/peer" commit -qm 'diverge-base'
git -C "$fixture/peer" push -q origin feat/sync-diverge
git -C "$fixture/repo" fetch -q origin
git -C "$fixture/repo" worktree add -q -b feat/sync-diverge "$state_dir/worktrees/issue-17" origin/feat/sync-diverge
mkdir -p "$state_dir/sessions/issue-17"
printf 'feat/sync-diverge\n' > "$state_dir/sessions/issue-17/branch_name"
printf 'local-commit\n' >> "$state_dir/worktrees/issue-17/diverge.txt"
git -C "$state_dir/worktrees/issue-17" commit -qam 'local-diverge'
printf 'remote-commit\n' >> "$fixture/peer/diverge.txt"
git -C "$fixture/peer" commit -qam 'remote-diverge'
git -C "$fixture/peer" push -q origin feat/sync-diverge

printf '0\n' > "$fixture/codex-count"
set_issue 17 "测试分叉保护" "需求-17"
run_dev_loop codex 1
assert_calls 1 'set-state issue 17 blocked'
[[ "$(<"$fixture/codex-count")" == "0" ]] || fail '历史分叉场景不应启动 Codex'

# 10. ready-for-agent 标签等同 agy:todo：仅带 ready-for-agent 的 Issue 可被认领，并与 agy:todo 合并去重按编号 FIFO 执行
printf '[]\n' > "$fixture/issues.json"
jq -n '[{number:18, title:"仅带ready-for-agent", body:"需求-18", url:"https://example.invalid/issues/18", state:"OPEN", labels:[{name:"ready-for-agent"}]}]' \
  > "$fixture/ready-issues.json"
printf 'complete' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
run_dev_loop codex 1
assert_calls 1 'set-state issue 18 in-progress'
assert_calls 1 'set-state issue 18 in-review'
rm -f "$fixture/ready-issues.json"

# 11. 验证真实 gh-state.sh 对 ready-for-agent 的列表合并与 set-state 替换（同时保留 agy:hold-merge 与普通标签）
mkdir -p "$fixture/ghstate-bin"
cat > "$fixture/ghstate-bin/gh" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
case "$1" in
  issue)
    # gh issue list --state open --limit 20 --json ... --label <lbl>
    lbl=""
    while (( $# > 0 )); do
      if [[ "$1" == "--label" ]]; then lbl="$2"; shift 2; else shift; fi
    done
    case "$lbl" in
      agy:todo)
        printf '[{"number":30,"title":"t30"},{"number":20,"title":"t20"}]\n'
        ;;
      ready-for-agent)
        printf '[{"number":10,"title":"t10"},{"number":20,"title":"t20"}]\n'
        ;;
      *)
        printf '[]\n'
        ;;
    esac
    ;;
  api)
    if [[ "$*" == *"-X PUT"* ]]; then
      cat > "$MOCK_DIR/gh-put-payload.json"
      printf '{}\n'
    else
      printf '[{"name":"ready-for-agent"},{"name":"agy:hold-merge"},{"name":"bug"}]\n'
    fi
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "$fixture/ghstate-bin/gh"

merged_issues="$(PATH="$fixture/ghstate-bin:$PATH" REPO=example/issue-fixture REPO_DIR="$fixture/repo" \
  bash "$repo_dir/gh-state.sh" list-issues open "agy:todo,ready-for-agent" 20)"
jq -e 'map(.number) == [10, 20, 30]' <<<"$merged_issues" >/dev/null \
  || { printf 'got: %s\n' "$merged_issues" >&2; fail 'gh-state list-issues 合并去重 ready-for-agent 失败'; }

PATH="$fixture/ghstate-bin:$PATH" REPO=example/issue-fixture REPO_DIR="$fixture/repo" \
  bash "$repo_dir/gh-state.sh" set-state issue 88 in-progress >/dev/null 2>&1
jq -e '
  (.labels | index("agy:in-progress")) != null
  and (.labels | index("ready-for-agent")) == null
  and (.labels | index("agy:hold-merge")) != null
  and (.labels | index("bug")) != null
' "$fixture/gh-put-payload.json" >/dev/null \
  || { cat "$fixture/gh-put-payload.json" >&2; fail 'gh-state set-state 未清除 ready-for-agent 或误删了 hold-merge/bug'; }

printf 'issue loop tests passed\n'
