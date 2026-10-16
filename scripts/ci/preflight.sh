#!/bin/bash

# X Certbot - CI 凭据预检
#
# 用途: 在真正跑签发/同步之前，先根据执行计划判断「这次需要哪些配置」，
#       缺哪个就一次性列清楚。避免跑到一半才因为某个域名/平台缺密钥而失败。
#
# 凭据命名约定（全部配置在 GitHub Environment `PROD` 下）:
#   ID 走 Variables（${{ vars.* }}），Key 走 Secrets（${{ secrets.* }}）
#   阿里云 DNS          : ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS
#   阿里云 CAS/CDN/DCDN : ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT -> 回退 ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS
#   腾讯云 CloudBase    : CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY
#   腾讯云 DNSPod(DNS)  : 同样复用 CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY
#
# 安全: 只检查变量是否存在，从不打印变量的值。
#
# 用法: scripts/ci/preflight.sh --plan /tmp/cert-sync/plan.json
#
# 退出码: 0 凭据齐全；1 有缺失（会列出变量名与用途）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/console_compat.sh
source "$SCRIPT_DIR/lib/console_compat.sh"

PLAN=""
while [ $# -gt 0 ]; do
    case "$1" in
        --plan) PLAN="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) print_error "未知参数: $1"; exit 1 ;;
    esac
done
[ -n "$PLAN" ] || { print_error "缺少 --plan"; exit 1; }

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || { print_error "找不到 node"; exit 1; }

print_subheader "凭据预检"

MISSING=""
require_any() {
    # $1 = 用途说明, 其余 = 候选变量名（任意一个非空即可）
    local purpose="$1"; shift
    local names="$*"
    local name val
    for name in "$@"; do
        # 用 eval 间接取值: ${!name} 在老的 bash 上与 :- 组合不可靠
        eval "val=\${$name:-}"
        if [ -n "$val" ]; then
            print_success "$purpose: 使用 $name"
            return 0
        fi
    done
    print_error "$purpose: 缺少（需要其中之一: $names）"
    MISSING="${MISSING}${purpose} -> ${names}\n"
}

# 计划里出现过的 DNS 供应商 / 同步平台
PLAN_SUMMARY="$("$NODE_BIN" -e '
  const fs = require("fs");
  const plan = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const dns = new Set();
  const platforms = new Set();
  for (const d of plan.domains) {
    dns.add(d.dns_provider);
    for (const t of d.targets) platforms.add(t.platform);
  }
  process.stdout.write([...dns].join(" ") + "\n" + [...platforms].join(" ") + "\n");
' "$PLAN")"

DNS_PROVIDERS_USED="$(printf '%s' "$PLAN_SUMMARY" | sed -n '1p')"
PLATFORMS_USED="$(printf '%s' "$PLAN_SUMMARY" | sed -n '2p')"

print_key_value "DNS 供应商" "${DNS_PROVIDERS_USED:-<无>}"
print_key_value "同步平台" "${PLATFORMS_USED:-<无>}"

for provider in $DNS_PROVIDERS_USED; do
    case "$provider" in
        aliyun)
            require_any "阿里云 DNS-01 凭据" \
                ALIYUN_SECRET_ID_DNS
            require_any "阿里云 DNS-01 密钥" \
                ALIYUN_SECRET_KEY_DNS
            ;;
        tencentcloud)
            # 腾讯云只配了一对 CAM 密钥，DNSPod 的 DNS-01 复用同一对。
            require_any "腾讯云 DNSPod DNS-01 凭据" \
                CLOUDBASE_SECRET_ID
            require_any "腾讯云 DNSPod DNS-01 密钥" \
                CLOUDBASE_SECRET_KEY
            ;;
        *)
            print_warning "未知 DNS 供应商: $provider"
            ;;
    esac
done

for platform in $PLATFORMS_USED; do
    case "$platform" in
        aliyun)
            # 默认复用 DNS 那一对；只想给证书同步最小权限时再单独配置 *_CERT。
            require_any "阿里云证书同步凭据(CAS/CDN/DCDN)" \
                ALIYUN_SECRET_ID_CERT ALIYUN_SECRET_ID_DNS
            require_any "阿里云证书同步密钥(CAS/CDN/DCDN)" \
                ALIYUN_SECRET_KEY_CERT ALIYUN_SECRET_KEY_DNS
            ;;
        cloudbase)
            require_any "腾讯云 CloudBase 凭据" \
                CLOUDBASE_SECRET_ID
            require_any "腾讯云 CloudBase 密钥" \
                CLOUDBASE_SECRET_KEY
            ;;
        *)
            print_warning "未知同步平台: $platform"
            ;;
    esac
done

if [ -n "$MISSING" ]; then
    print_error "凭据预检未通过，缺少以下配置（请在 GitHub Environment PROD 的 Variables/Secrets 里补上，不要写进任何文件）:"
    printf '%b' "$MISSING"
    exit 1
fi

print_success "凭据预检通过"
