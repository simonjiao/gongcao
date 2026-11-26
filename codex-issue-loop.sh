#!/usr/bin/bash
set -euo pipefail

# 首次使用请运行 ./codex-issue-loop.sh login，或将已有 auth.json 放进 Gongcao 的 codex 目录。
# 单独启动开发循环：REPO=owner/repo ./codex-issue-loop.sh
# 可设置 CODEX_MODEL、CODEX_REASONING_EFFORT 和 CODEX_DEV_TIMEOUT（默认 gpt-6.2-sol、xhigh、40m）。
SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
exec /usr/bin/bash "${SCRIPT_DIR}/lib/issue-loop.sh" codex "$@"
