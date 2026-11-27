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

printf 'workflow convergence tests passed\n'
