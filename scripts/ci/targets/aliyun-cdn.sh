#!/bin/bash

# X Certbot - 同步目标: 阿里云 CDN / DCDN（证书部署）
#
# 用途: 把「数字证书管理服务(CAS)」里的证书部署到 CDN（或 DCDN 全站加速）的 HTTPS 加速域名。
#       本脚本同时服务两个目标 id:
#         aliyun.cdn  -> product=cdn  -> SetCdnDomainSSLCertificate  (cdn.aliyuncs.com, 2018-05-10)
#         aliyun.dcdn -> product=dcdn -> SetDcdnDomainSSLCertificate (dcdn.aliyuncs.com, 2018-01-15)
#       两者参数形状一致，所以共用一份实现，避免复制粘贴走样。
#
# 官方接口（已核对官方文档 / 官方 SDK 源码）:
#   CDN : https://help.aliyun.com/zh/cdn/developer-reference/api-cdn-2018-05-10-setcdndomainsslcertificate
#   DCDN: https://help.aliyun.com/zh/dcdn/developer-reference/api-dcdn-2018-01-15-setdcdomainsslcertificate
#   SDK : aliyun-openapi-python-sdk / aliyunsdkdcdn / request/v20180115/SetDcdnDomainSSLCertificateRequest.py
#   请求参数: DomainName(必填) / CertType(cas|upload) / CertId(CertType=cas 时必填)
#             SSLProtocol(on|off, 必填) / CertName(可选) / CertRegion(cas 时生效) / SSLPub / SSLPri
#   RAM 权限: cdn:SetCdnDomainSSLCertificate / dcdn:SetDcdnDomainSSLCertificate
#
# 幂等:
#   这是一个「设置型」接口，参数是 CAS 的证书 ID（CertType=cas），不会创建新的证书对象；
#   用同一个 CertId 重复调用结果完全一致，因此每天重复跑是安全的。
#   真正可能产生垃圾资源的是上传动作，那一步在 aliyun-cas.sh 里做了指纹级幂等。
#
# 前置: 需要 aliyun.cas 目标先行执行并把 ALIYUN_CAS_CERT_ID 传出来（见 sync-cert.sh）。
#
# 输入环境变量:
#   TARGET               目标 id（aliyun.cdn / aliyun.dcdn）
#   CERT_DOMAIN / TARGET_CONFIG / TARGET_OUTPUT_FILE
#   ALIYUN_CAS_CERT_ID   aliyun-cas.sh 产出的证书 ID（必需）
#   ALIYUN_CAS_CERT_NAME 可选，用于 CertName
#   ALIYUN_CERT_REGION   可选，CAS 证书地域（cn-hangzhou / ap-southeast-1），默认 cn-hangzhou
#   ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT  阿里云证书同步凭据
#       未配置时自动回退到 ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS（DNS 那一对）。
#   NODE_BIN / DRY_RUN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/console_compat.sh
source "$SCRIPT_DIR/../lib/console_compat.sh"

TARGET="${TARGET:?缺少 TARGET}"
TARGET_CONFIG="${TARGET_CONFIG:?缺少 TARGET_CONFIG}"
TARGET_OUTPUT_FILE="${TARGET_OUTPUT_FILE:-}"
DRY_RUN="${DRY_RUN:-false}"
ALIYUN_CERT_REGION="${ALIYUN_CERT_REGION:-}"

case "$TARGET" in
    aliyun.cdn)  PRODUCT="cdn";  PRODUCT_UPPER="CDN";  ACTION="SetCdnDomainSSLCertificate";  API_VERSION="2018-05-10"; RAM_ACTION="cdn:SetCdnDomainSSLCertificate" ;;
    aliyun.dcdn) PRODUCT="dcdn"; PRODUCT_UPPER="DCDN"; ACTION="SetDcdnDomainSSLCertificate"; API_VERSION="2018-01-15"; RAM_ACTION="dcdn:SetDcdnDomainSSLCertificate" ;;
    *) print_error "未知目标: $TARGET（只支持 aliyun.cdn / aliyun.dcdn）"; exit 1 ;;
