#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/workflow/lib" "$fixture/home/codex-review"
cp "$repo_dir"/*.sh "$fixture/workflow/"
cp "$repo_dir"/lib/*.sh "$fixture/workflow/lib/"
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
  'get-comment pr 7 <!-- codex-e2e-comment -->')
    [[ -f "$MOCK_DIR/e2e-comment" ]] && cat "$MOCK_DIR/e2e-comment"
    ;;
  'get-comment '*|'get-pr-diff '*)
    ;;
  'get-issue '*)
    inum="${2:-}"
    if [[ -n "$inum" && -f "$MOCK_DIR/issue-${inum}.json" ]]; then
      cat "$MOCK_DIR/issue-${inum}.json"
    elif [[ -f "$MOCK_DIR/issue.json" ]]; then
      cat "$MOCK_DIR/issue.json"
    else
      printf '%s\n' '{"title":"Mock Issue","body":"需求正文","state":"OPEN","labels":[],"url":"https://example.invalid/issues/42"}'
    fi
    ;;
  'get-pr '*)
    if [[ -f "$MOCK_DIR/live-pr.json" ]]; then
      cat "$MOCK_DIR/live-pr.json"
    else
      jq '.[0] + {state:"OPEN"}' "$MOCK_DIR/pr.json"
    fi
    ;;
  'get-pr-comments '*)
    if [[ -f "$MOCK_DIR/pr-comments.json" ]]; then
      cat "$MOCK_DIR/pr-comments.json"
    else
      printf '[]\n'
    fi
    ;;
  'mark-pr-ready '*)
    printf '%s\n' "$*" >> "$MOCK_DIR/calls"
    ;;
  'merge-pr '*)
    printf '%s\n' "$*" >> "$MOCK_DIR/calls"
    ;;
  'update-pr '*)
    ;;
  'get-repo-merge-settings')
    printf '%s\n' '{"allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true}'
    ;;
  'list-issues '*)
    if [[ -f "$MOCK_DIR/open-issues.json" ]]; then
      cat "$MOCK_DIR/open-issues.json"
    else
      printf '[]\n'
    fi
    ;;
  'create-issue '*)
    printf '%s\n' "create-issue $2" >> "$MOCK_DIR/calls"
    printf '99\thttps://example.invalid/issues/99\tcreated\n'
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
  'comment pr 7 - <!-- codex-e2e-comment -->')
    printf '%s\n' write-e2e >> "$MOCK_DIR/calls"
    if [[ -f "$MOCK_DIR/fail-e2e-comment" ]]; then
      rm "$MOCK_DIR/fail-e2e-comment"
      exit 1
    fi
    cat > "$MOCK_DIR/e2e-comment"
    ;;
  'comment issue 42 - <!-- codex-e2e-comment -->')
    printf '%s\n' write-issue-e2e >> "$MOCK_DIR/calls"
    cat >/dev/null
    ;;
  'comment issue '*' <!-- gongcao-auto-queue-comment -->')
    printf 'comment-auto-queue issue %s\n' "$3" >> "$MOCK_DIR/calls"
    cat > "$MOCK_DIR/auto-queue-comment-${3}.md"
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
  'set-state issue '*)
    printf '%s\n' "$*" >> "$MOCK_DIR/calls"
    if [[ "$3" == "42" && -f "$MOCK_DIR/fail-issue-state" ]]; then
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
expected_home="$(cd -- "$GONGCAO_HOME/codex-review" && pwd -P)"
if [[ "${CODEX_HOME:-}" != "$expected_home" ]]; then
  printf 'Unexpected CODEX_HOME=%q (expected %q)\n' "${CODEX_HOME:-}" "$expected_home" >&2
  exit 97
fi
while [[ "$1" != "-o" ]]; do shift; done
cat > "$MOCK_DIR/last-prompt"
case "$2" in
  */verdict-*)
    printf '%s\n' codex-review >> "$MOCK_DIR/calls"
    printf '%s\n' "${TMPDIR:-}" >> "$MOCK_DIR/review-tmpdir.log"
    [[ -n "${TMPDIR:-}" && -d "${TMPDIR:-}" ]] || { printf 'Missing review TMPDIR\n' >&2; exit 96; }
    cat "$MOCK_DIR/verdict.json" > "$2"
    ;;
  */result-*)
    printf '%s\n' codex-e2e >> "$MOCK_DIR/calls"
    artifact_dir="${2%/*}/artifacts-${2##*/result-}"
    artifact_dir="${artifact_dir%.json}"
    sed "s|__ARTIFACTS_DIR__|${artifact_dir}|g" "$MOCK_DIR/result.json" > "$2"
    if [[ ! -f "$MOCK_DIR/skip-artifact" ]]; then
      printf '%s\n' '实测通过' > "${artifact_dir}/upgrade.log"
      mkdir -p "${artifact_dir}/runs/E1/attempt-1"
      printf '%s\n' '首跑原始证据' > "${artifact_dir}/runs/E1/attempt-1/report.log"
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

