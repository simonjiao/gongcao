#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/workflow"
cp "$repo_dir"/*.sh "$fixture/workflow/"
for module in "$repo_dir"/*.jq; do
  [[ -f "$module" ]] && cp "$module" "$fixture/workflow/"
done

fail() {
  printf 'FAIL %s\n' "$*" >&2
  exit 1
}

git init -q -b main "$fixture/repo"
git -C "$fixture/repo" config user.name Test
git -C "$fixture/repo" config user.email test@example.invalid
git -C "$fixture/repo" commit -qm initial --allow-empty
git clone -q --bare "$fixture/repo" "$fixture/origin"
git -C "$fixture/repo" remote add origin "$fixture/origin"
export MOCK_DIR="$fixture" REPO_DIR="$fixture/repo" REPO=example/fixture
export PATH="$fixture/bin:$PATH" GONGCAO_HOME="$fixture/home" INIT_LABELS=0 POLL_INTERVAL=1 PUBLISH_EVIDENCE=0
export MOCK_SHA="$(git -C "$fixture/repo" rev-parse HEAD)"
export CODEX_E2E_BYPASS_APPROVALS=0
jq -n --arg sha "$MOCK_SHA" '[{number: 7, title:"Fixture", body:"", url:"https://example.invalid/pull/7",
  headRefName:"main", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", updatedAt:"first"}]' > "$fixture/pr.json"

cat > "$fixture/workflow/gh-state.sh" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
case "$*" in
  'list-prs '*)
    cat "$MOCK_DIR/pr.json"
    ;;
  'get-comment pr 7 <!-- codex-review-comment -->')
    printf '%s\n' read-review >> "$MOCK_DIR/calls"
    [[ ! -f "$MOCK_DIR/fail-read" ]] || exit 1
    cat "$MOCK_DIR/review-comment"
    ;;
  'get-comment '*|'get-pr-diff '*)
    ;;
  'get-issue '*)
    printf '%s\n' '{"title":"Mock Issue","body":"需求正文","labels":[],"url":"https://example.invalid/issues/42"}'
    ;;
  'get-repo-merge-settings')
    printf '%s\n' '{"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true}'
    ;;
  'list-issues '*)
    printf '[]\n'
    ;;
  'comment pr 7 - <!-- codex-review-comment -->')
    printf '%s\n' write-review >> "$MOCK_DIR/calls"
    if [[ -f "$MOCK_DIR/fail-comment" ]]; then
      rm "$MOCK_DIR/fail-comment"
      exit 1
    fi
    cat > "$MOCK_DIR/review-comment"
    ;;
  'comment issue 42 - <!-- codex-review-comment -->')
    printf '%s\n' write-issue-review >> "$MOCK_DIR/calls"
    if [[ -f "$MOCK_DIR/fail-issue-comment" ]]; then
      rm "$MOCK_DIR/fail-issue-comment"
      exit 1
    fi
    cat >/dev/null
    ;;
  'comment '*)
    cat >/dev/null
    ;;
  'set-state pr 7 '*)
    printf '%s\n' "$*" >> "$MOCK_DIR/calls"
    if [[ -f "$MOCK_DIR/fail-state" ]]; then
      rm "$MOCK_DIR/fail-state"
      exit 1
    fi
    ;;
  'set-state issue 42 '*)
    printf '%s\n' "$*" >> "$MOCK_DIR/calls"
    if [[ -f "$MOCK_DIR/fail-issue-state" ]]; then
      rm "$MOCK_DIR/fail-issue-state"
      exit 1
    fi
    ;;
  *) printf 'Unexpected GitHub command %s\n' "$*" >&2; exit 98 ;;
esac
EOF
cat > "$fixture/bin/codex" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
while [[ "$1" != "-o" ]]; do shift; done
cat > "$MOCK_DIR/last-prompt"
case "$2" in
  */verdict-*)
    printf '%s\n' codex-review >> "$MOCK_DIR/calls"
    cat "$MOCK_DIR/verdict.json" > "$2"
    ;;
  */result-*)
    printf '%s\n' codex-e2e >> "$MOCK_DIR/calls"
    artifact_dir="${2%/*}/artifacts-${2##*/result-}"
    artifact_dir="${artifact_dir%.json}"
    sed "s|__ARTIFACTS_DIR__|${artifact_dir}|g" "$MOCK_DIR/result.json" > "$2"
    if [[ ! -f "$MOCK_DIR/skip-artifact" ]]; then
      printf '%s\n' '实测通过' > "${artifact_dir}/upgrade.log"
    fi
    ;;
  */decision-*)
    printf '%s\n' codex-final >> "$MOCK_DIR/calls"
    cat "$MOCK_DIR/decision.json" > "$2"
    ;;
  *) exit 98 ;;
