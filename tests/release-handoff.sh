#!/usr/bin/bash
set -euo pipefail

repo_dir="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/workflow/lib" "$fixture/repo/qa/ci" "$fixture/repo/docs/acceptance/release" "$fixture/repo/scripts"
cp "$repo_dir"/{cleanup-merged,release-loop}.sh "$fixture/workflow/"
cp "$repo_dir/lib/release-handoff.sh" "$fixture/workflow/lib/"
source "$repo_dir/lib/release-handoff.sh"

export STATE_ROOT="$fixture/state" REPO_DIR="$fixture/repo" REPO=example/fixture GONGCAO_HOME="$fixture/home" TEST_DIR="$fixture"
cat > "$fixture/workflow/gh-state.sh" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
case "$*" in
  'list-prs merged '*)
    cat "$TEST_DIR/merged.json"
    ;;
  'set-state '*)
    printf '%s\n' "$*" >> "$TEST_DIR/calls"
    ;;
  'get-issue 66')
    printf '%s\n' '{"state":"OPEN"}'
    ;;
  'comment issue '*)
    cat >> "$TEST_DIR/comments"
    ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$fixture/workflow/gh-state.sh"
cat > "$REPO_DIR/qa/ci/run.sh" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
[[ "$1" == "--sha" && "$3" == "--output" && "$(git rev-parse HEAD)" == "$2" ]]
mkdir "$4"
jq -n --arg sha "$2" '{candidate_sha:$sha,version:"0.7.12",tag:"v0.7.12",build_source:"local-container",packages:{archive:"digest"},tests:{spi:2},guide:{sha256:"digest"}}' > "$4/candidate.json"
printf '%s\n' build >> "$TEST_DIR/calls"
EOF
cat > "$REPO_DIR/scripts/release-readiness.py" <<'EOF'
from hashlib import sha256
from pathlib import Path
import json
import sys

mode, report_path, ci_path = sys.argv[1:]
raw = (Path(ci_path) / "candidate.json").read_bytes()
report = json.loads(Path(report_path).read_text())
assert mode == "verify-ci"
assert report["candidate_sha"] == json.loads(raw)["candidate_sha"]
assert report["manifest_sha256"] == sha256(raw).hexdigest()
assert report["decision"] == "NO-GO"
EOF
printf '%s\n' '{"decision":"NO-GO","guide":{"status":"NOT_RUN"},"scenarios":{"V01":{"status":"BLOCKED"}}}' \
  > "$REPO_DIR/docs/acceptance/release/report-template.json"
git -C "$REPO_DIR" init -q -b main
git -C "$REPO_DIR" add -A
git -C "$REPO_DIR" -c user.name=Test -c user.email=test@example.invalid commit -qm first
pr_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
git -C "$REPO_DIR" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm merge
merge_sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
jq -n --arg head "$pr_sha" --arg merge "$merge_sha" --arg body "$(release_pr_reference 66)" '
  [{number:7, body:$body, headRefName:"chore/release", baseRefName:"main",
    headRefOid:$head, mergeCommit:{oid:$merge}, labels:[{name:"agy:done"}]}]
  + [{number:8, body:"Closes #67", headRefName:"fix/test", labels:[{name:"agy:in-review"}]}]
' > "$fixture/merged.json"

bash "$fixture/workflow/cleanup-merged.sh" --once
dir="$STATE_ROOT/releases/issue-66/$merge_sha"
jq -e --arg sha "$merge_sha" '.issue == 66 and .pr == 7 and .sha == $sha' "$dir/handoff.json" >/dev/null
grep -Fxq 'set-state issue 66 release-pending' "$fixture/calls"
grep -Fxq 'set-state issue 67 done' "$fixture/calls"
if grep -Fxq 'set-state issue 66 done' "$fixture/calls"; then
  printf '%s\n' 'FAIL 发布 Issue 被封版合入收口' >&2
  exit 1
fi

bash "$fixture/workflow/release-loop.sh" --once
jq -e --arg sha "$merge_sha" '
  .candidate_sha == $sha and .decision == "NO-GO" and .guide.status == "NOT_RUN" and .scenarios.V01.status == "BLOCKED"
' "$dir/acceptance.json" >/dev/null
grep -Fq "$merge_sha" "$fixture/comments"
bash "$fixture/workflow/cleanup-merged.sh" --once
bash "$fixture/workflow/release-loop.sh" --once
[[ "$(grep -Fxc build "$fixture/calls")" == "1" ]]

cat > "$fixture/acceptance" <<'EOF'
#!/usr/bin/bash
set -euo pipefail
[[ -f "$1" && -f "$2/candidate.json" && -f "$3/handoff.json" ]]
printf '%s\n' acceptance >> "$TEST_DIR/calls"
EOF
chmod +x "$fixture/acceptance"
RELEASE_ACCEPTANCE_RUNNER="$fixture/acceptance" bash "$fixture/workflow/release-loop.sh" --once
RELEASE_ACCEPTANCE_RUNNER="$fixture/acceptance" bash "$fixture/workflow/release-loop.sh" --once
[[ "$(grep -Fxc acceptance "$fixture/calls")" == "1" ]]
printf '%s\n' 'release handoff tests passed'