git clone -q -b qa/e2e-evidence "$fixture/origin" "$fixture/archive"
archives=("$fixture/archive/pr-7/"*)
[[ "${#archives[@]}" == "1" && -f "${archives[0]}/artifacts/upgrade.log" ]] || fail 'E2E 证据归档失败'
entry="${archives[0]}"
commit_archive() {
  git -C "$fixture/archive" add -A
  git -C "$fixture/archive" -c user.name=Test -c user.email=test@example.invalid commit -qm "$1"
  git -C "$fixture/archive" push -q origin qa/e2e-evidence
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
grep -Fq '<details>' "$fixture/review-comment" || fail '复审评论未保留历次评审记录折叠区'
grep -Fq '历次评审记录' "$fixture/review-comment" || fail '复审评论缺少历次评审记录标题'
grep -Fq '`capture-normalization`' "$fixture/review-comment" || fail '复审评论未保留前轮打回的阻塞根因 ID'
grep -Fq '反例或边界场景' "$fixture/last-prompt" || fail '评审提示词缺少 QA 反例覆盖指引'
review_tmp_used="$(head -n 1 "$fixture/review-tmpdir.log")"
[[ "$review_tmp_used" == "$state_dir/tmp/review-pr-7-"* ]] || fail "codex-review 未使用独立 TMPDIR: $review_tmp_used"
[[ ! -e "$review_tmp_used" ]] || fail "codex-review 结束后未清理临时目录: $review_tmp_used"
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

# 4. 未初始化评审专用 Codex 目录时必须显式报错，绝不静默回退个人默认 ~/.codex
if CODEX_REVIEW_HOME="$fixture/missing-codex-review" timeout 10s bash "$fixture/workflow/codex-review-loop.sh" > "$fixture/missing-home.log" 2>&1; then
  fail '未初始化 codex-review 目录时不应静默启动'
fi
grep -Fq 'codex-review-loop.sh login' "$fixture/missing-home.log" || fail '缺少 codex-review 初始化提示'

# 5. P0-1: 目标 head_sha 不存在时拒绝回退 FETCH_HEAD，不启动评审模型
before_rev_p0="$(grep -Fxc -- codex-review "$fixture/calls" || true)"
cp "$fixture/pr.json" "$fixture/pr-p0-bak.json"
jq '.[0].headRefOid = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"' "$fixture/pr.json" > "$fixture/pr-missing-sha.json"
mv "$fixture/pr-missing-sha.json" "$fixture/pr.json"
REVIEWS_ROOT="$fixture/reviews-missing-sha" run_loop review
mv "$fixture/pr-p0-bak.json" "$fixture/pr.json"
assert_calls "$before_rev_p0" codex-review
grep -Fq '拒绝回退 FETCH_HEAD' "$fixture/loop.log" || fail '缺失提交时未拒绝回退 FETCH_HEAD'

# 6. P0-2: 宿主机逐 PR 合入授权与 HOLD 硬门禁
cp "$fixture/original-comment" "$fixture/review-comment"
jq -n --arg sha "$MOCK_SHA" '[{number: 7, title:"Fixture", body:"Closes #42", url:"https://example.invalid/pull/7",
  state:"OPEN", isDraft:true, headRefName:"main", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", labels:[], updatedAt:"p0"}]' > "$fixture/pr.json"

# 6a. AUTO_MERGE=0 下 Draft PR 不应提前转为 Ready
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-p0-noauto" run_loop final-gate
assert_calls 0 'mark-pr-ready 7'
assert_calls 0 "merge-pr 7 merge ${MOCK_SHA}"

# 6b. 运行中实时新增 agy:hold-merge 标签 -> 拦截转 Ready 与合入
jq -n --arg sha "$MOCK_SHA" '{number:7, state:"OPEN", isDraft:true, headRefName:"main", baseRefName:"main", headRefOid:$sha, labels:[{name:"agy:hold-merge"}]}' \
  > "$fixture/live-pr.json"
AUTO_MERGE=1 FINAL_ROOT="$fixture/final-p0-hold" run_loop final-gate
assert_calls 0 'mark-pr-ready 7'
assert_calls 0 "merge-pr 7 merge ${MOCK_SHA}"
grep -Fq 'agy:hold-merge' "$fixture/final-p0-hold/pr-7/final-gate-comment.md" || fail 'HOLD 标签未写入终审说明'
rm -f "$fixture/live-pr.json"

# 6c. Issue 明示将合入决定保留给 Owner：未授权用户评论与旧 SHA 放行均须拒绝，仅 Owner 绑定当前 SHA 才放行
jq -n '{title:"发布封版", body:"合入决定保留给 Owner，确认后放行。", labels:[], url:"https://example.invalid/issues/42"}' > "$fixture/issue.json"
jq -n --arg sha "$MOCK_SHA" '[{author:"stranger", author_association:"NONE", body:("/approve-merge " + $sha), updated_at:"2026-11-26T00:00:00Z"}]' \
  > "$fixture/pr-comments.json"
AUTO_MERGE=1 FINAL_ROOT="$fixture/final-p0-owner" run_loop final-gate
assert_calls 0 'mark-pr-ready 7'
assert_calls 0 "merge-pr 7 merge ${MOCK_SHA}"

jq -n '[{author:"simonjiao", author_association:"OWNER", body:"/approve-merge 1111111111111111111111111111111111111111", updated_at:"2026-11-26T00:00:00Z"}]' \
  > "$fixture/pr-comments.json"
AUTO_MERGE=1 FINAL_ROOT="$fixture/final-p0-owner" run_loop final-gate
assert_calls 0 'mark-pr-ready 7'
assert_calls 0 "merge-pr 7 merge ${MOCK_SHA}"

jq -n --arg sha "$MOCK_SHA" '[{author:"simonjiao", author_association:"OWNER", body:("/approve-merge " + $sha), updated_at:"2026-11-26T00:00:00Z"}]' \
  > "$fixture/pr-comments.json"
AUTO_MERGE=1 FINAL_ROOT="$fixture/final-p0-owner" run_loop final-gate
assert_calls 1 'mark-pr-ready 7'
assert_calls 1 "merge-pr 7 merge ${MOCK_SHA}"
assert_calls 1 'set-state pr 7 done'
compgen -G "$fixture/final-p0-owner/pr-7/merge-output-*.log" >/dev/null || fail '合并成功未生成 merge-output-*.log'
if compgen -G "$fixture/final-p0-owner/pr-7/merge-error-*.log" >/dev/null; then
  fail '合并成功不应生成 merge-error-*.log'
fi

# 6d. 合入前实时复读发现 headRefOid 已变 -> 取消合入并退回 changes-requested
jq -n '{title:"普通单", body:"正常需求", labels:[], url:"https://example.invalid/issues/42"}' > "$fixture/issue.json"
jq '{number:7, state:"OPEN", isDraft:true, headRefName:"main", baseRefName:"main", headRefOid:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", labels:[]}' \
  "$fixture/pr.json" > "$fixture/live-pr.json"
AUTO_MERGE=1 FINAL_ROOT="$fixture/final-p0-headchanged" run_loop final-gate
assert_calls 1 'mark-pr-ready 7'
assert_calls 1 "merge-pr 7 merge ${MOCK_SHA}"
grep -Fq '最新提交已变为 aaaaaaaaaa' "$fixture/final-p0-headchanged/pr-7/final-gate-comment.md" || fail 'head 变动未在终审评论中提示'
rm -f "$fixture/live-pr.json" "$fixture/issue.json" "$fixture/pr-comments.json"

# 7. E2E 按原因接续：return_to_dev 退回 Dev（changes-requested），return_to_review 退回 Review（同 SHA 自动触发复审并交回 E2E）
handoff_rev="$fixture/reviews-e2e-handoff"
handoff_e2e="$fixture/e2e-handoff"
rm -f "$fixture/e2e-comment"
set_pr_body 'Closes #42 验证 E2E 交接流转'

# 7a. Review 首轮批准并给出需双账号的 E1
jq -n '{
  verdict:"approve", summary:"通过", e2e_decision:"run_e2e", e2e_decision_reason:"实测",
  e2e_checks:["双账号登录并验证整页重载保留原提交编号"], requires_human_decision:false,
  requirements_coverage:[], blocking_issues:[], non_blocking_notes:[]
}' > "$fixture/verdict.json"
REVIEWS_ROOT="$handoff_rev" run_loop review
grep -Fq 'Review 必须先核对每条 E2E 必验项的前置条件' "$fixture/last-prompt" || fail 'Review 提示词缺少前置条件核对要求'

# 7b. E2E 发现维护 QA 脚本缺失准备步骤 -> return_to_dev -> PR 和 Issue 均切为 changes-requested（不落入 blocked）
before_pr_cr="$(grep -Fxc -- 'set-state pr 7 changes-requested' "$fixture/calls" || true)"
before_issue_cr="$(grep -Fxc -- 'set-state issue 42 changes-requested' "$fixture/calls" || true)"
jq -n '{
  verdict:"return_to_dev", summary:"现有 QA 入口缺少测试用户准备和清理步骤", environment:"测试环境",
  scenarios:[{id:"E1", name:"双账号准备", status:"blocked", details:"QA 脚本缺少创建测试账号与授权步骤", evidence_paths:[]}],
  evidence_paths:[],
  failure_details:[{title:"QA 入口缺少可复用准备步骤", reproduction:"运行 qa 入口", observed:"未创建测试账号", expected:"补齐预检、创建、运行与清理命令"}],
  remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$handoff_e2e" run_loop e2e
assert_calls "$((before_pr_cr + 1))" 'set-state pr 7 changes-requested'
assert_calls "$((before_issue_cr + 1))" 'set-state issue 42 changes-requested'
grep -Fq '仓库 QA 脚本或可复用准备步骤缺口' "$handoff_e2e/pr-7/e2e-comment.md" || fail 'return_to_dev 缺少交回 Dev 说明'

# 7c. E2E 发现必验项依赖候选版本尚未支持的能力 -> return_to_review -> 同 SHA 自动唤醒 Review 复审并收缩 e2e_checks -> E2E 重跑通过
handoff_e2e_rev="$fixture/e2e-handoff-review"
before_rev_handoff="$(grep -Fxc -- codex-review "$fixture/calls" || true)"
jq -n '{
  verdict:"return_to_review", summary:"候选后端仅接受单组登录凭据，无法实测双账号切换", environment:"测试环境",
  scenarios:[{id:"E1", name:"双账号登录隔离", status:"blocked", details:"候选后端仅配置单组凭据，已有双身份组件单测", evidence_paths:[]}],
  evidence_paths:[],
  failure_details:[{title:"E1 依赖候选版本尚未支持的多账号能力", reproduction:"检查候选后端登录配置", observed:"仅支持单组凭据", expected:"评审核对已有组件测试是否满足账号隔离回归并保留整页重载 E2E"}],
  remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$handoff_e2e_rev" run_loop e2e
assert_calls 1 'set-state pr 7 in-review'
assert_calls 1 'set-state issue 42 in-review'
grep -Fq "<!-- codex-e2e-handoff:${MOCK_SHA}:" "$fixture/e2e-comment" || fail 'return_to_review 未写入 E2E 交接标记'

# Review 在同 SHA + 同 PR body 下应识别 E2E 交接标记并重新评审，调整 e2e_checks 后 approve
jq -n '{
  verdict:"approve", summary:"核对已有双身份组件测试满足隔离回归，保留整页重载真实 E2E", e2e_decision:"run_e2e", e2e_decision_reason:"实测整页重载",
  e2e_checks:["单账号整页重载后保留原提交编号"], requires_human_decision:false,
  requirements_coverage:[], blocking_issues:[], non_blocking_notes:[]
}' > "$fixture/verdict.json"
REVIEWS_ROOT="$handoff_rev" run_loop review
assert_calls "$((before_rev_handoff + 1))" codex-review
grep -Fq 'E2E 退回复审交接' "$fixture/last-prompt" || fail 'Review 复审提示词未注入 E2E 退回复审交接说明'
# 同一交接标记再次轮询不应重复触发评审（防止死循环）
REVIEWS_ROOT="$handoff_rev" run_loop review
assert_calls "$((before_rev_handoff + 1))" codex-review

# E2E 在同一 SHA 下因评审必验场景已更新而自动重跑并通过
before_e2e_pass="$(grep -Fxc -- 'set-state pr 7 e2e-passed' "$fixture/calls" || true)"
jq -n '{
  verdict:"pass", summary:"整页重载真实 E2E 通过", environment:"测试环境",
  scenarios:[{id:"E1", name:"单账号整页重载后保留原提交编号", status:"passed", details:"实测通过", evidence_paths:["upgrade.log"]}],
  evidence_paths:["upgrade.log"], failure_details:[], remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$handoff_e2e_rev" run_loop e2e
assert_calls "$((before_e2e_pass + 1))" 'set-state pr 7 e2e-passed'
grep -Fq 'E1 单账号整页重载后保留原提交编号' "$fixture/last-prompt" || fail 'E2E 未按复审更新后的必验场景重跑'

