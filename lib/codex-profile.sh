# 评审 / E2E / 终审循环共享的隔离 Codex 配置目录初始化助手。
# 独立于开发循环目录（~/.gongcao/codex）与个人默认目录（~/.codex）。

init_codex_review_profile() {
  local script_name="$1"
  local action="${2:-run}"
  local profile_dir="${CODEX_REVIEW_HOME:-${GONGCAO_HOME}/codex-review}"
  local env_bin
  env_bin="$(resolve_bin env)"

  case "$action" in
    login)
      (umask 077 && "$MKDIR_BIN" -p "$profile_dir")
      profile_dir="$(cd -- "$profile_dir" && pwd -P)"
      exec "$env_bin" "CODEX_HOME=$profile_dir" "$CODEX_BIN" login
      ;;
    run)
      if [[ ! -d "$profile_dir" ]]; then
        printf '错误：请先运行 %s/%s login 初始化评审专用 Codex 目录 %s（避免使用个人默认 ~/.codex）。\n' \
          "$SCRIPT_DIR" "$script_name" "$profile_dir" >&2
        exit 1
      fi
      ;;
    *)
      printf '用法：%s [login]\n' "$script_name" >&2
      exit 2
      ;;
  esac

  CODEX_PROFILE_DIR="$(cd -- "$profile_dir" && pwd -P)"
  CODEX_CMD=("$env_bin" "CODEX_HOME=$CODEX_PROFILE_DIR" "$CODEX_BIN")
}