esac

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || { print_error "找不到 node"; exit 1; }
ALIYUN_API="$SCRIPT_DIR/../lib/aliyun-api.cjs"

record_output() {
    [ -n "$TARGET_OUTPUT_FILE" ] || return 0
    printf '%s=%s\n' "$1" "$2" >> "$TARGET_OUTPUT_FILE"
}

print_deploy "同步目标: 阿里云 ${PRODUCT_UPPER}（证书 $CERT_DOMAIN）"

# 不用 mapfile: 本仓库脚本要能在 macOS 自带的 bash 3.2 下直接跑，方便本机演练
DOMAINS=()
while IFS= read -r _d; do
    if [ -n "$_d" ]; then DOMAINS+=("$_d"); fi
done < <("$NODE_BIN" -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  (cfg.domains || []).forEach((d) => process.stdout.write(d + "\n"));
' "$TARGET_CONFIG")

if [ "${#DOMAINS[@]}" -eq 0 ]; then
    print_warning "没有配置要部署的 ${PRODUCT_UPPER} 域名，跳过"
    exit 0
fi

if [ -z "${ALIYUN_CAS_CERT_ID:-}" ]; then
    print_error "缺少 ALIYUN_CAS_CERT_ID：${PRODUCT_UPPER} 部署依赖 aliyun.cas 目标先完成上传。"
    print_error "请在 deploy/domains.yml 里同时启用 sync.aliyun.cas 和 sync.aliyun.${PRODUCT}。"
    exit 1
fi
print_key_value "CAS 证书 ID" "$ALIYUN_CAS_CERT_ID"

if [ -z "$ALIYUN_CERT_REGION" ]; then
    ALIYUN_CERT_REGION="$("$NODE_BIN" -e '
      const fs = require("fs");
      const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write(String(cfg.cert_region || "cn-hangzhou"));
    ' "$TARGET_CONFIG")"
fi
print_key_value "证书地域" "$ALIYUN_CERT_REGION"

FAILED=0
DONE_LIST=""
for domain in "${DOMAINS[@]}"; do
    print_subheader "${PRODUCT_UPPER} 域名: $domain"

    ARGS=(
        --product "$PRODUCT"
        --version "$API_VERSION"
        --action "$ACTION"
        --param DomainName="$domain"
        --param CertType=cas
        --param CertId="$ALIYUN_CAS_CERT_ID"
        --param SSLProtocol=on
        --param CertRegion="$ALIYUN_CERT_REGION"
    )
    if [ -n "${ALIYUN_CAS_CERT_NAME:-}" ]; then
        ARGS+=(--param CertName="$ALIYUN_CAS_CERT_NAME")
    fi

    if [ "$DRY_RUN" = "true" ]; then
        print_warning "DRY-RUN: 跳过 ${ACTION}"
        "$NODE_BIN" "$ALIYUN_API" "${ARGS[@]}" --dry-run >/dev/null
        DONE_LIST="${DONE_LIST}${domain}(dry-run) "
        continue
    fi

    # stderr 里只有阿里云返回的 Code/Message，不含私钥；stdout 丢弃
    api_err=""
    if api_err="$("$NODE_BIN" "$ALIYUN_API" "${ARGS[@]}" 2>&1 >/dev/null)"; then
        print_success "已部署: $domain（CertType=cas, CertId=$ALIYUN_CAS_CERT_ID）"
        DONE_LIST="${DONE_LIST}${domain} "
    else
        print_error "部署失败: $domain"
        if [ -n "$api_err" ]; then print_error "$api_err"; fi
        print_info "需要 RAM 权限: $RAM_ACTION"
        FAILED=1
    fi
done

record_output "ALIYUN_${PRODUCT_UPPER}_DOMAINS" "${DONE_LIST% }"

if [ "$FAILED" -ne 0 ]; then
    print_error "${PRODUCT_UPPER} 同步有失败项"
    exit 1
fi
print_success "${PRODUCT_UPPER} 同步完成"