# 8. 按修复进展判停（#474 场景）：每轮关闭上一轮阻塞项时，第 3 轮仍继续交回 Dev，且 meta 内嵌阻塞关闭条件；连续无进展时暂停
progress_rev="$fixture/reviews-progress"
before_prog_cr="$(grep -Fxc -- 'set-state pr 7 changes-requested' "$fixture/calls" || true)"
before_prog_blk="$(grep -Fxc -- 'set-state pr 7 blocked' "$fixture/calls" || true)"

# R1: 3 项阻塞
jq -n '{
  verdict:"request_changes", summary:"首轮 3 项阻塞", e2e_decision:"run_e2e", e2e_decision_reason:"",
  e2e_checks:[], requires_human_decision:false, requirements_coverage:[], non_blocking_notes:[],
  blocking_issues:[
    {id:"obs-binding", severity:"major", location:"a.ts:1", description:"观察未绑定", suggestion:"绑定", verification:"确认后变更目录观察 -> 派发前拦截 -> 旧请求不执行"},
    {id:"unknown-unlock", severity:"major", location:"b.java:2", description:"断链解锁", suggestion:"保持锁定", verification:"断链无可信凭证时锁定不重提；取得唯一凭证后解锁并展示来源明确的时间"},
    {id:"contract-scope", severity:"major", location:"c.java:3", description:"普通查询契约", suggestion:"收回", verification:"普通查询传 expectedSourceRevision 不被拒绝"}
  ]
}' > "$fixture/verdict.json"
set_pr_body 'Closes #42 进展判停 R1'
REVIEWS_ROOT="$progress_rev" run_loop review
assert_calls "$((before_prog_cr + 1))" 'set-state pr 7 changes-requested'
grep -Fq '前置状态/边界输入 → 操作/触发条件 → 可观测预期结果' "$fixture/last-prompt" || fail 'Review 提示词缺少前置状态->操作->预期结果关闭条件要求'
grep -F 'codex-review-meta:' "$fixture/review-comment" | grep -Fq '"unknown-unlock"' || fail 'codex-review-meta 未内嵌阻塞项 ID'

# R2: 关闭 obs-binding 与 contract-scope，保留 unknown-unlock，新增 qa-preflight
jq -n '{
  verdict:"request_changes", summary:"次轮关闭两项，余两项", e2e_decision:"run_e2e", e2e_decision_reason:"",
  e2e_checks:[], requires_human_decision:false, requirements_coverage:[], non_blocking_notes:[],
  blocking_issues:[
    {id:"unknown-unlock", severity:"major", location:"b.java:20", description:"终态缺少时间", suggestion:"补核对时间", verification:"取得唯一凭证后解锁并展示来源明确的时间"},
    {id:"qa-preflight", severity:"major", location:"qa/m.py:10", description:"缺少审计预检", suggestion:"补预检", verification:"从 enable_audit_plugin=false 起测 -> 临时启用并读到唯一凭证 -> 成功与失败退出均恢复原值"}
  ]
}' > "$fixture/verdict.json"
set_pr_body 'Closes #42 进展判停 R2'
REVIEWS_ROOT="$progress_rev" run_loop review
assert_calls "$((before_prog_cr + 2))" 'set-state pr 7 changes-requested'

# R3: 关闭 unknown-unlock，仅剩 qa-preflight（第 2 次出现）-> 有实质进展，应继续 changes-requested 而非硬停 blocked
jq -n '{
  verdict:"request_changes", summary:"第三轮关闭终态时间，仅剩审计预检", e2e_decision:"run_e2e", e2e_decision_reason:"",
  e2e_checks:[], requires_human_decision:false, requirements_coverage:[], non_blocking_notes:[],
  blocking_issues:[
    {id:"qa-preflight", severity:"major", location:"qa/m.py:15", description:"未覆盖关闭态启用", suggestion:"支持 false 态启用并恢复", verification:"从 enable_audit_plugin=false 起测 -> 临时启用并读到唯一凭证 -> 成功与失败退出均恢复原值"}
  ]
}' > "$fixture/verdict.json"
set_pr_body 'Closes #42 进展判停 R3'
REVIEWS_ROOT="$progress_rev" run_loop review
assert_calls "$((before_prog_cr + 3))" 'set-state pr 7 changes-requested'
assert_calls "$before_prog_blk" 'set-state pr 7 blocked'
[[ "$(<"$progress_rev/pr-7/stalled_rounds.txt")" == "0" ]] || fail '每轮有关闭阻塞项时 stalled_rounds 应保持 0'

# 8b. 复审未关闭上一轮任何阻塞项达到 MAX_STALLED_REVIEW_ROUNDS 时触发停滞暂停
stall_rev="$fixture/reviews-stall"
jq -n '{
  verdict:"request_changes", summary:"首轮单阻塞", e2e_decision:"run_e2e", e2e_decision_reason:"",
  e2e_checks:[], requires_human_decision:false, requirements_coverage:[], non_blocking_notes:[],
  blocking_issues:[{id:"stall-item", severity:"major", location:"x.ts:1", description:"未修", suggestion:"修", verification:"输入 A -> 返回 B"}]
}' > "$fixture/verdict.json"
set_pr_body 'Closes #42 停滞测试 R1'
MAX_STALLED_REVIEW_ROUNDS=1 REVIEWS_ROOT="$stall_rev" run_loop review
assert_calls "$((before_prog_cr + 4))" 'set-state pr 7 changes-requested'
set_pr_body 'Closes #42 停滞测试 R2（未关闭 stall-item）'
MAX_STALLED_REVIEW_ROUNDS=1 REVIEWS_ROOT="$stall_rev" run_loop review
assert_calls "$((before_prog_blk + 1))" 'set-state pr 7 blocked'
grep -Fq '复审未关闭上一轮任何阻塞项' "$fixture/review-comment" || fail '停滞暂停评论缺少无进展说明'

# 9. Review 提示词注入宿主机实测变更规模与测试/QA 复核信号，并包含重复测试/通用 QA 底座双向规则
mkdir -p "$fixture/repo/frontend/src" "$fixture/repo/qa"
seq 1 90 | sed 's/^/t_/' > "$fixture/repo/frontend/src/demo.test.ts"
seq 1 20 | sed 's/^/r_/' > "$fixture/repo/qa/browser-runtime.cjs"
git -C "$fixture/repo" add frontend/src/demo.test.ts qa/browser-runtime.cjs
git -C "$fixture/repo" commit -qm 'feat: add oversized test and qa runtime'
git -C "$fixture/repo" checkout -q -b feat/metrics-check
git -C "$fixture/repo" push -q origin feat/metrics-check
metrics_sha="$(git -C "$fixture/repo" rev-parse HEAD)"
git -C "$fixture/repo" checkout -q main
git -C "$fixture/repo" reset -q --hard HEAD~1
jq -n --arg sha "$metrics_sha" '[{number: 7, title:"Metrics", body:"Closes #42", url:"https://example.invalid/pull/7",
  headRefName:"feat/metrics-check", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", updatedAt:"metrics"}]' > "$fixture/pr.json"
jq -n '{title:"测试规模", body:"生产约 110–200 行，必要测试 30–75 行", labels:[], url:"https://example.invalid/issues/42"}' > "$fixture/issue.json"
cp "$fixture/approve.json" "$fixture/verdict.json"
REVIEWS_ROOT="$fixture/reviews-metrics" run_loop review
grep -Fq '## 变更规模与测试/QA 复核信号（宿主机实测）' "$fixture/last-prompt" || fail 'Review 提示词未注入宿主机实测变更规模'
grep -Fq '超出 Issue 估算上限 75 行' "$fixture/last-prompt" || fail 'Review 提示词未提示内部测试超估算'
grep -Fq 'qa/browser-runtime.cjs' "$fixture/last-prompt" || fail 'Review 提示词未标出通用 QA 运行时改动'
grep -Fq '不得在功能 PR 复审中追加跨单通用 QA 底座需求作为阻塞项' "$fixture/last-prompt" || fail 'Review 提示词缺少不追加通用 QA 底座需求的双向约束'
grep -Fq '重复/低价值测试膨胀' "$fixture/last-prompt" || fail 'Review 提示词缺少重复测试膨胀阻塞准则'

# 10. Final Gate 合并成功后按终审研判 + 宿主机硬门禁为已解除依赖的既有 Open Issue 添加 agy:todo
cp "$fixture/original-comment" "$fixture/review-comment"
jq -n --arg sha "$MOCK_SHA" '[{number: 7, title:"Fixture", body:"Closes #42", url:"https://example.invalid/pull/7",
  state:"OPEN", isDraft:false, headRefName:"main", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", labels:[], updatedAt:"queue-next"}]' > "$fixture/pr.json"
