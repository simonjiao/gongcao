#!/usr/bin/bash

release_marker='<!-- gongcao-release -->'

is_release_issue() {
  local line
  while IFS= read -r line; do
    [[ "${line%$'\r'}" != "$release_marker" ]] || return 0
  done <<<"$1"
  return 1
}

release_issue_from_pr() {
  local line marker_pattern='^<!-- gongcao-release-issue:([1-9][0-9]*) -->$'
  while IFS= read -r line; do
    if [[ "${line%$'\r'}" =~ $marker_pattern ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return
    fi
  done <<<"$1"
}

release_pr_reference() {
  printf 'Refs #%s\n<!-- gongcao-release-issue:%s -->' "$1" "$1"
}

queue_release_handoff() {
  local issue="$1" pr="$2" sha="$3" base="$4" dir tmp
  [[ "$issue" =~ ^[1-9][0-9]*$ && "$pr" =~ ^[1-9][0-9]*$ && "$sha" =~ ^[0-9a-f]{40}$ && -n "$base" ]] || return 1
  [[ "$DRY_RUN" != "1" ]] || return 0
  dir="$STATE_ROOT/releases/issue-$issue/$sha"
  "$MKDIR_BIN" -p "$dir" || return 1
  [[ ! -f "$dir/handoff.json" ]] || return 0

  tmp="$(mktemp "$dir/handoff.XXXXXX")" || return 1
  "$JQ_BIN" -n --argjson issue "$issue" --argjson pr "$pr" --arg sha "$sha" --arg base "$base" \
    '{issue: $issue, pr: $pr, sha: $sha, base: $base}' > "$tmp" || return 1
  mv -- "$tmp" "$dir/handoff.json"
}