esac
EOF
cat > "$fixture/bin/sleep" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
count=$(<"$MOCK_DIR/sleep-count")
printf '%s\n' "$(( count + 1 ))" > "$MOCK_DIR/sleep-count"
if [[ -f "$MOCK_DIR/next-pr" ]]; then
  mv "$MOCK_DIR/next-pr" "$MOCK_DIR/pr.json"
  mv "$MOCK_DIR/next-comment" "$MOCK_DIR/review-comment"
fi
if (( count + 1 >= MOCK_POLLS )); then exit 91; fi
EOF
chmod +x "$fixture/workflow/gh-state.sh" "$fixture/bin/"*

run_loop() {
  local loop="$1" polls="${2:-1}" rc=0
  printf '0\n' > "$fixture/sleep-count"
  MOCK_POLLS="$polls" timeout 20s bash "$fixture/workflow/codex-${loop}-loop.sh" > "$fixture/loop.log" 2>&1 || rc=$?
  [[ "$rc" == "91" ]] || { cat "$fixture/loop.log" >&2; fail "$loop exit $rc"; }
}

assert_calls() {
  local expected="$1" call="$2" actual
  actual="$(grep -Fxc -- "$call" "$fixture/calls" || true)"
  [[ "$actual" == "$expected" ]] || fail "$call 执行 $actual 次，预期 $expected 次"
}

state_dir="$GONGCAO_HOME/state/example__fixture"
set_pr_body() {
  jq --arg body "$1" '.[0].body = $body' "$fixture/pr.json" > "$fixture/new-pr"
  mv "$fixture/new-pr" "$fixture/pr.json"
}

jq -n '{
  verdict:"approve", summary:"通过", e2e_decision:"run_e2e", e2e_decision_reason:"实测",
  e2e_checks:["从旧状态读取，检查结果 -->"], requires_human_decision:false,
  requirements_coverage:[], blocking_issues:[], non_blocking_notes:[]
}' > "$fixture/verdict.json"
cp "$fixture/verdict.json" "$fixture/approve.json"
touch "$fixture/fail-comment" "$fixture/fail-state"
run_loop review
run_loop review
run_loop review
assert_calls 1 codex-review
assert_calls 2 write-review
assert_calls 2 'set-state pr 7 approved'
[[ "$(wc -l < "$state_dir/reviews/pr-7/reviewed_shas.txt")" == "1" ]] || fail '写回重试重复计轮'
grep -F 'codex-review-meta:' "$fixture/review-comment" | grep -Fq -- '--\u003e' || fail 'HTML 注释中的场景未转义'

sed 's/$/\r/' "$fixture/review-comment" > "$fixture/crlf"
mv "$fixture/crlf" "$fixture/review-comment"
jq -n '{
  verdict:"pass", summary:"通过", environment:"测试环境",
  scenarios:[{id:"E1", name:"从旧状态读取, 检查结果 -->", status:"passed", details:"实测通过", evidence_paths:["upgrade.log"]}],
  evidence_paths:["upgrade.log"], failure_details:[], remaining_risks:[]
}' > "$fixture/result.json"
PUBLISH_EVIDENCE=1 run_loop e2e 3
assert_calls 1 codex-e2e
assert_calls 1 read-review
assert_calls 1 'set-state pr 7 e2e-passed'
grep -Fq 'E1 从旧状态读取，检查结果 -->' "$fixture/last-prompt" || fail 'CRLF 评论丢失必验场景'

cp "$fixture/review-comment" "$fixture/original-comment"
sed 's/检查结果/检查升级结果/' "$fixture/review-comment" > "$fixture/next-comment"
jq '.[0].updatedAt = "second"' "$fixture/pr.json" > "$fixture/next-pr"
run_loop e2e 3
assert_calls 2 codex-e2e
assert_calls 3 read-review
assert_calls 2 'set-state pr 7 e2e-passed'
grep -Fq 'E1 从旧状态读取，检查升级结果 -->' "$fixture/last-prompt" || fail '同 SHA 的新场景未复验'