jq -n '{number:42, title:"前置底座", body:"普通需求", state:"OPEN", labels:[{name:"agy:e2e-passed"}], url:"https://example.invalid/issues/42"}' > "$fixture/issue-42.json"
jq -n '{number:50, title:"下游单 A", body:"前置依赖：#42\n验收标准：完成下游 A。", state:"OPEN", labels:[{name:"enhancement"}], url:"https://example.invalid/issues/50"}' > "$fixture/issue-50.json"
jq -n '{number:51, title:"进行中单", body:"前置依赖：#42", state:"OPEN", labels:[{name:"agy:in-progress"}], url:"https://example.invalid/issues/51"}' > "$fixture/issue-51.json"
jq -n '{number:52, title:"别名已入队单", body:"前置依赖：#42", state:"OPEN", labels:[{name:"ready-for-agent"}], url:"https://example.invalid/issues/52"}' > "$fixture/issue-52.json"
jq -n '{number:53, title:"人工标签单", body:"前置依赖：#42", state:"OPEN", labels:[{name:"needs-human"}], url:"https://example.invalid/issues/53"}' > "$fixture/issue-53.json"
jq -n '{number:54, title:"需 Owner 确认单", body:"前置依赖：#42\n待 Owner 确认后再开发。", state:"OPEN", labels:[], url:"https://example.invalid/issues/54"}' > "$fixture/issue-54.json"
jq -n '{number:55, title:"发版追踪单", body:"<!-- gongcao-release -->\n前置依赖：#42", state:"OPEN", labels:[], url:"https://example.invalid/issues/55"}' > "$fixture/issue-55.json"
jq -n '{number:56, title:"仍有未关依赖单", body:"前置依赖：#42、#60", state:"OPEN", labels:[], url:"https://example.invalid/issues/56"}' > "$fixture/issue-56.json"
jq -n '{number:57, title:"已关闭单", body:"前置依赖：#42", state:"CLOSED", labels:[], url:"https://example.invalid/issues/57"}' > "$fixture/issue-57.json"
jq -n '{number:58, title:"下游单 B", body:"Depends on #42\n实现下游 B（删除前需要人工确认弹窗）。", state:"OPEN", labels:[], url:"https://example.invalid/issues/58"}' > "$fixture/issue-58.json"
jq -n '{number:59, title:"下游单 C（超限）", body:"Depends on #42\n第三条就绪单。", state:"OPEN", labels:[], url:"https://example.invalid/issues/59"}' > "$fixture/issue-59.json"
jq -n '{number:60, title:"未关闭前置单", body:"仍在排队", state:"OPEN", labels:[], url:"https://example.invalid/issues/60"}' > "$fixture/issue-60.json"
jq -n '{number:99, title:"新建后续单", body:"来源 PR #7", state:"OPEN", labels:[], url:"https://example.invalid/issues/99"}' > "$fixture/issue-99.json"
jq -s '.' "$fixture"/issue-{42,50,51,52,53,54,55,56,58,59,60}.json > "$fixture/open-issues.json"

jq -n '{
  verdict:"merge", summary:"可合入并解锁下游单", merge_method:"merge", merge_method_reason:"默认",
  audit_checks:[], pr_title:"", pr_body:"", issue_closing_note:"已完成收口",
  blocking_issues:[], non_blocking_notes:[],
  follow_up_issues:[{slug:"fu-item", title:"后续改进项", priority:"P2", reason:"遗留改进", body:"详细说明"}],
  queue_next_issues:[
    {issue_number:42, reason:"误推当前单"},
    {issue_number:99, reason:"误推新建后续单"},
    {issue_number:50, reason:"前置 #42 已合入"},
    {issue_number:50, reason:"重复项应去重"},
    {issue_number:51, reason:"已在开发中"},
    {issue_number:52, reason:"已有 ready-for-agent"},
    {issue_number:53, reason:"带人工标签"},
    {issue_number:54, reason:"需 Owner 确认"},
    {issue_number:55, reason:"发版追踪单"},
    {issue_number:56, reason:"仍依赖未关闭 #60"},
    {issue_number:57, reason:"已关闭单"},
    {issue_number:58, reason:"前置 #42 已合入，第二顺位"},
    {issue_number:59, reason:"超出上限"}
  ]
}' > "$fixture/decision.json"

# 10a. AUTO_MERGE=0（未实际合并）时绝不提前为下游 Issue 添加 agy:todo
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-queue-nomerge" run_loop final-gate
assert_calls 0 'set-state issue 50 todo'
assert_calls 0 'set-state issue 58 todo'
grep -Fq '前置依赖：#42' "$fixture/last-prompt" || fail 'Final Gate 提示词未注入 Open Issues 正文摘要'
grep -Fq 'queue_next_issues' "$fixture/last-prompt" || fail 'Final Gate 提示词缺少 queue_next_issues 研判准则'

# 10b. AUTO_QUEUE_NEXT_ISSUES=0 时即使合并成功也不自动入队
AUTO_MERGE=1 AUTO_QUEUE_NEXT_ISSUES=0 FINAL_ROOT="$fixture/final-queue-disabled" run_loop final-gate
assert_calls 0 'set-state issue 50 todo'
assert_calls 0 'set-state issue 58 todo'

# 10c. AUTO_MERGE=1 合并成功后：仅 #50 与 #58 通过硬门禁并按先评论后打标切换为 agy:todo，其余全部拦截
AUTO_MERGE=1 MAX_QUEUED_NEXT_ISSUES=2 FINAL_ROOT="$fixture/final-queue-ok" run_loop final-gate
assert_calls 1 'comment-auto-queue issue 50'
assert_calls 1 'set-state issue 50 todo'
assert_calls 1 'comment-auto-queue issue 58'
assert_calls 1 'set-state issue 58 todo'
for blocked_inum in 42 51 52 53 54 55 56 57 59 99; do
  assert_calls 0 "set-state issue ${blocked_inum} todo"
done
c50_line="$(grep -Fn 'comment-auto-queue issue 50' "$fixture/calls" | head -n 1 | cut -d: -f1)"
s50_line="$(grep -Fn 'set-state issue 50 todo' "$fixture/calls" | head -n 1 | cut -d: -f1)"
[[ -n "$c50_line" && -n "$s50_line" && "$c50_line" -lt "$s50_line" ]] \
  || fail "自动入队应先写评论再切 agy:todo 标签 (comment=$c50_line, set-state=$s50_line)"
grep -Fq '前置 #42 已合入' "$fixture/auto-queue-comment-50.md" || fail '自动入队说明评论未写入目标 Issue'
grep -Fq '自动入队的下游/既有 Open Issue' "$fixture/final-queue-ok/pr-7/final-gate-comment.md" || fail '终审评论缺少自动入队汇总'
grep -Fq '未自动入队的候选 Issue（宿主机硬门禁拦截）' "$fixture/final-queue-ok/pr-7/final-gate-comment.md" || fail '终审评论缺少门禁拦截明细'
grep -Fq '仍声明依赖未关闭的 Open Issue #60' "$fixture/final-queue-ok/pr-7/final-gate-comment.md" || fail '终审评论未记录未关闭依赖拦截原因'
grep -Fq '已达单次自动入队上限' "$fixture/final-queue-ok/pr-7/final-gate-comment.md" || fail '终审评论未记录上限拦截原因'
jq -e '
  ([.queued_next_issues[] | select(.status == "queued") | .number] == [50, 58])
  and ([.queued_next_issues[] | select(.status == "skipped")] | length == 10)
' "$fixture/final-queue-ok/pr-7/meta.json" >/dev/null \
  || { cat "$fixture/final-queue-ok/pr-7/meta.json" >&2; fail 'meta.json 的 queued_next_issues 记录不符合预期'; }
rm -f "$fixture"/issue-*.json "$fixture/open-issues.json" "$fixture"/auto-queue-comment-*.md

# 11. Review e2e_checks 基线防漂移门禁：Issue 正文未更新且非 E2E return_to_review 交接时，忽略复审改写并沿用批准基线；Issue 正文更新后允许变更
drift_rev="$fixture/reviews-e2e-drift"
rm -f "$fixture/e2e-comment"
jq -n '{number:42, title:"双窗引用核对", body:"原始 Issue 要求：核对双 Guest 真实失焦与复焦。", state:"OPEN", labels:[], url:"https://example.invalid/issues/42"}' > "$fixture/issue.json"
jq -n --arg sha "$MOCK_SHA" '[{number: 7, title:"DriftGuard", body:"Closes #42 首轮提交", url:"https://example.invalid/pull/7",
  state:"OPEN", isDraft:true, headRefName:"main", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", labels:[], updatedAt:"drift-1"}]' > "$fixture/pr.json"
jq -n '{
  verdict:"approve", summary:"首轮批准", e2e_decision:"run_e2e", e2e_decision_reason:"实测",
  e2e_checks:["核对双 Guest 真实失焦与复焦"], requires_human_decision:false,
  requirements_coverage:[], blocking_issues:[], non_blocking_notes:[]
}' > "$fixture/verdict.json"
REVIEWS_ROOT="$drift_rev" run_loop review
[[ -s "$drift_rev/pr-7/e2e-checks-baseline.json" ]] || fail '首轮 approve 未写入 e2e-checks-baseline.json'

