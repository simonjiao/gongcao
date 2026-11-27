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
    if [[ -f "$MOCK_DIR/changes-issues.json" ]]; then
      cat "$MOCK_DIR/changes-issues.json"
    else
      printf '[]\n'
    fi
    ;;
  'get-comment issue '*'codex-review-comment'*)
    [[ -f "$MOCK_DIR/review-comment.md" ]] && cat "$MOCK_DIR/review-comment.md" || true
    ;;
  'get-comment issue '*)
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
  evidence-retry)
    if (( count == 1 )); then
      printf 'rework-part1\n' >> app.txt
      printf '{"status":"completed","summary":"已修一项","blocked_reason":"","commit_message":"fix: partial","branch_name":"feat/rework-evidence","blocker_resolutions":[{"id":"blocker-a","precondition_covered":"输入 false 态","test_or_check":"pytest test_a","result":"passed"}]}\n' > "$out_file"
    else
      printf 'rework-part2\n' >> app.txt
      printf '{"status":"completed","summary":"已补齐全部阻塞证据","blocked_reason":"","commit_message":"fix: full evidence","branch_name":"feat/rework-evidence","blocker_resolutions":[{"id":"blocker-a","precondition_covered":"输入 false 态","test_or_check":"pytest test_a","result":"passed"},{"id":"blocker-b","precondition_covered":"异常退出恢复原值","test_or_check":"pytest test_b","result":"passed"}]}\n' > "$out_file"
    fi
    ;;
  test-size-retry)
    if (( count == 1 )); then
      mkdir -p frontend/src qa
      seq 1 80 | sed 's/^/test_line_/' > frontend/src/foo.test.ts
      seq 1 10 | sed 's/^/runtime_line_/' > qa/browser-runtime.cjs
      printf '{"status":"completed","summary":"已实现并补测","blocked_reason":"","commit_message":"feat: with tests","branch_name":"feat/test-size-gate","blocker_resolutions":[],"verification_matrix":[],"size_justification":""}\n' > "$out_file"
    else
      printf '{"status":"completed","summary":"已补齐四列表与规模说明","blocked_reason":"","commit_message":"feat: with tests and matrix","branch_name":"feat/test-size-gate","blocker_resolutions":[],"verification_matrix":[{"target":"验证断链状态清理","existing_entry":"frontend/src/foo.test.ts 仅有成功路径","gap":"缺少 401 竞态清理断言","action":"EXTEND","rationale":"少了会漏检会话过期后旧引用残留"}],"size_justification":"401 竞态与多分支清理需 80 行隔离单测；browser-runtime 仅补 10 行归属校验。"}\n' > "$out_file"
    fi
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

# 12. 评审返工：阻塞清单与反馈置顶 + 缺少逐项证据时续接原会话补齐 + 兼容旧版评论与 approve 评论
printf '[]\n' > "$fixture/issues.json"
jq -n '[{number:19, title:"测试返工逐项证据", body:"UNIQUE_ISSUE_19_BODY", url:"https://example.invalid/issues/19", state:"OPEN", labels:[{name:"agy:changes-requested"}]}]' \
  > "$fixture/changes-issues.json"
cat > "$fixture/review-comment.md" <<'EOF'
### Codex 独立评审报告

| 字段 | 值 |
| --- | --- |
| 评审结论 | `request_changes` -> `agy:changes-requested` |

#### 阻塞问题（Blocking Issues）
- **[major]** `blocker-a` · `a.py:1`
  缺少 false 态覆盖
  - 修复建议。从 false 起测
  - 关闭条件。从 switch=false 起测并验证开启
- **[major]** `blocker-b` · `b.py:2`
  缺少异常恢复
  - 修复建议。finally 恢复
  - 关闭条件。探针失败退出时恢复原值

<!-- codex-review-meta:{"head_sha":"abc123","verdict":"request_changes","e2e_decision":"run_e2e","e2e_reused_sha":"","e2e_checks":[],"blocking_issues":[{"id":"blocker-a","severity":"major","location":"a.py:1","verification":"从 switch=false 起测并验证开启"},{"id":"blocker-b","severity":"major","location":"b.py:2","verification":"探针失败退出时恢复原值"}]} -->
EOF
printf 'evidence-retry' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
: > "$fixture/codex-args.log"
run_dev_loop codex 2
assert_calls 1 'set-state issue 19 in-review'
[[ "$(<"$fixture/codex-count")" == "2" ]] || fail '缺项证据应触发 1 次原会话补齐'
grep -Fq 'resume thread-abc-123' "$fixture/codex-args.log" || fail '缺项证据补齐未续接原会话'
grep -Fq 'blocker-b' "$fixture/prompt-2.txt" || fail '原会话补齐提示词未指出缺失的 blocker-b'
grep -Fq '探针失败退出时恢复原值' "$fixture/prompt-2.txt" || fail '原会话补齐提示词未附带缺失项关闭条件'
line_checklist="$(grep -n '本轮待关闭阻塞项与关闭条件' "$fixture/prompt-1.txt" | head -n 1 | cut -d: -f1)"
line_issue_body="$(grep -n 'UNIQUE_ISSUE_19_BODY' "$fixture/prompt-1.txt" | head -n 1 | cut -d: -f1)"
[[ -n "$line_checklist" && -n "$line_issue_body" && "$line_checklist" -lt "$line_issue_body" ]] \
  || fail "返工提示词未将阻塞清单置顶于 Issue 正文之前 (checklist=$line_checklist, body=$line_issue_body)"
