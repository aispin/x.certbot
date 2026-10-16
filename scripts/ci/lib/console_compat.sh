#!/bin/bash

# CI 控制台兼容层
# 用途: 让 scripts/ci/ 下的脚本复用项目既有的 scripts/console_utils.sh（彩色输出 + emoji），
#       在找不到它时（例如本机直接跑、或在没有挂载容器路径的环境里）提供同名兜底函数，
#       保证任何环境下脚本都不会因为 source 失败而中断。
# 用法: source "$(dirname "${BASH_SOURCE[0]}")/lib/console_compat.sh"
# 环境变量:
#   CONSOLE_UTILS - 显式指定 console_utils.sh 的绝对路径
#   NO_COLOR / NO_EMOJI / DEBUG - 透传给 console_utils.sh

# console_utils.sh 内部会直接展开 $NO_COLOR / $NO_EMOJI / $DEBUG / $TERM，
# 而我们的脚本一律 set -u，所以先给它们补默认值，避免 unbound variable。
: "${NO_COLOR:=false}"
: "${NO_EMOJI:=false}"
: "${DEBUG:=false}"
: "${TERM:=dumb}"
export NO_COLOR NO_EMOJI DEBUG TERM

# 依次尝试候选路径，命中第一个存在的就 source
_console_utils_candidates=(
    "${CONSOLE_UTILS:-}"
    "/usr/local/bin/scripts/console_utils.sh"
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/console_utils.sh"
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/scripts/console_utils.sh"
)

CONSOLE_UTILS_LOADED=""
for _candidate in "${_console_utils_candidates[@]}"; do
    if [ -n "$_candidate" ] && [ -f "$_candidate" ]; then
        # shellcheck source=/dev/null
        source "$_candidate"
        CONSOLE_UTILS_LOADED="$_candidate"
        break
    fi
done
unset _candidate _console_utils_candidates

# 兜底: console_utils.sh 不可用时，提供纯文本版本的同名函数。
# 只覆盖本目录脚本会用到的那几个，保持行为（写 stdout）一致。
if [ -z "$CONSOLE_UTILS_LOADED" ]; then
    print_header()     { printf '\n%s\n%s\n%s\n\n' "=====================================================================" "  $*" "====================================================================="; }
    print_subheader()  { printf '\n%s\n%s\n' "$*" "---------------------------------------------------------------------"; }
    print_separator()  { printf '\n%s\n\n' "---------------------------------------------------------------------"; }
    print_success()    { printf '[OK] %s\n' "$*"; }
    print_error()      { printf '[ERROR] %s\n' "$*" >&2; }
    print_warning()    { printf '[WARN] %s\n' "$*"; }
    print_info()       { printf '[INFO] %s\n' "$*"; }
    print_debug()      { [ "$DEBUG" = "true" ] && printf '[DEBUG] %s\n' "$*"; return 0; }
    print_cert()       { printf '[CERT] %s\n' "$*"; }
    print_dns()        { printf '[DNS] %s\n' "$*"; }
    print_http()       { printf '[HTTP] %s\n' "$*"; }
    print_hook()       { printf '[HOOK] %s\n' "$*"; }
    print_cron()       { printf '[CRON] %s\n' "$*"; }
    print_deploy()     { printf '[DEPLOY] %s\n' "$*"; }
    print_env()        { printf '[ENV] %s\n' "$*"; }
    print_cloud_provider() { printf '[CLOUD:%s] %s\n' "$1" "$2"; }
    print_step()       { printf '[步骤 %s] %s\n' "$1" "$2"; }
    print_key_value()  { printf '%-20s : %s\n' "$1" "$2"; }
fi

export CONSOLE_UTILS_LOADED