# 复审（Issue 正文未改、非 return_to_review 交接）试图将 E2E 环境故障现场倒灌进 e2e_checks -> 宿主机强制沿用基线
set_pr_body 'Closes #42 返工后复审'
jq -n '{
  verdict:"approve", summary:"复审批准", e2e_decision:"run_e2e", e2e_decision_reason:"实测",
  e2e_checks:["从 Windows Terminal 持有前台的已解锁桌面启动并核对双 Guest"], requires_human_decision:false,
  requirements_coverage:[], blocking_issues:[], non_blocking_notes:[]
}' > "$fixture/verdict.json"
REVIEWS_ROOT="$drift_rev" run_loop review
grep -Fq '## 已锁定 E2E 必验基线（宿主机防漂移保护）' "$fixture/last-prompt" || fail '复审提示词未注入已锁定 E2E 必验基线'
grep -Fq '宿主机 `e2e_checks` 防漂移保护' "$fixture/review-comment" || fail '复审改写必验项时未记录防漂移保护说明'
grep -F 'codex-review-meta:' "$fixture/review-comment" | grep -Fq '核对双 Guest 真实失焦与复焦' || fail '宿主机未保留既有 e2e_checks 基线'
if grep -F 'codex-review-meta:' "$fixture/review-comment" | grep -Fq 'Windows Terminal'; then
  fail '复审倒灌的外部桌面环境条件未被宿主机拦截'
fi

# 当关联 Issue 正文已更新后，允许 Review 更新 e2e_checks 并刷新基线
jq -n '{number:42, title:"双窗引用核对", body:"更新后的 Issue 要求：先定向证明 Terminal 前台到所属主 Guest。", state:"OPEN", labels:[], url:"https://example.invalid/issues/42"}' > "$fixture/issue.json"
set_pr_body 'Closes #42 Issue 正文已更新后复审'
jq -n '{
  verdict:"approve", summary:"按更新后 Issue 调整必验项", e2e_decision:"run_e2e", e2e_decision_reason:"实测",
  e2e_checks:["先定向证明 Terminal 前台到所属主 Guest"], requires_human_decision:false,
  requirements_coverage:[], blocking_issues:[], non_blocking_notes:[]
}' > "$fixture/verdict.json"
REVIEWS_ROOT="$drift_rev" run_loop review
grep -F 'codex-review-meta:' "$fixture/review-comment" | grep -Fq '先定向证明 Terminal 前台到所属主 Guest' || fail 'Issue 更新后未放行新的 e2e_checks'
jq -e '.e2e_checks == ["先定向证明 Terminal 前台到所属主 Guest"]' "$drift_rev/pr-7/e2e-checks-baseline.json" >/dev/null || fail 'Issue 更新后未刷新 e2e-checks-baseline.json'

# 12. E2E 宿主机硬门禁：reproducible_in_dev_sandbox=false 直接阻断 return_to_dev；同 failure_stage 连续复发提前短路 blocked
# 12a. reproducible_in_dev_sandbox=false -> 立即覆写为 blocked（不退回 changes-requested，且不写入 verified_shas 以便人工排障后同 SHA 重跑）
cp "$fixture/original-comment" "$fixture/review-comment"
jq -n --arg sha "$MOCK_SHA" '[{number: 7, title:"E2EGuard", body:"Closes #42", url:"https://example.invalid/pull/7",
  state:"OPEN", isDraft:true, headRefName:"main", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", labels:[], updatedAt:"e2e-guard-1"}]' > "$fixture/pr.json"
e2e_nonrepro="$fixture/e2e-nonrepro"
before_blk_12a="$(grep -Fxc -- 'set-state pr 7 blocked' "$fixture/calls" || true)"
before_cr_12a="$(grep -Fxc -- 'set-state pr 7 changes-requested' "$fixture/calls" || true)"
jq -n '{
  verdict:"return_to_dev", summary:"Windows Terminal 持有前台导致登录前失败", environment:"Windows RDP",
  failure_stage:"login-main", reproducible_in_dev_sandbox:false,
  scenarios:[{id:"E1", name:"主窗登录", status:"failed", details:"Terminal 持有前台 66456", evidence_paths:[]}],
  evidence_paths:[],
  failure_details:[{title:"RDP 前台锁导致主 Guest 无法激活", reproduction:"RDP 桌面运行", observed:"activation-window-covered", expected:"取得主 Guest 前台"}],
  remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$e2e_nonrepro" run_loop e2e
assert_calls "$((before_blk_12a + 1))" 'set-state pr 7 blocked'
assert_calls "$before_cr_12a" 'set-state pr 7 changes-requested'
grep -Fq '宿主机硬路由拦截' "$e2e_nonrepro/pr-7/e2e-comment.md" || fail 'non-reproducible 拦截未写入 E2E 评论'
jq -e '.host_route_override == "non_reproducible_in_dev_sandbox" and .reproducible_in_dev_sandbox == false and .failure_stage == "login-main"' "$e2e_nonrepro/pr-7/meta.json" >/dev/null \
  || { cat "$e2e_nonrepro/pr-7/meta.json" >&2; fail 'non-reproducible 的 meta.json 记录不符合预期'; }
[[ ! -s "$e2e_nonrepro/pr-7/verified_shas.txt" ]] || fail '被宿主机拦截切 blocked 时不应记录 verified_shas'

# 12b. 同 failure_stage 连续 2 轮 return_to_dev -> 在 MAX_E2E_ROUNDS=3 前由 MAX_REPEAT_E2E_STAGE=2 短路切 blocked
e2e_repeat="$fixture/e2e-repeat-stage"
before_blk_12b="$(grep -Fxc -- 'set-state pr 7 blocked' "$fixture/calls" || true)"
before_cr_12b="$(grep -Fxc -- 'set-state pr 7 changes-requested' "$fixture/calls" || true)"
jq -n '{
  verdict:"return_to_dev", summary:"首次在 login-main 失败", environment:"Windows RDP",
  failure_stage:"login-main", reproducible_in_dev_sandbox:true,
  scenarios:[{id:"E1", name:"主窗登录", status:"failed", details:"caption-unavailable", evidence_paths:[]}],
  evidence_paths:[],
  failure_details:[{title:"login-main 首次失败", reproduction:"运行入口", observed:"caption-unavailable", expected:"通过登录"}],
  remaining_risks:[]
}' > "$fixture/result.json"
MAX_E2E_ROUNDS=3 MAX_REPEAT_E2E_STAGE=2 E2E_ROOT="$e2e_repeat" run_loop e2e
assert_calls "$((before_cr_12b + 1))" 'set-state pr 7 changes-requested'
assert_calls "$before_blk_12b" 'set-state pr 7 blocked'

# 第二轮使用更新后的评审场景 key 模拟新提交/重跑，仍在同一 failure_stage=login-main 失败 -> 短路 blocked
sed 's/检查结果/检查第二轮结果/' "$fixture/original-comment" > "$fixture/review-comment"
jq '.[0].updatedAt = "e2e-guard-2"' "$fixture/pr.json" > "$fixture/pr-tmp.json"
mv "$fixture/pr-tmp.json" "$fixture/pr.json"
MAX_E2E_ROUNDS=3 MAX_REPEAT_E2E_STAGE=2 E2E_ROOT="$e2e_repeat" run_loop e2e
assert_calls "$((before_blk_12b + 1))" 'set-state pr 7 blocked'
assert_calls "$((before_cr_12b + 1))" 'set-state pr 7 changes-requested'
grep -Fq '## 本周期历史 E2E 失败检查点' "$fixture/last-prompt" || fail 'E2E 提示词未注入历史失败检查点'
grep -Fq '宿主机防盲猜短路' "$e2e_repeat/pr-7/e2e-comment.md" || fail '重复检查点短路未写入 E2E 评论'
jq -e '.host_route_override == "repeat_failure_stage" and .failure_stage == "login-main"' "$e2e_repeat/pr-7/meta.json" >/dev/null \
  || { cat "$e2e_repeat/pr-7/meta.json" >&2; fail '重复检查点短路的 meta.json 记录不符合预期'; }
rm -f "$fixture/issue.json"

# 13. 复审显式逐项处置（previous_blocker_dispositions）防改名伪关闭 + e2e_plan 与首跑产物哈希校验
disp_rev="$fixture/reviews-disp"
jq -n --arg sha "$MOCK_SHA" '[{number: 7, title:"Fixture", body:"Closes #42 显式处置 R1", url:"https://example.invalid/pull/7",
  headRefName:"main", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", updatedAt:"disp-r1"}]' > "$fixture/pr.json"
