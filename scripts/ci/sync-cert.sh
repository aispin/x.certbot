#!/bin/bash

# X Certbot - 单域名证书同步调度器
#
# 用途: 读取 config.cjs 生成的执行计划，对一个域名依次执行它启用的所有同步目标，
#       逐个隔离失败、记录结果，最后给出「哪个域名 / 哪个平台出问题」的明细。
#
# 为什么每天都要全量同步（而不是「只在续期时同步」）:
#   证书续期和云平台同步是两个可能分别失败的动作。如果只在「本次真的续期了」时才同步，
#   那么「证书已换新 + 云平台同步失败」这种状态会在下次运行时因为没有续期而被跳过，
#   变成永久性不一致（CloudBase 尤其危险：它存的是 CertId 指针，不会自动跟着换）。
#   所以这里的策略是: 每次都把当前证书同步一遍，靠各目标自身的幂等性把重复调用变成便宜的空操作。
#
# 用法:
#   scripts/ci/sync-cert.sh --plan plan.json --domain example.com \
#       --cert-dir /tmp/run/certs/example.com --run-dir /tmp/run [--only cloudbase.domain] [--dry-run]
#
# 输出:
#   $RUN_DIR/targets/<目标id>.env   每个目标产出的 key=value（供后续目标使用）
#   $RUN_DIR/results.jsonl          每个「域名 x 目标」的结果记录（workflow 用它生成 Step Summary）
#
# 退出码: 0 全部成功；1 有任一目标失败（明细在 results.jsonl 与日志里）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/console_compat.sh
source "$SCRIPT_DIR/lib/console_compat.sh"

PLAN=""
DOMAIN=""
CERT_DIR=""
RUN_DIR=""
ONLY=""
DRY_RUN="${DRY_RUN:-false}"

while [ $# -gt 0 ]; do
    case "$1" in
        --plan)     PLAN="$2"; shift 2 ;;
        --domain)   DOMAIN="$2"; shift 2 ;;
        --cert-dir) CERT_DIR="$2"; shift 2 ;;
        --run-dir)  RUN_DIR="$2"; shift 2 ;;
        --only)     ONLY="$2"; shift 2 ;;
        --dry-run)  DRY_RUN="true"; shift ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) print_error "未知参数: $1"; exit 1 ;;
    esac
done

[ -n "$PLAN" ] || { print_error "缺少 --plan"; exit 1; }
[ -n "$DOMAIN" ] || { print_error "缺少 --domain"; exit 1; }
[ -n "$CERT_DIR" ] || { print_error "缺少 --cert-dir"; exit 1; }
[ -n "$RUN_DIR" ] || { print_error "缺少 --run-dir"; exit 1; }

REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || { print_error "找不到 node"; exit 1; }

CERT_FULLCHAIN="$CERT_DIR/fullchain.pem"
CERT_PRIVKEY="$CERT_DIR/privkey.pem"
[ -s "$CERT_FULLCHAIN" ] || { print_error "找不到证书: $CERT_FULLCHAIN"; exit 1; }
[ -s "$CERT_PRIVKEY" ]   || { print_error "找不到私钥: $CERT_PRIVKEY"; exit 1; }

TARGETS_DIR="$RUN_DIR/targets"
RESULTS_FILE="$RUN_DIR/results.jsonl"
mkdir -p "$TARGETS_DIR"

# ---------------------------------------------------------------------------
# 凭据解析 / 前置校验
#
# 命名约定（全部配置在 GitHub Environment `PROD` 下）:
#   ID 走 Variables（${{ vars.* }}），Key 走 Secrets（${{ secrets.* }}）
#   阿里云 DNS          : ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS
#   阿里云 CAS/CDN/DCDN : ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT
#                         -> 未配置时【默认复用】DNS 那一对（交付物原有的回退逻辑）
#   腾讯云 CloudBase    : CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY
#
# 注意: 阿里云证书同步（CAS 上传 / CDN / DCDN 部署）需要的权限超出 DNS 权限。
# 用 DNS 这对密钥调用时若报 Forbidden / NoPermission，请另建 RAM 用户并配置 *_CERT 那一对。
# 具体权限清单见 docs/07-github-actions-cert-sync.md 第 4.3 节。
# ---------------------------------------------------------------------------
resolve_aliyun_cert_credentials() {
    if [ -n "${ALIYUN_SECRET_ID_CERT:-}" ] && [ -n "${ALIYUN_SECRET_KEY_CERT:-}" ]; then
        print_info "阿里云证书同步使用专用凭据: ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT"
        return 0
    fi
    if [ -n "${ALIYUN_SECRET_ID_DNS:-}" ] && [ -n "${ALIYUN_SECRET_KEY_DNS:-}" ]; then
        print_info "阿里云证书同步复用 DNS 凭据: ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS"
        print_info "（CAS/CDN/DCDN 报权限错误时，请另建 RAM 用户并配置 ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT）"
        return 0
    fi
    print_error "缺少阿里云凭据: 请配置 ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS（或证书同步专用的 ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT）"
    return 1
}

resolve_tencent_credentials() {
    if [ -z "${CLOUDBASE_SECRET_ID:-}" ] || [ -z "${CLOUDBASE_SECRET_KEY:-}" ]; then
        print_error "缺少腾讯云凭据: 请配置 CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY"
        return 1
    fi
    print_info "腾讯云 CloudBase 使用凭据: CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY"
}

