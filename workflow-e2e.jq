def nonblank: type == "string" and test("\\S");

def valid_e2e_checks:
  type == "array"
  and all(nonblank and (test("[\\r\\n]") | not))
  and length == (unique | length);

def review_metadata:
  "<!-- codex-review-meta:" as $prefix
  | split("\n") | map(rtrimstr("\r") | select(startswith($prefix))) | last
  | if . == null then error("缺少评审元数据")
    elif endswith(" -->") | not then error("评审元数据未闭合")
    else ltrimstr($prefix) | rtrimstr(" -->") | fromjson
    end;

def approved_e2e_checks($sha; $previous_sha):
  if type != "object" then error("评审元数据格式无效")
  elif .head_sha != $sha and ($previous_sha == "" or .head_sha != $previous_sha) then
    error("评审提交与当前提交不匹配")
  elif .verdict != "approve" then error("缺少通过评审的结论")
  elif has("e2e_checks") | not then [] # 已有签核生成时尚无必验场景字段
  elif .e2e_checks | valid_e2e_checks then .e2e_checks | sort
  else error("评审必验场景格式无效")
  end;

def numbered_e2e_checks:
  to_entries | map({id: ("E" + ((.key + 1) | tostring)), description: .value});

def resolve_artifact_path($root; $files):
  if nonblank then
    ($root | rtrimstr("/")) as $base
    | (if $base != "" and startswith($base + "/") then ltrimstr($base + "/")
       elif test("/artifacts-[0-9]{8}-[0-9]{6}/") then sub("^.*/artifacts-[0-9]{8}-[0-9]{6}/"; "")
       else . end)
    | sub("^(\\./)+"; "")
    | if ($files | index(.)) != null then .
      elif startswith("artifacts/") and ($files | index(ltrimstr("artifacts/"))) != null then ltrimstr("artifacts/")
      else null
      end
  else
    null
  end;

def missing_e2e_checks($checks; $files; $root):
  (.scenarios | if type == "array" then map(objects) else [] end) as $scenarios
  | (.evidence_paths | if type == "array" then map(resolve_artifact_path($root; $files) | select(. != null)) else [] end) as $reported
  | $checks | numbered_e2e_checks
  | map(.id as $id
      | [$scenarios[] | select(.id == $id)] as $matches
      | select(($matches | length) != 1 or (
          $matches[0] | (
            .status == "passed" and (.details | nonblank)
            and (.evidence_paths | type == "array" and length > 0 and all(
              resolve_artifact_path($root; $files) as $norm
              | $norm != null and ($reported | index($norm)) != null
            ))
          ) | not
        ))
      | .id);

def missing_e2e_checks($checks; $files):
  missing_e2e_checks($checks; $files; "");