jq -n '{title:"显式处置", body:"需求正文", labels:[], url:"https://example.invalid/issues/42"}' > "$fixture/issue.json"
jq -n '{
  verdict:"request_changes", summary:"首轮阻塞", e2e_decision:"run_e2e", e2e_decision_reason:"",
  e2e_checks:[], e2e_plan:[], previous_blocker_dispositions:[], requires_human_decision:false,
  requirements_coverage:[], non_blocking_notes:[],
  blocking_issues:[{id:"orig-blocker", severity:"major", location:"a.ts:1", description:"问题", suggestion:"修复", verification:"输入 false -> 输出 true"}]
}' > "$fixture/verdict.json"
REVIEWS_ROOT="$disp_rev" run_loop review

# R2a: 换名伪关闭（previous_blocker_dispositions 未处置 orig-blocker）-> 必须被 Schema 门禁拒绝，不写入状态
before_disp_state="$(grep -Fxc -- 'set-state pr 7 changes-requested' "$fixture/calls" || true)"
jq -n '{
  verdict:"request_changes", summary:"企图换名", e2e_decision:"run_e2e", e2e_decision_reason:"",
  e2e_checks:[], e2e_plan:[], previous_blocker_dispositions:[], requires_human_decision:false,
  requirements_coverage:[], non_blocking_notes:[],
  blocking_issues:[{id:"renamed-blocker", severity:"major", location:"a.ts:1", description:"换名", suggestion:"修复", verification:"输入 false -> 输出 true"}]
}' > "$fixture/verdict.json"
set_pr_body 'Closes #42 显式处置 R2a 换名'
REVIEWS_ROOT="$disp_rev" run_loop review
assert_calls "$before_disp_state" 'set-state pr 7 changes-requested'

# R2b: 显式关闭 orig-blocker 并附带 e2e_plan（preserve_first_run=true）-> 通过评审
before_disp_app="$(grep -Fxc -- 'set-state pr 7 approved' "$fixture/calls" || true)"
jq -n '{
  verdict:"approve", summary:"显式关闭通过", e2e_decision:"run_e2e", e2e_decision_reason:"需实测首跑",
  e2e_checks:["保留首跑并验证升级"],
  e2e_plan:[{id:"E1", scenario:"保留首跑并验证升级", capability_basis:"候选支持升级", entrypoint:"qa/metadata-evidence.py list", preflight_hint:"检查入口注册", preserve_first_run:true}],
  previous_blocker_dispositions:[{id:"orig-blocker", status:"closed", evidence:"test_false 通过"}],
  requires_human_decision:false, requirements_coverage:[], blocking_issues:[], non_blocking_notes:[]
}' > "$fixture/verdict.json"
set_pr_body 'Closes #42 显式处置 R2b 通过'
REVIEWS_ROOT="$disp_rev" run_loop review
assert_calls "$((before_disp_app + 1))" 'set-state pr 7 approved'
grep -Fq '上一轮阻塞项逐项处置' "$fixture/review-comment" || fail '评审报告未渲染上一轮阻塞项逐项处置表'
grep -Fq 'E2E 可执行前置计划' "$fixture/review-comment" || fail '评审报告未渲染 E2E 可执行前置计划表'

# 14. preserve_first_run 校验 + manifest.json SHA256 防篡改校验
# 14a: 仅给普通平铺 upgrade.log（无 attempt-1 首跑路径）-> E2E 门禁转为 blocked
before_fr_blk="$(grep -Fxc -- 'set-state pr 7 blocked' "$fixture/calls" || true)"
jq -n '{
  verdict:"pass", summary:"只有平铺报告", environment:"测试环境", failure_stage:"", reproducible_in_dev_sandbox:true,
  scenarios:[{id:"E1", name:"保留首跑并验证升级", status:"passed", details:"通过", evidence_paths:["upgrade.log"]}],
  evidence_paths:["upgrade.log"], failure_details:[], remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$fixture/e2e-first-run-miss" run_loop e2e
assert_calls "$((before_fr_blk + 1))" 'set-state pr 7 blocked'

# 14b: 给出 runs/E1/attempt-1/report.log -> E2E 通过并写 file_hashes -> 终审验证通过 -> 篡改归档文件后终审拦截
jq -n '{
  verdict:"pass", summary:"首跑留存通过", environment:"测试环境", failure_stage:"", reproducible_in_dev_sandbox:true,
  scenarios:[{id:"E1", name:"保留首跑并验证升级", status:"passed", details:"通过", evidence_paths:["runs/E1/attempt-1/report.log"]}],
  evidence_paths:["runs/E1/attempt-1/report.log"], failure_details:[], remaining_risks:[]
}' > "$fixture/result.json"
before_fr_pass="$(grep -Fxc -- 'set-state pr 7 e2e-passed' "$fixture/calls" || true)"
E2E_ROOT="$fixture/e2e-first-run-ok" PUBLISH_EVIDENCE=1 run_loop e2e
assert_calls "$((before_fr_pass + 1))" 'set-state pr 7 e2e-passed'
git -C "$fixture/archive" pull -q origin qa/e2e-evidence
latest_entry="$(ls -dt "$fixture/archive/pr-7/"* | head -n 1)"
jq -e '.file_hashes["artifacts/runs/E1/attempt-1/report.log"].sha256 | length == 64' "$latest_entry/manifest.json" >/dev/null \
  || fail 'manifest.json 缺少归档产物 SHA256 哈希'
before_fr_ready="$(grep -Fxc -- 'set-state pr 7 ready-to-merge' "$fixture/calls" || true)"
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-hash-ok" run_loop final-gate
assert_calls "$((before_fr_ready + 1))" 'set-state pr 7 ready-to-merge'

# 篡改归档文件内容 -> Final-Gate 必须阻断
printf 'tampered\n' > "$latest_entry/artifacts/runs/E1/attempt-1/report.log"
commit_archive tamper-artifact
before_tamper_blk="$(grep -Fxc -- 'set-state pr 7 blocked' "$fixture/calls" || true)"
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-hash-tamper" run_loop final-gate
assert_calls "$((before_tamper_blk + 1))" 'set-state pr 7 blocked'
grep -Fq 'QA 归档文件哈希校验失败' "$fixture/final-hash-tamper/pr-7/final-gate-comment.md" || fail '终审未拦截被篡改的归档产物'

# 15. E2E 持久化交接重试（pending-e2e.json）：写评论与 Issue 切标失败后不重跑 codex-e2e，且正确续完
retry_e2e="$fixture/e2e-handoff-retry"
before_e2e_calls="$(grep -Fxc -- codex-e2e "$fixture/calls" || true)"
before_e2e_wr="$(grep -Fxc -- write-e2e "$fixture/calls" || true)"
touch "$fixture/fail-e2e-comment" "$fixture/fail-issue-state"
E2E_ROOT="$retry_e2e" run_loop e2e
E2E_ROOT="$retry_e2e" run_loop e2e
# 模拟 PR 已切离 agy:approved，残留 Issue 交接在下次轮询自动续完
cp "$fixture/pr.json" "$fixture/pr-e2e-bak.json"
printf '[]\n' > "$fixture/pr.json"
E2E_ROOT="$retry_e2e" run_loop e2e
mv "$fixture/pr-e2e-bak.json" "$fixture/pr.json"
assert_calls "$((before_e2e_calls + 1))" codex-e2e
assert_calls "$((before_e2e_wr + 2))" write-e2e
[[ ! -f "$retry_e2e/pr-7/pending-e2e.json" ]] || fail 'E2E 交接完成后仍残留 pending-e2e.json'
[[ -s "$retry_e2e/pr-7/attempts.jsonl" ]] || fail 'E2E 未写入 attempts.jsonl 结构化记录'

# 16. 宿主机轻量预检零 Token 短路（exit 10 -> return_to_dev，exit 11 -> return_to_review）与资源租约阻断叠加
before_pf_e2e="$(grep -Fxc -- codex-e2e "$fixture/calls" || true)"
before_pf_cr="$(grep -Fxc -- 'set-state pr 7 changes-requested' "$fixture/calls" || true)"
E2E_ROOT="$fixture/e2e-pf-dev" E2E_PREFLIGHT_CMD='echo "missing qa action"; exit 10' run_loop e2e
assert_calls "$before_pf_e2e" codex-e2e
assert_calls "$((before_pf_cr + 1))" 'set-state pr 7 changes-requested'
grep -Fq 'codex-e2e-meta:' "$fixture/e2e-comment" || fail 'E2E 评论未写入 codex-e2e-meta'
grep -Fq 'preflight-return_to_dev' "$fixture/e2e-comment" || fail '预检 exit 10 未写入结构化 preflight-return_to_dev 项'

before_pf_rev="$(grep -Fxc -- 'set-state pr 7 in-review' "$fixture/calls" || true)"
E2E_ROOT="$fixture/e2e-pf-rev" E2E_PREFLIGHT_CMD='echo "single credential only"; exit 11' run_loop e2e
assert_calls "$before_pf_e2e" codex-e2e
assert_calls "$((before_pf_rev + 1))" 'set-state pr 7 in-review'
grep -Fq "<!-- codex-e2e-handoff:${MOCK_SHA}:" "$fixture/e2e-comment" || fail '预检 exit 11 未写入 E2E 退回复审交接标记'

