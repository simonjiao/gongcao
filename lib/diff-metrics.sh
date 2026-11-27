# 宿主机确定性 Diff 分类统计、Issue 测试估算解析与规模复核信号助手。
# 供 lib/issue-loop.sh（提交前拦截与 PR 呈现）与 codex-review-loop.sh（评审客观算账）共用。

classify_diff_path() {
  local p="$1"
  local low="${p,,}"
  local base="${low##*/}"

  # 文档优先判定（避免 qa/README.md 误计入 QA 驱动代码）
  case "$low" in
    docs/*|*/docs/*|*.md|readme|readme.*|changelog|changelog.*|license|license.*)
      printf 'docs'
      return
      ;;
  esac

  # 自动化单元测试 / 模块测试（含 qa/ 下的测试文件，如 qa/test-browser-runtime.cjs、qa/test_environment.py）
  if [[ "$low" == */src/test/* || "$low" == src/test/* \
     || "$low" == tests/* || "$low" == */tests/* \
     || "$low" == test/* || "$low" == */test/* \
     || "$low" == __tests__/* || "$low" == */__tests__/* \
     || "$base" == *.test.* || "$base" == *.spec.* \
     || "$base" == *_test.* || "$base" == test_*.* || "$base" == test-*.* \
     || "$p" == *Test.java || "$p" == *Tests.java || "$p" == *IT.java ]]; then
    printf 'test'
    return
  fi

  # QA / E2E 维护入口与驱动脚本
  case "$low" in
    qa/*|*/qa/*|e2e/*|*/e2e/*|playwright/*|*/playwright/*)
      printf 'qa'
      return
      ;;
  esac

  printf 'prod'
}

is_qa_infra_path() {
  local p="$1"
  local low="${p,,}"
  local base="${low##*/}"
  case "$low" in
    qa/browser-runtime*|qa/env.*|qa/dind/*|qa/ci/*|qa/lib/*|qa/helpers/*|qa/common/*|e2e/helpers/*|e2e/runtime/*)
      return 0
      ;;
  esac
  if [[ "$low" == qa/* && "$base" == *runtime* && "$base" != test* ]]; then
    return 0
  fi
  return 1
}

# 从 Issue 正文中提取「必要测试 / 测试约」行数估算上限（提取不到返回 0）
parse_issue_test_budget() {
  local text="${1:-}"
  local match="" nums="" upper="0" n=""
  if [[ -z "$text" ]]; then
    printf '0'
    return
  fi

  match="$(printf '%s' "$text" | grep -oiE '(必要测试|内部测试|单元测试|测试代码|测试规模|test budget|tests?)[^0-9\n]{0,12}[0-9]+([[:space:]]*[-–—~至到][[:space:]]*[0-9]+)?[[:space:]]*(行|lines?)' | head -n 1 || true)"
  if [[ -z "$match" ]]; then
    printf '0'
    return
  fi

  nums="$(printf '%s' "$match" | grep -oE '[0-9]+' || true)"
  while IFS= read -r n; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    if (( n > upper )); then
      upper="$n"
    fi
  done <<<"$nums"
  printf '%s' "$upper"
}

# 计算相对 base_ref 的分类增删行数统计（输出紧凑 JSON）
# 参数：git_bin jq_bin repo_or_wt base_ref [head_ref_or_WORKTREE]
compute_diff_metrics() {
  local git_bin="$1"
  local jq_bin="$2"
  local wt="$3"
  local base_ref="$4"
  local target="${5:-WORKTREE}"

  local compare_base="$base_ref"
  local mb=""
  if [[ "$target" == "WORKTREE" ]]; then
    mb="$("$git_bin" -C "$wt" merge-base "$base_ref" HEAD 2>/dev/null || true)"
  else
    mb="$("$git_bin" -C "$wt" merge-base "$base_ref" "$target" 2>/dev/null || true)"
  fi
  [[ -n "$mb" ]] && compare_base="$mb"

  local prod_add=0 prod_del=0 prod_files=0
  local test_add=0 test_del=0 test_files=0
  local qa_add=0 qa_del=0 qa_files=0
  local docs_add=0 docs_del=0 docs_files=0
  local -a qa_infra_list=()

  local numstat_out=""
  if [[ "$target" == "WORKTREE" ]]; then
    numstat_out="$("$git_bin" -C "$wt" diff --numstat "$compare_base" 2>/dev/null || true)"
  else
    numstat_out="$("$git_bin" -C "$wt" diff --numstat "${compare_base}..${target}" 2>/dev/null || true)"
  fi

  local add="" del="" fpath="" cat_name=""
  while IFS=$'\t' read -r add del fpath; do
    [[ -z "$fpath" ]] && continue
    # 处理 rename 形式 "a/{old => new}/b" 或 "old => new"，取目标路径
    if [[ "$fpath" == *" => "* ]]; then
      if [[ "$fpath" =~ ^(.*)\{[^}]*[[:space:]]=\>[[:space:]]([^}]*)\}(.*)$ ]]; then
        fpath="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
      else
        fpath="${fpath##* => }"
      fi
    fi
    [[ "$add" =~ ^[0-9]+$ ]] || add=0
    [[ "$del" =~ ^[0-9]+$ ]] || del=0
    cat_name="$(classify_diff_path "$fpath")"
    case "$cat_name" in
      prod) prod_add=$((prod_add + add)); prod_del=$((prod_del + del)); prod_files=$((prod_files + 1)) ;;
      test) test_add=$((test_add + add)); test_del=$((test_del + del)); test_files=$((test_files + 1)) ;;
      qa)
        qa_add=$((qa_add + add)); qa_del=$((qa_del + del)); qa_files=$((qa_files + 1))
        if is_qa_infra_path "$fpath"; then
          qa_infra_list+=("$fpath")
        fi
        ;;
      docs) docs_add=$((docs_add + add)); docs_del=$((docs_del + del)); docs_files=$((docs_files + 1)) ;;
    esac
  done <<<"$numstat_out"

  # 工作树模式下把未跟踪的新建文件也纳入统计（Dev 沙箱内不执行 git add）
  if [[ "$target" == "WORKTREE" ]]; then
    local untracked_out="" ufile="" ulines=0
    untracked_out="$("$git_bin" -C "$wt" ls-files --others --exclude-standard 2>/dev/null || true)"
    while IFS= read -r ufile; do
      [[ -z "$ufile" ]] && continue
      ulines=0
      if [[ -f "${wt}/${ufile}" ]]; then
        ulines="$(wc -l < "${wt}/${ufile}" 2>/dev/null | tr -d '[:space:]' || printf '0')"
        [[ "$ulines" =~ ^[0-9]+$ ]] || ulines=0
      fi
      cat_name="$(classify_diff_path "$ufile")"
      case "$cat_name" in
        prod) prod_add=$((prod_add + ulines)); prod_files=$((prod_files + 1)) ;;
        test) test_add=$((test_add + ulines)); test_files=$((test_files + 1)) ;;
        qa)
          qa_add=$((qa_add + ulines)); qa_files=$((qa_files + 1))
          if is_qa_infra_path "$ufile"; then
            qa_infra_list+=("$ufile")
          fi
          ;;
        docs) docs_add=$((docs_add + ulines)); docs_files=$((docs_files + 1)) ;;
      esac
    done <<<"$untracked_out"
  fi

  local qa_infra_json='[]'
  if (( ${#qa_infra_list[@]} > 0 )); then
    qa_infra_json="$(printf '%s\n' "${qa_infra_list[@]}" | "$jq_bin" -Rsc 'split("\n") | map(select(length > 0)) | unique')"
  fi

  local test_or_qa_changed=false
  if (( test_files > 0 || qa_files > 0 )); then
    test_or_qa_changed=true
  fi

  "$jq_bin" -nc \
    --argjson prod_add "$prod_add" --argjson prod_del "$prod_del" --argjson prod_files "$prod_files" \
    --argjson test_add "$test_add" --argjson test_del "$test_del" --argjson test_files "$test_files" \
    --argjson qa_add "$qa_add" --argjson qa_del "$qa_del" --argjson qa_files "$qa_files" \
    --argjson docs_add "$docs_add" --argjson docs_del "$docs_del" --argjson docs_files "$docs_files" \
    --argjson qa_infra_files "$qa_infra_json" \
    --argjson test_or_qa_changed "$test_or_qa_changed" \
    '{
      prod: {added: $prod_add, deleted: $prod_del, files: $prod_files},
      test: {added: $test_add, deleted: $test_del, files: $test_files},
      qa:   {added: $qa_add,   deleted: $qa_del,   files: $qa_files},
      docs: {added: $docs_add, deleted: $docs_del, files: $docs_files},
      qa_infra_files: $qa_infra_files,
      test_or_qa_changed: $test_or_qa_changed
    }'
}

# 根据宿主机实测规模与 Issue 测试估算，输出需要说明理由/人工或评审复核的信号列表（无触发时输出空）
evaluate_size_review_triggers() {
  local jq_bin="$1"
  local metrics_json="$2"
  local test_budget="${3:-0}"
  local qa_limit="${QA_SIZE_REVIEW_THRESHOLD:-150}"
  local default_test_min="${TEST_SIZE_REVIEW_MIN:-80}"

  [[ "$test_budget" =~ ^[0-9]+$ ]] || test_budget=0
  [[ "$qa_limit" =~ ^[0-9]+$ ]] || qa_limit=150
  [[ "$default_test_min" =~ ^[0-9]+$ ]] || default_test_min=80

  "$jq_bin" -r \
    --argjson budget "$test_budget" \
    --argjson qa_limit "$qa_limit" \
    --argjson test_min "$default_test_min" \
    '
    [
      (if $budget > 0 and (.test.added > $budget) then
        "内部测试新增 +" + (.test.added | tostring) + " 行，超出 Issue 估算上限 " + ($budget | tostring) + " 行"
      elif $budget == 0 and (.test.added > $test_min) and ((.test.added * 2) > (.prod.added * 3)) then
        "内部测试新增 +" + (.test.added | tostring) + " 行（产品代码 +" + (.prod.added | tostring) + " 行），超出默认复核比例阈值"
      else empty end),
      (if (.qa.added > $qa_limit) then
        "QA 维护入口/驱动新增 +" + (.qa.added | tostring) + " 行，超出默认 " + ($qa_limit | tostring) + " 行复核阈值"
      else empty end),
      (if ((.qa_infra_files // []) | length) > 0 then
        "改动涉及通用 QA 运行时/基础设施文件（" + ((.qa_infra_files | map("`" + . + "`")) | join("、")) + "），须说明为何必须在本功能 PR 内修改而非独立拆分"
      else empty end)
    ] | join("\n")
    ' <<<"$metrics_json" 2>/dev/null || true
}

# 将分类统计渲染为 Markdown 表格与复核提示
render_diff_metrics_markdown() {
  local jq_bin="$1"
  local metrics_json="$2"
  local test_budget="${3:-0}"
  local triggers=""
  triggers="$(evaluate_size_review_triggers "$jq_bin" "$metrics_json" "$test_budget")"

  local budget_note=""
  if [[ "$test_budget" =~ ^[0-9]+$ ]] && (( test_budget > 0 )); then
    budget_note="（Issue 测试估算上限：${test_budget} 行）"
  fi

  local table=""
  table="$("$jq_bin" -r --arg bnote "$budget_note" '
    "| 类别 | 文件数 | 新增行 | 删除行 |\n"
    + "| --- | ---: | ---: | ---: |\n"
    + "| 生产代码 | " + (.prod.files|tostring) + " | +" + (.prod.added|tostring) + " | -" + (.prod.deleted|tostring) + " |\n"
    + "| 内部测试" + $bnote + " | " + (.test.files|tostring) + " | +" + (.test.added|tostring) + " | -" + (.test.deleted|tostring) + " |\n"
    + "| QA 驱动与入口 | " + (.qa.files|tostring) + " | +" + (.qa.added|tostring) + " | -" + (.qa.deleted|tostring) + " |\n"
    + "| 文档 | " + (.docs.files|tostring) + " | +" + (.docs.added|tostring) + " | -" + (.docs.deleted|tostring) + " |"
  ' <<<"$metrics_json")"

  printf '%s\n' "$table"
  if [[ -n "$triggers" ]]; then
    printf '\n**规模/范围复核信号**：\n'
    while IFS= read -r _t; do
      [[ -z "$_t" ]] && continue
      printf -- '- %s\n' "$_t"
    done <<<"$triggers"
  fi
}