grep -Fq '本轮阻塞项逐项验证' "$state_dir/sessions/issue-19/summary.md" || fail '最终 summary 未渲染阻塞项逐项验证表'
grep -Fq '异常退出恢复原值' "$state_dir/sessions/issue-19/summary.md" || fail '最终 summary 缺少 blocker-b 证据'
rm -f "$fixture/changes-issues.json" "$fixture/review-comment.md"

# 12b. 验证 extract_review_blockers_json 兼容无 blocking_issues 的旧版评审评论，并在 verdict=approve 时返回 []
bash -euo pipefail -c '
  JQ_BIN="$(command -v jq)"
  eval "$(sed -n "/^extract_review_blockers_json()/,/^}/p" "'"$fixture"'/workflow/lib/issue-loop.sh")"
  legacy_md="$(cat <<'\''EOM'\''
### Codex 独立评审报告
| 评审结论 | `request_changes` -> `agy:changes-requested` |
#### 阻塞问题（Blocking Issues）
- **[major]** `quality-qa-doris-preflight` · `qa/metadata-evidence.py:150`
  READY 契约允许关闭
  - 修复建议。先启用再恢复
  - 关闭条件。定向覆盖 enable_audit_plugin=false 时启用并恢复原值。
<!-- codex-review-meta:{"head_sha":"abc","verdict":"request_changes","e2e_decision":"run_e2e","e2e_reused_sha":"","e2e_checks":[]} -->
EOM
)"
  got_legacy="$(extract_review_blockers_json "$legacy_md")"
  jq -e '\''length == 1 and .[0].id == "quality-qa-doris-preflight" and (.[0].verification | contains("enable_audit_plugin=false"))'\'' <<<"$got_legacy" >/dev/null

  approved_md="$(cat <<'\''EOM'\''
<!-- codex-review-meta:{"head_sha":"abc","verdict":"approve","e2e_decision":"run_e2e","e2e_reused_sha":"","e2e_checks":["E1"],"blocking_issues":[]} -->
EOM
)"
  got_approved="$(extract_review_blockers_json "$approved_md")"
  [[ "$got_approved" == "[]" ]]
'

# 13. 提交前验证覆盖四列表与测试/QA 规模门禁（超 Issue 估算 + 触及通用 QA 运行时 -> 原会话补齐并渲染进 PR 正文）
printf 'test-size-retry' > "$fixture/codex-mode"
printf '0\n' > "$fixture/codex-count"
: > "$fixture/codex-args.log"
set_issue 20 "测试规模与四列表门禁" "需求正文：生产约 110–200 行，必要测试 30–75 行，原则前端为主。"
run_dev_loop codex 2
assert_calls 1 'set-state issue 20 in-review'
[[ "$(<"$fixture/codex-count")" == "2" ]] || fail '缺少 verification_matrix 或 size_justification 时应触发原会话补齐'
grep -Fq 'resume thread-abc-123' "$fixture/codex-args.log" || fail '规模/四列表补齐未续接原会话'
grep -Fq 'verification_matrix' "$fixture/prompt-2.txt" || fail '补齐提示词未要求填写 verification_matrix'
grep -Fq '超出 Issue 估算上限 75 行' "$fixture/prompt-2.txt" || fail '补齐提示词未指出超出 Issue 测试估算上限 75 行'
grep -Fq 'qa/browser-runtime.cjs' "$fixture/prompt-2.txt" || fail '补齐提示词未指出改动了通用 QA 运行时文件'
grep -Fq '验证覆盖与复用说明' "$state_dir/sessions/issue-20/summary.md" || fail 'summary 未渲染验证覆盖与复用说明表'
grep -Fq '测试/QA 规模与范围说明' "$state_dir/sessions/issue-20/summary.md" || fail 'summary 未渲染规模说明'
grep -Fq '## 变更规模（宿主机实测）' "$state_dir/sessions/issue-20/pr-body.md" || fail 'PR 正文未注入宿主机实测变更规模'
grep -Fq '内部测试（Issue 测试估算上限：75 行）' "$state_dir/sessions/issue-20/pr-body.md" || fail 'PR 正文规模表未标注 Issue 测试估算上限'

# 13b. 单元测试 lib/diff-metrics.sh 分类与估算解析
bash -euo pipefail -c '
  source "'"$fixture"'/workflow/lib/diff-metrics.sh"
  [[ "$(classify_diff_path "qa/README.md")" == "docs" ]]
  [[ "$(classify_diff_path "qa/test-browser-runtime.cjs")" == "test" ]]
  [[ "$(classify_diff_path "qa/test_environment.py")" == "test" ]]
  [[ "$(classify_diff_path "qa/metadata-evidence-browser.cjs")" == "qa" ]]
  [[ "$(classify_diff_path "frontend/src/views/GraphView.vue")" == "prod" ]]
  is_qa_infra_path "qa/browser-runtime.cjs"
  ! is_qa_infra_path "qa/metadata-evidence-browser.cjs"
  [[ "$(parse_issue_test_budget "生产约 110–200 行，必要测试 30–75 行")" == "75" ]]
  [[ "$(parse_issue_test_budget "无估算说明")" == "0" ]]
'

printf 'issue loop tests passed\n'