new_e2e_root="$fixture/e2e-invalid"
printf 'no metadata\n' > "$fixture/review-comment"
E2E_ROOT="$new_e2e_root" run_loop e2e
grep -Fq '缺少评审元数据' "$fixture/loop.log" || fail '缺失元数据未记录'
sed "s/$MOCK_SHA/stale-sha/" "$fixture/original-comment" > "$fixture/review-comment"
E2E_ROOT="$new_e2e_root" run_loop e2e
grep -Fq '评审提交与当前提交不匹配' "$fixture/loop.log" || fail '陈旧 SHA 未记录'
touch "$fixture/fail-read"
E2E_ROOT="$new_e2e_root" run_loop e2e
grep -Fq '评审验收交接，将在后续轮询重试' "$fixture/loop.log" || fail '读取失败未记录'
rm "$fixture/fail-read"
assert_calls 2 codex-e2e

cp "$fixture/original-comment" "$fixture/review-comment"
touch "$fixture/skip-artifact"
E2E_ROOT="$new_e2e_root" run_loop e2e
assert_calls 1 'set-state pr 7 blocked'
grep -Fq 'E1 缺少唯一的通过记录' "$new_e2e_root/pr-7/e2e-comment.md" || fail '无实际证据的场景被接受'
rm "$fixture/skip-artifact"

git --git-dir="$fixture/origin" worktree add -q "$fixture/archive" qa/e2e-evidence
archives=("$fixture/archive/pr-7/"*)
[[ "${#archives[@]}" == "1" && -f "${archives[0]}/artifacts/upgrade.log" ]] || fail 'E2E 证据归档失败'
entry="${archives[0]}"
commit_archive() {
  git -C "$fixture/archive" add -A
  git -C "$fixture/archive" -c user.name=Test -c user.email=test@example.invalid commit -qm "$1"
}
jq -n '{
  verdict:"merge", summary:"可合入", merge_method:"merge", merge_method_reason:"默认",
  audit_checks:[], pr_title:"", pr_body:"", issue_closing_note:"",
  blocking_issues:[], non_blocking_notes:[], follow_up_issues:[]
}' > "$fixture/decision.json"
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-pass" run_loop final-gate
assert_calls 1 'set-state pr 7 ready-to-merge'
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-pass" run_loop final-gate
assert_calls 1 codex-final

jq '.scenarios[0].id = "E2"' "$fixture/result.json" > "$entry/result.json"
commit_archive wrong-id
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-blocked" run_loop final-gate
assert_calls 2 'set-state pr 7 blocked'
grep -Fq '归档证据：E1' "$fixture/final-blocked/pr-7/final-gate-comment.md" || fail '终审没有指出缺失的必验场景'

cp "$fixture/result.json" "$entry/result.json"
commit_archive restore-id
sed 's/检查结果/检查本轮升级结果/' "$fixture/original-comment" > "$fixture/review-comment"
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-pass" run_loop final-gate
assert_calls 3 'set-state pr 7 blocked'
grep -Fq '缺少与当前评审必验场景和提交匹配的 QA 归档' "$fixture/final-pass/pr-7/final-gate-comment.md" \
  || fail '终审接受了同 SHA 上旧场景的 QA 归档'

jq -n '{
  verdict:"request_changes", summary:"目录与事件口径不一致", e2e_decision:"run_e2e", e2e_decision_reason:"",
  e2e_checks:[], requires_human_decision:false, requirements_coverage:[], non_blocking_notes:[],
  blocking_issues:[{id:"capture-normalization",severity:"major", location:"catalog.sh:12",
    description:"发现小数精度口径不一致", suggestion:"重用读取层逻辑", verification:"比较两路采集的类型数据"}]
}' > "$fixture/reject.json"
cp "$fixture/reject.json" "$fixture/verdict.json"
set_pr_body '第一轮类型差异'
run_loop review
assert_calls 1 'set-state pr 7 changes-requested'
set_pr_body '第二轮补了部分类型'
run_loop review
assert_calls 2 'set-state pr 7 changes-requested'
cp "$fixture/approve.json" "$fixture/verdict.json"
set_pr_body '通过评审进入 E2E'
run_loop review
assert_calls 3 'set-state pr 7 approved'
jq '.blocking_issues[0].description = "发现 BIT 口径不一致" | .blocking_issues[0].location = "ddl.sh:50"' \
  "$fixture/reject.json" > "$fixture/verdict.json"
