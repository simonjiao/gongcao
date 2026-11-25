#!/usr/bin/bash
set -euo pipefail

# 首次使用请运行 ./agy-issue-loop.sh login，登录保存在 ${GONGCAO_HOME:-~/.gongcao}/agy。
SCRIPT_DIR="$(cd -- "$([[ "${BASH_SOURCE[0]}" == */* ]] && printf '%s' "${BASH_SOURCE[0]%/*}" || printf '.')" && pwd)"
exec /usr/bin/bash "${SCRIPT_DIR}/lib/issue-loop.sh" agy "$@"
