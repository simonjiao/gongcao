#!/usr/bin/bash
set -euo pipefail

# 处理已合入的发布任务，复用仓库的容器 CI、报告模板及验收入口。
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="${REPO:?需要 REPO=owner/repo}"
GONGCAO_HOME="${GONGCAO_HOME:-$HOME/.gongcao}"
repo_slug="${REPO//\//__}"
repo_slug="${repo_slug//[^a-zA-Z0-9._-]/_}"
REPO_DIR="${REPO_DIR:-${REPOS_ROOT:-$GONGCAO_HOME/repos}/$repo_slug}"
STATE_ROOT="${STATE_ROOT:-${STATE_BASE:-$GONGCAO_HOME/state}/$repo_slug}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
DRY_RUN="${DRY_RUN:-0}"
LABEL_PREFIX="${LABEL_PREFIX:-agy:}"
RELEASE_ACCEPTANCE_RUNNER="${RELEASE_ACCEPTANCE_RUNNER:-}"

gh_state() {
  GONGCAO_HOME="$GONGCAO_HOME" REPO="$REPO" REPO_DIR="$REPO_DIR" LABEL_PREFIX="$LABEL_PREFIX" DRY_RUN="$DRY_RUN" \
    "$SCRIPT_DIR/gh-state.sh" "$@"
}

report_release_progress() {
  printf '%s\n' "$2" | gh_state comment issue "$1" - '<!-- gongcao-release-progress -->'
}

prepare_release() (
  local handoff="$1" dir="${1%/*}" sha base issue pr source ci report report_tmp digest message
  flock -n 9 || return 0
  if [[ -f "$dir/announced" ]] \
    && [[ -z "$RELEASE_ACCEPTANCE_RUNNER" || -f "$dir/acceptance-run.log" || -f "$dir/blocked.txt" ]]; then
    return 0
  fi
  sha="$(jq -er '.sha | select(test("^[0-9a-f]{40}$"))' "$handoff")" || return 1
  issue="$(jq -er '.issue | select(type == "number" and . > 0)' "$handoff")" || return 1
  pr="$(jq -er '.pr | select(type == "number" and . > 0)' "$handoff")" || return 1
  base="$(jq -er '.base | strings' "$handoff")" || return 1
  git check-ref-format --branch "$base" >/dev/null || return 1
  [[ "$dir" == "$STATE_ROOT/releases/issue-$issue/$sha" ]] || return 1
  source="$dir/source"
  ci="$dir/container-ci"
  report="$dir/acceptance.json"

  if [[ ! -e "$source/.git" ]]; then
    (
      flock -x 8 || exit 1
      if ! git -C "$REPO_DIR" cat-file -e "${sha}^{commit}" 2>/dev/null; then
        git -C "$REPO_DIR" fetch origin "refs/heads/$base" || exit 1
      fi
      git -C "$REPO_DIR" worktree add --detach "$source" "$sha"
    ) 8>"$STATE_ROOT/repo-git.lock" || return 1
  fi
  [[ "$(git -C "$source" rev-parse HEAD)" == "$sha" ]] || return 1

  if [[ -s "$dir/blocked.txt" ]]; then
    :
  elif [[ ! -f "$source/qa/ci/run.sh" || ! -f "$source/docs/acceptance/release/report-template.json" \
    || ! -f "$source/scripts/release-readiness.py" ]]; then
    printf '%s\n' '合入版本缺少容器 CI、发布报告模板或候选校验入口。' > "$dir/blocked.txt"
  elif [[ ! -s "$ci/candidate.json" ]]; then
    # 保留中断的原始记录，发布 CI 入口要求输出目录尚未创建。
    if [[ -e "$ci" ]]; then
      mv -- "$ci" "$(mktemp -d "$dir/ci-interrupted.XXXXXX")/container-ci" || return 1
    fi
    printf 'Issue #%s：开始构建合入提交 %s\n' "$issue" "$sha"
    if ! (cd "$source" && bash qa/ci/run.sh --sha "$sha" --output "$ci") >>"$dir/build.log" 2>&1; then
      printf '%s\n' '容器 CI 失败，保留原始记录待复核。' > "$dir/blocked.txt"
    fi
  fi

  if [[ -s "$dir/blocked.txt" ]]; then
    report_release_progress "$issue" "封版 PR #$pr 的发布候选准备受阻。$(<"$dir/blocked.txt")" || return 1
    gh_state set-state issue "$issue" blocked || return 1
    : > "$dir/announced"
    return
  fi

  if [[ ! -s "$report" ]]; then
    digest="$(sha256sum "$ci/candidate.json")" || return 1
    report_tmp="$dir/acceptance.json.tmp"
    jq --arg sha "$sha" --arg digest "${digest%% *}" --slurpfile candidate "$ci/candidate.json" '
      $candidate[0] as $c
      | if $c.candidate_sha == $sha and $c.build_source == "local-container" then
          .candidate_sha = $c.candidate_sha | .version = $c.version | .tag = $c.tag
          | .packages = $c.packages | .ci_tests = $c.tests | .manifest_sha256 = $digest
          | .guide = (.guide + $c.guide) | .decision = "NO-GO"
        else error("候选清单与合入提交不匹配") end
    ' "$source/docs/acceptance/release/report-template.json" > "$report_tmp" || return 1
    python3 -B "$source/scripts/release-readiness.py" verify-ci "$report_tmp" "$ci" || return 1
    mv -- "$report_tmp" "$report" || return 1
  fi

  if [[ -n "$RELEASE_ACCEPTANCE_RUNNER" && ! -f "$dir/acceptance-run.log" ]]; then
    if (cd "$source" && "$RELEASE_ACCEPTANCE_RUNNER" "$report" "$ci" "$dir") >"$dir/acceptance-run.log" 2>&1; then
      printf 'Issue #%s：发布验收入口已结束，结果见真实验收报告。\n' "$issue"
    else
      printf 'Issue #%s：验收入口报错，已保存诊断与候选。\n' "$issue" >&2
    fi
  fi
  printf -v message '封版 PR #%s 已接续本地容器 CI，候选提交为 `%s`。已保存原包和发布报告，正式发布依据最终原包的场景证据及所有者 GO。' "$pr" "$sha"
  report_release_progress "$issue" "$message" || return 1
  : > "$dir/announced"
) 9>"${1%/*}/release.lock"

run_pass() {
  local handoff
  [[ "$DRY_RUN" != "1" ]] || return 0
  for handoff in "$STATE_ROOT"/releases/issue-*/*/handoff.json; do
    [[ -f "$handoff" ]] || continue
    prepare_release "$handoff" || printf '警告：发布交接未完成，下次轮询重试：%s\n' "$handoff" >&2
  done
}

if [[ "${1:-}" == "--once" ]]; then
  run_pass
else
  while true; do
    run_pass
    sleep "$POLL_INTERVAL"
  done
fi