# ---------------------------------------------------------------------------
# 从计划里取出该域名的目标列表（每行一个 JSON）
# ---------------------------------------------------------------------------
TARGET_LIST="$RUN_DIR/${DOMAIN}.targets.jsonl"
"$NODE_BIN" -e '
  const fs = require("fs");
  const plan = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const domain = process.argv[2];
  const only = (process.argv[3] || "").split(",").map((s) => s.trim()).filter(Boolean);
  const entry = plan.domains.find((d) => d.name === domain);
  if (!entry) { process.stderr.write("计划里没有域名: " + domain + "\n"); process.exit(1); }
  let targets = entry.targets || [];
  if (only.length) targets = targets.filter((t) => only.includes(t.id));
  for (const t of targets) process.stdout.write(JSON.stringify(t) + "\n");
' "$PLAN" "$DOMAIN" "$ONLY" > "$TARGET_LIST"

TARGET_COUNT="$(wc -l < "$TARGET_LIST" | tr -d ' ')"
print_subheader "同步 [$DOMAIN]：$TARGET_COUNT 个目标"

if [ "$TARGET_COUNT" -eq 0 ]; then
    print_info "没有启用任何同步目标，跳过"
    exit 0
fi

FAILED=0
while IFS= read -r target_json; do
    [ -n "$target_json" ] || continue

    TARGET_ID="$("$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const o=JSON.parse(s);process.stdout.write(o.id)})' <<<"$target_json")"
    TARGET_LABEL="$("$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const o=JSON.parse(s);process.stdout.write(o.label||o.id)})' <<<"$target_json")"
    TARGET_SCRIPT_REL="$("$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const o=JSON.parse(s);process.stdout.write(o.script)})' <<<"$target_json")"

    TARGET_SCRIPT="$REPO_ROOT/$TARGET_SCRIPT_REL"
    TARGET_CONFIG_FILE="$TARGETS_DIR/${TARGET_ID}.config.cjson"
    TARGET_OUTPUT_FILE="$TARGETS_DIR/${TARGET_ID}.env"
    : > "$TARGET_OUTPUT_FILE"
    "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{const o=JSON.parse(s);process.stdout.write(JSON.stringify(o.config||{}))})' <<<"$target_json" > "$TARGET_CONFIG_FILE"

    print_header "目标: $TARGET_ID（$TARGET_LABEL）"

    if [ ! -f "$TARGET_SCRIPT" ]; then
        print_error "目标脚本不存在: $TARGET_SCRIPT"
        printf '{"domain":"%s","target":"%s","label":"%s","status":"error","message":"目标脚本不存在"}\n' \
            "$DOMAIN" "$TARGET_ID" "$TARGET_LABEL" >> "$RESULTS_FILE"
        FAILED=1
        continue
    fi

    # 把「已经跑过的目标」产出的变量注入环境（例如 aliyun.cas 产出的 ALIYUN_CAS_CERT_ID）
    for produced in "$TARGETS_DIR"/*.env; do
        [ -f "$produced" ] || continue
        [ "$produced" = "$TARGET_OUTPUT_FILE" ] && continue
        # 只接受 KEY=VALUE 形式，且 KEY 必须是合法变量名，
        # 这样即使产出文件被写脏也不会执行到意外内容。
        while IFS= read -r line; do
            case "$line" in
                ''|'#'*) continue ;;
            esac
            case "$line" in
                *=*)
                    produced_name="${line%%=*}"
                    produced_value="${line#*=}"
                    case "$produced_name" in
                        ''|[0-9]*|*[!A-Za-z0-9_]*) continue ;;
                    esac
                    export "$produced_name=$produced_value"
                    ;;
            esac
        done < "$produced"
    done

    target_rc=0
    (
        case "$TARGET_ID" in
            aliyun.*) resolve_aliyun_cert_credentials ;;
            cloudbase.*) resolve_tencent_credentials ;;
        esac
        export CERT_DOMAIN="$DOMAIN"
        export CERT_FULLCHAIN CERT_PRIVKEY
        export TARGET="$TARGET_ID"
        export TARGET_CONFIG="$TARGET_CONFIG_FILE"
        export TARGET_OUTPUT_FILE
        export DRY_RUN
        export NODE_BIN
        export STATE_DIR="${STATE_DIR:-}"
        export ALIYUN_CERT_REGION="${ALIYUN_CERT_REGION:-}"
        bash "$TARGET_SCRIPT"
    ) || target_rc=$?

    if [ "$target_rc" -eq 0 ]; then
        print_success "$TARGET_ID 成功"
        printf '{"domain":"%s","target":"%s","label":"%s","status":"success"}\n' \
            "$DOMAIN" "$TARGET_ID" "$TARGET_LABEL" >> "$RESULTS_FILE"
    else
        print_error "$TARGET_ID 失败（退出码 $target_rc）"
        printf '{"domain":"%s","target":"%s","label":"%s","status":"failed","exit_code":%s}\n' \
            "$DOMAIN" "$TARGET_ID" "$TARGET_LABEL" "$target_rc" >> "$RESULTS_FILE"
        FAILED=1
    fi
done < "$TARGET_LIST"

if [ "$FAILED" -ne 0 ]; then
    print_error "域名 [$DOMAIN] 有同步目标失败，见上面各目标的日志"
    exit 1
fi

print_success "域名 [$DOMAIN] 全部同步目标完成"