# 资源清理失败保留 cleanup_failed 租约，并阻止下一次叠加启动 codex-e2e
lease_e2e="$fixture/e2e-lease"
before_lease_e2e="$(grep -Fxc -- codex-e2e "$fixture/calls" || true)"
E2E_ROOT="$lease_e2e" E2E_CLEANUP_CMD='echo "destroy failed"; exit 1' run_loop e2e
assert_calls "$((before_lease_e2e + 1))" codex-e2e
[[ -f "$lease_e2e/active-leases/pr-7.json" ]] || fail '清理失败后未保留 active-leases 租约'
jq -e '.status == "cleanup_failed"' "$lease_e2e/active-leases/pr-7.json" >/dev/null || fail '租约状态应为 cleanup_failed'
# 移除 verified_shas 模拟下轮重试 -> 因租约补偿清理仍失败，必须阻止再次调用 codex-e2e
: > "$lease_e2e/pr-7/verified_shas.txt"
E2E_ROOT="$lease_e2e" E2E_CLEANUP_CMD='echo "still failing"; exit 1' run_loop e2e
assert_calls "$((before_lease_e2e + 1))" codex-e2e
rm -f "$fixture/issue.json"

# 17. 必验条款编号与 E2E 计划强对应门禁（复现 #479 / PR #491 漏网路径）
# 17a: 查看者条款标为 partial（或 requires_real_e2e=true 却仅以单测/MockMvc 充当 verified_evidence，或 scheduled_e2e 未映射到 e2e_plan）时，宿主机拦截 approve
req_rev="$fixture/reviews-req-gate"
jq -n --arg sha "$MOCK_SHA" '[{number: 7, title:"Fixture", body:"Closes #42 必验条款门禁", url:"https://example.invalid/pull/7",
  headRefName:"main", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", updatedAt:"req-gate-1"}]' > "$fixture/pr.json"
jq -n '{title:"双账号查看者验收", body:"[REQ-VIEWER-E2E] 查看者用独立 Edge Guest 登录，可读不可写且 POST 返回 403", labels:[], url:"https://example.invalid/issues/42"}' > "$fixture/issue.json"

before_req_app="$(grep -Fxc -- 'set-state pr 7 approved' "$fixture/calls" || true)"
jq -n '{
  verdict:"approve", summary:"遗漏查看者场景却企图放行", e2e_decision:"run_e2e", e2e_decision_reason:"仅跑编辑场景",
  e2e_checks:["E1-editor: 编辑账号保存业务信息"],
  e2e_plan:[{id:"E1", scenario:"E1-editor: 编辑账号保存业务信息", capability_basis:"候选支持编辑登录", entrypoint:"qa/e2e.py run", preflight_hint:"qa/e2e.py preflight", preserve_first_run:false}],
  previous_blocker_dispositions:[], requires_human_decision:false, blocking_issues:[], non_blocking_notes:[],
  requirements_coverage:[{
    id:"REQ-VIEWER-E2E", requirement:"真实查看者只读与 403 写入拒绝", status:"partial",
    requires_real_e2e:true, disposition:"verified_evidence", e2e_plan_ids:[], waiver_ref:"",
    evidence:"MockMvc 已覆盖，真实查看者记为 NOT_RUN"
  }]
}' > "$fixture/verdict.json"
E2E_EVIDENCE_BRANCH="qa/test17-none" REVIEWS_ROOT="$req_rev" run_loop review
assert_calls "$before_req_app" 'set-state pr 7 approved'

# scheduled_e2e 引用了不存在的 e2e_plan ID -> 同样拦截
jq '.requirements_coverage[0] += {disposition:"scheduled_e2e", e2e_plan_ids:["E9"]}' "$fixture/verdict.json" > "$fixture/verdict-tmp.json"
mv "$fixture/verdict-tmp.json" "$fixture/verdict.json"
E2E_EVIDENCE_BRANCH="qa/test17-none" REVIEWS_ROOT="$req_rev" run_loop review
assert_calls "$before_req_app" 'set-state pr 7 approved'

# requires_real_e2e=true 标为 met + verified_evidence 但无既往通过 E2E -> 同样拦截（不可用单测代替真实登录）
jq '.requirements_coverage[0] += {status:"met", disposition:"verified_evidence", e2e_plan_ids:[]}' "$fixture/verdict.json" > "$fixture/verdict-tmp.json"
mv "$fixture/verdict-tmp.json" "$fixture/verdict.json"
E2E_EVIDENCE_BRANCH="qa/test17-none" REVIEWS_ROOT="$req_rev" run_loop review
assert_calls "$before_req_app" 'set-state pr 7 approved'

# 17b: 将查看者场景加入 e2e_plan（E2）并在 requirements_coverage 以 scheduled_e2e 映射 E2 -> 允许 approve 进入 E2E
jq -n '{
  verdict:"approve", summary:"查看者场景已纳入 E2E 计划", e2e_decision:"run_e2e", e2e_decision_reason:"执行编辑与查看者双账号 E2E",
  e2e_checks:["E1-editor: 编辑账号保存业务信息", "E2-viewer: 查看者独立 Edge Guest 只读并验证写入 403"],
  e2e_plan:[
    {id:"E1", scenario:"E1-editor: 编辑账号保存业务信息", capability_basis:"候选支持编辑登录", entrypoint:"qa/e2e.py run", preflight_hint:"qa/e2e.py preflight", preserve_first_run:false},
    {id:"E2", scenario:"E2-viewer: 查看者独立 Edge Guest 只读并验证写入 403", capability_basis:"QA 夹具注册临时 VIEWER", entrypoint:"qa/e2e.py run --with-viewer", preflight_hint:"qa/e2e.py preflight --with-viewer", preserve_first_run:false}
  ],
  previous_blocker_dispositions:[], requires_human_decision:false, blocking_issues:[], non_blocking_notes:[],
  requirements_coverage:[{
    id:"REQ-VIEWER-E2E", requirement:"真实查看者只读与 403 写入拒绝", status:"partial",
    requires_real_e2e:true, disposition:"scheduled_e2e", e2e_plan_ids:["E2"], waiver_ref:"",
    evidence:"已排入 E2 真实查看者验收计划"
  }]
}' > "$fixture/verdict.json"
E2E_EVIDENCE_BRANCH="qa/test17-none" REVIEWS_ROOT="$req_rev" run_loop review
assert_calls "$((before_req_app + 1))" 'set-state pr 7 approved'
grep -Fq 'REQ-VIEWER-E2E' "$fixture/review-comment" || fail '评审报告未渲染必验条款编号 REQ-VIEWER-E2E'
grep -Fq '`scheduled_e2e` (E2)' "$fixture/review-comment" || fail '评审报告未渲染 scheduled_e2e (E2) 放行去向'

# 17c: E2E 对查看者场景仍记 NOT_RUN 却输出 verdict=pass -> 宿主机拒绝放行（不转 e2e-passed，强制转 blocked）
before_nr_pass="$(grep -Fxc -- 'set-state pr 7 e2e-passed' "$fixture/calls" || true)"
before_nr_blk="$(grep -Fxc -- 'set-state pr 7 blocked' "$fixture/calls" || true)"
jq -n '{
  verdict:"pass", summary:"编辑通过，查看者未执行", environment:"测试环境", failure_stage:"", reproducible_in_dev_sandbox:true,
  scenarios:[
    {id:"E1", name:"E1-editor: 编辑账号保存业务信息", status:"passed", details:"编辑保存通过", evidence_paths:["upgrade.log"]},
    {id:"E2", name:"E2-viewer: 查看者独立 Edge Guest 只读并验证写入 403", status:"passed", details:"NOT_RUN: 候选环境仅单账号，由 MockMvc 覆盖", evidence_paths:["upgrade.log"]}
  ],
  evidence_paths:["upgrade.log"], failure_details:[], remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$fixture/e2e-viewer-not-run" run_loop e2e
assert_calls "$before_nr_pass" 'set-state pr 7 e2e-passed'
assert_calls "$((before_nr_blk + 1))" 'set-state pr 7 blocked'
grep -Fq '固化到项目维护 QA 入口' "$fixture/last-prompt" || fail 'E2E 提示词未包含可复用 QA 准备交接给 Dev 的规则'

# 18. 非连续/语义化 e2e_plan ID（E0 / E1 / REQ-VIEWER-E2E / E2）全链路编号交接回归（复现 PR #491 误拦）
id_rev="$fixture/reviews-plan-ids"
jq -n --arg sha "$MOCK_SHA" '[{number: 7, title:"Fixture", body:"Closes #42 编号交接回归", url:"https://example.invalid/pull/7",
  headRefName:"main", baseRefName:"main", headRefOid:$sha, mergeable:"MERGEABLE", updatedAt:"plan-ids-1"}]' > "$fixture/pr.json"
jq -n '{title:"语义化场景编号", body:"[REQ-VIEWER-E2E] 查看者独立 Guest 验收", labels:[], url:"https://example.invalid/issues/42"}' > "$fixture/issue.json"