set_pr_body 'E2E 后修复并进入新周期'
run_loop review
assert_calls 4 'set-state pr 7 blocked'
grep -Fq 'capture-normalization（已出现 2 轮）' "$fixture/last-prompt" || fail '新周期未带上历史根因'
jq -e '."capture-normalization".review_keys | length == 3' "$state_dir/reviews/pr-7/blocker-history.json" >/dev/null \
  || fail '跨周期根因轮次累计错误'

jq '.requires_human_decision = true | .blocking_issues[0].id = "write-contract"' "$fixture/reject.json" > "$fixture/verdict.json"
set_pr_body '需要授权才能变更持久化契约'
run_loop review
assert_calls 5 'set-state pr 7 blocked'
grep -Fq '变更现有契约的事项待人工授权' "$fixture/review-comment" || fail '未暂停自动返工'

# 1. 验证关联 Issue 写回失败时，即使 PR 已切离 agy:in-review，下次轮询也会续完 Issue 交接而不重跑 Codex
jq '.blocking_issues[0].id = "issue-handoff-check"' "$fixture/reject.json" > "$fixture/verdict.json"
set_pr_body 'Closes #42 关联 Issue 交接重试测试'
touch "$fixture/fail-issue-comment" "$fixture/fail-issue-state"
before_reviews="$(grep -Fxc -- codex-review "$fixture/calls" || true)"
REVIEWS_ROOT="$fixture/reviews-issue-handoff" run_loop review
# 模拟 PR 已切离 agy:in-review（list-prs 返回空）
cp "$fixture/pr.json" "$fixture/pr-backup.json"
printf '[]\n' > "$fixture/pr.json"
REVIEWS_ROOT="$fixture/reviews-issue-handoff" run_loop review
REVIEWS_ROOT="$fixture/reviews-issue-handoff" run_loop review
mv "$fixture/pr-backup.json" "$fixture/pr.json"
assert_calls "$((before_reviews + 1))" codex-review
assert_calls 2 write-issue-review
assert_calls 2 'set-state issue 42 changes-requested'
[[ ! -f "$fixture/reviews-issue-handoff/pr-7/pending-review.json" ]] || fail 'Issue 交接完成后仍残留 pending-review.json'

# 2. 验证 E2E 证据路径归一化（绝对路径、./ 前缀、artifacts/ 前缀在 E2E 和终审均可识别）
cp "$fixture/original-comment" "$fixture/review-comment"
jq -n '{
  verdict:"pass", summary:"通过", environment:"测试环境",
  scenarios:[{id:"E1", name:"路径归一化", status:"passed", details:"实测通过", evidence_paths:["__ARTIFACTS_DIR__/upgrade.log"]}],
  evidence_paths:["./upgrade.log"], failure_details:[], remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$fixture/e2e-norm" PUBLISH_EVIDENCE=1 run_loop e2e 1
assert_calls 3 'set-state pr 7 e2e-passed'
# 终审识别归档中含绝对路径和 artifacts/ 前缀的 result.json
git -C "$fixture/archive" pull -q origin qa/e2e-evidence
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-norm" run_loop final-gate
assert_calls 2 'set-state pr 7 ready-to-merge'

# 3. 验证终审就地消解冲突后的父提交映射（resolved-conflicts.tsv）在重跑与轮询去重中生效
git -C "$fixture/repo" commit -qm 'merge-resolved-conflict' --allow-empty
git -C "$fixture/repo" push -q origin main
merged_sha="$(git -C "$fixture/repo" rev-parse HEAD)"
mkdir -p "$fixture/final-conflict/pr-7"
printf '%s\t%s\n' "$merged_sha" "$MOCK_SHA" > "$fixture/final-conflict/pr-7/resolved-conflicts.tsv"
jq --arg sha "$merged_sha" '.[0].headRefOid = $sha' "$fixture/pr.json" > "$fixture/pr-merged.json"
mv "$fixture/pr-merged.json" "$fixture/pr.json"
before_final="$(grep -Fxc -- codex-final "$fixture/calls" || true)"
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-conflict" run_loop final-gate
assert_calls "$((before_final + 1))" codex-final
assert_calls 3 'set-state pr 7 ready-to-merge'
# 再次轮询同一冲突消解提交应被跳过，不再重复调用 codex-final
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-conflict" run_loop final-gate
assert_calls "$((before_final + 1))" codex-final

printf 'workflow convergence tests passed\n'