# 18a: 重复 e2e_plan[].id 与含空白字符的非法 ID 均在 Review 宿主机门禁拦截
before_id_app="$(grep -Fxc -- 'set-state pr 7 approved' "$fixture/calls" || true)"
jq -n '{
  verdict:"approve", summary:"重复 ID", e2e_decision:"run_e2e", e2e_decision_reason:"测试",
  e2e_checks:["E0 预检", "E1 正常轮"],
  e2e_plan:[
    {id:"E1", scenario:"预检", capability_basis:"支持", entrypoint:"qa/run.py", preflight_hint:"preflight", preserve_first_run:true},
    {id:"E1", scenario:"正常轮", capability_basis:"支持", entrypoint:"qa/run.py", preflight_hint:"preflight", preserve_first_run:true}
  ],
  previous_blocker_dispositions:[], requires_human_decision:false, blocking_issues:[], non_blocking_notes:[], requirements_coverage:[]
}' > "$fixture/verdict.json"
E2E_EVIDENCE_BRANCH="qa/test18-none" REVIEWS_ROOT="$id_rev" run_loop review
assert_calls "$before_id_app" 'set-state pr 7 approved'

jq '.e2e_plan[1].id = "REQ VIEWER"' "$fixture/verdict.json" > "$fixture/verdict-tmp.json"
mv "$fixture/verdict-tmp.json" "$fixture/verdict.json"
E2E_EVIDENCE_BRANCH="qa/test18-none" REVIEWS_ROOT="$id_rev" run_loop review
assert_calls "$before_id_app" 'set-state pr 7 approved'

# 18b: 合法的 E0 / E1 / REQ-VIEWER-E2E / E2 通过 Review，评审评论不再叠加冲突的 E1..E4 前缀
jq -n '{
  verdict:"approve", summary:"四项语义化编号通过评审", e2e_decision:"run_e2e", e2e_decision_reason:"执行四项验收",
  e2e_checks:["E0 双账号预检", "E1 编辑正常轮", "REQ-VIEWER-E2E 查看者只读与 403", "E2 清理故障轮"],
  e2e_plan:[
    {id:"E0", scenario:"双账号预检", capability_basis:"支持双账号", entrypoint:"qa/run.py --preflight", preflight_hint:"preflight", preserve_first_run:true},
    {id:"E1", scenario:"编辑正常轮", capability_basis:"支持编辑", entrypoint:"qa/run.py", preflight_hint:"preflight", preserve_first_run:true},
    {id:"REQ-VIEWER-E2E", scenario:"查看者只读与 403", capability_basis:"QA 夹具 VIEWER", entrypoint:"qa/run.py", preflight_hint:"preflight", preserve_first_run:true},
    {id:"E2", scenario:"清理故障轮", capability_basis:"支持故障注入", entrypoint:"qa/run.py --fault", preflight_hint:"preflight", preserve_first_run:true}
  ],
  previous_blocker_dispositions:[], requires_human_decision:false, blocking_issues:[], non_blocking_notes:[],
  requirements_coverage:[{
    id:"REQ-VIEWER-E2E", requirement:"查看者只读与写入 403", status:"partial",
    requires_real_e2e:true, disposition:"scheduled_e2e", e2e_plan_ids:["REQ-VIEWER-E2E"], waiver_ref:"",
    evidence:"已纳入 REQ-VIEWER-E2E 验收计划"
  }]
}' > "$fixture/verdict.json"
E2E_EVIDENCE_BRANCH="qa/test18-none" REVIEWS_ROOT="$id_rev" run_loop review
assert_calls "$((before_id_app + 1))" 'set-state pr 7 approved'
! grep -Fq -- '- E4 REQ-VIEWER-E2E' "$fixture/review-comment" || fail '评审评论不应再给 e2e_plan 场景叠加合成 E4 前缀'
! grep -Fq -- '- E1 E0' "$fixture/review-comment" || fail '评审评论不应再给 E0 场景叠加合成 E1 前缀'

# 18c: E2E schema 动态约束 enum；漏报 REQ-VIEWER-E2E 精确报 REQ-VIEWER-E2E（非 E4）；四项齐全通过 E2E + Final-Gate
before_id_blk="$(grep -Fxc -- 'set-state pr 7 blocked' "$fixture/calls" || true)"
jq -n '{
  verdict:"pass", summary:"漏报查看者场景", environment:"zapto", failure_stage:"", reproducible_in_dev_sandbox:true,
  scenarios:[
    {id:"E0", name:"预检", status:"passed", details:"预检通过", evidence_paths:["runs/E1/attempt-1/report.log"]},
    {id:"E1", name:"正常轮", status:"passed", details:"正常轮通过", evidence_paths:["runs/E1/attempt-1/report.log"]},
    {id:"E2", name:"故障轮", status:"passed", details:"故障轮通过", evidence_paths:["runs/E1/attempt-1/report.log"]}
  ],
  evidence_paths:["runs/E1/attempt-1/report.log"], failure_details:[], remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$fixture/e2e-plan-ids-miss" run_loop e2e
assert_calls "$((before_id_blk + 1))" 'set-state pr 7 blocked'
jq -e '.properties.scenarios.items.properties.id.enum == ["E0","E1","REQ-VIEWER-E2E","E2",""]' "$fixture/e2e-plan-ids-miss/pr-7/schema.json" >/dev/null \
  || fail 'E2E schema.json 未按权威 e2e_plan ID 生成动态 enum 约束'
! grep -Fq -- '- E4 REQ-VIEWER-E2E' "$fixture/last-prompt" || fail 'E2E 提示词不应再出现合成 E4 前缀'
grep -Fq 'REQ-VIEWER-E2E 缺少唯一的通过记录' "$fixture/e2e-plan-ids-miss/pr-7/e2e-comment.md" || fail '漏报查看者场景时未按真实 ID REQ-VIEWER-E2E 报错'

before_id_pass="$(grep -Fxc -- 'set-state pr 7 e2e-passed' "$fixture/calls" || true)"
jq -n '{
  verdict:"pass", summary:"四项语义化编号全部实测通过", environment:"zapto", failure_stage:"", reproducible_in_dev_sandbox:true,
  scenarios:[
    {id:"E0", name:"预检", status:"passed", details:"预检通过", evidence_paths:["runs/E1/attempt-1/report.log"]},
    {id:"E1", name:"正常轮", status:"passed", details:"正常轮通过", evidence_paths:["runs/E1/attempt-1/report.log"]},
    {id:"REQ-VIEWER-E2E", name:"查看者", status:"passed", details:"查看者只读且 403", evidence_paths:["runs/E1/attempt-1/report.log"]},
    {id:"E2", name:"故障轮", status:"passed", details:"故障轮通过", evidence_paths:["runs/E1/attempt-1/report.log"]}
  ],
  evidence_paths:["runs/E1/attempt-1/report.log"], failure_details:[], remaining_risks:[]
}' > "$fixture/result.json"
E2E_ROOT="$fixture/e2e-plan-ids-ok" PUBLISH_EVIDENCE=1 run_loop e2e
assert_calls "$((before_id_pass + 1))" 'set-state pr 7 e2e-passed'

before_id_ready="$(grep -Fxc -- 'set-state pr 7 ready-to-merge' "$fixture/calls" || true)"
AUTO_MERGE=0 FINAL_ROOT="$fixture/final-plan-ids-ok" run_loop final-gate
assert_calls "$((before_id_ready + 1))" 'set-state pr 7 ready-to-merge'

# 18d: 宿主机防漂移基线同时锁定 e2e_checks 与 e2e_plan（Issue 未变更时复审试图改写计划编号会被完整恢复）
jq -n '{
  verdict:"approve", summary:"企图篡改基线计划", e2e_decision:"run_e2e", e2e_decision_reason:"漂移",
  e2e_checks:["漂移项"],
  e2e_plan:[{id:"DRIFT-1", scenario:"漂移场景", capability_basis:"支持", entrypoint:"qa/drift.py", preflight_hint:"preflight", preserve_first_run:false}],
  previous_blocker_dispositions:[], requires_human_decision:false, blocking_issues:[], non_blocking_notes:[], requirements_coverage:[]
}' > "$fixture/verdict.json"
set_pr_body 'Closes #42 编号交接回归 R2 漂移'
E2E_EVIDENCE_BRANCH="qa/test18-none" REVIEWS_ROOT="$id_rev" run_loop review
grep -Fq '防漂移保护' "$fixture/review-comment" || fail '未触发防漂移保护提示'
jq -eRs -L "$fixture/workflow" 'include "workflow-e2e"; review_metadata | [.e2e_plan[].id] == ["E0","E1","REQ-VIEWER-E2E","E2"]' < "$fixture/review-comment" >/dev/null \
  || fail '防漂移保护未同步恢复 e2e_plan 权威编号'
rm -f "$fixture/issue.json"

printf 'workflow convergence tests passed\n'
