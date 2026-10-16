#!/bin/bash

# X Certbot - stub 演练用的假 acme.sh
#
# 用途: 只用于 scripts/ci/selftest/run.sh 的端到端演练 —— 不联网、不用真凭据，
#       但完整复现 acme.sh 对 issue-cert.sh 有影响的行为:
#         --issue        创建 $ACME_HOME/<域名>[_ecc]/ 下的证书文件与 .conf
#         --renew        已有 .conf 时: 没到窗口就打印 Skip 并【退出码 2】（这是真实的 acme.sh 行为，
#                        也是最容易被 CI 脚本误判为失败的地方），带 --force 时退出 0
#         --install-cert 把证书复制到 --key-file/--fullchain-file/--cert-file/--ca-file
#
# 环境变量:
#   STUB_ACME_GOLDEN    预置证书目录（含 fullchain.pem / privkey.pem / cert.pem / chain.pem）
#   STUB_ACME_CALL_LOG  调用记录文件
#   STUB_ACME_RENEW_RC  强制 --renew 的退出码（不设则按上面的规则）

set -euo pipefail

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
GOLDEN="${STUB_ACME_GOLDEN:?stub acme.sh 需要 STUB_ACME_GOLDEN}"
LOG="${STUB_ACME_CALL_LOG:-/dev/null}"

printf '%s\n' "acme-stub $*" >> "$LOG"

ACTION=""
DOMAIN=""
ECC=""
FORCE="false"
KEY_FILE=""
FULLCHAIN_FILE=""
CERT_FILE=""
CA_FILE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --issue)        ACTION="issue"; shift ;;
        --renew)        ACTION="renew"; shift ;;
        --install-cert) ACTION="install-cert"; shift ;;
        --ecc)          ECC="_ecc"; shift ;;
        --force)        FORCE="true"; shift ;;
        # acme.sh 约定: 第一个 -d 是主域名（决定证书目录），后面的 -d 是 SAN/泛域名
        -d)             [ -z "$DOMAIN" ] && DOMAIN="$2"; shift 2 ;;
        --key-file)     KEY_FILE="$2"; shift 2 ;;
        --fullchain-file) FULLCHAIN_FILE="$2"; shift 2 ;;
        --cert-file)    CERT_FILE="$2"; shift 2 ;;
        --ca-file)      CA_FILE="$2"; shift 2 ;;
        --server|--dns|--keylength|--dnssleep|--accountemail)
                        shift 2 ;;
        --*)            shift ;;
        *)              shift ;;
    esac
done

[ -n "$DOMAIN" ] || { echo "acme-stub: 缺少 -d <domain>" >&2; exit 1; }
DOMAIN_PATH="$ACME_HOME/${DOMAIN}${ECC}"
DOMAIN_CONF="$DOMAIN_PATH/${DOMAIN}${ECC}.conf"

case "$ACTION" in
    issue)
        [ -f "$DOMAIN_CONF" ] && { echo "acme-stub: 已存在证书配置，拒绝重复签发" >&2; exit 1; }
        mkdir -p "$DOMAIN_PATH"
        cp "$GOLDEN/fullchain.pem" "$DOMAIN_PATH/fullchain.cer"
        cp "$GOLDEN/fullchain.pem" "$DOMAIN_PATH/${DOMAIN}${ECC}.cer"
        cp "$GOLDEN/privkey.pem"   "$DOMAIN_PATH/${DOMAIN}${ECC}.key"
        cp "$GOLDEN/chain.pem"     "$DOMAIN_PATH/ca.cer"
        {
            echo "Le_Domain='${DOMAIN}'"
            echo "Le_RealCertPath=''"
            echo "# acme-stub: 模拟 acme.sh 的域名配置文件"
        } > "$DOMAIN_CONF"
        echo "acme-stub: 签发成功 $DOMAIN"
        ;;
    renew)
        [ -f "$DOMAIN_CONF" ] || { echo "acme-stub: 没有域名配置，无法续期" >&2; exit 1; }
        if [ -n "${STUB_ACME_RENEW_RC:-}" ]; then
            echo "acme-stub: 按 STUB_ACME_RENEW_RC=${STUB_ACME_RENEW_RC} 退出"
            exit "$STUB_ACME_RENEW_RC"
        fi
        # 先刷新一次证书内容，方便演练「续期后同步」的路径
        cp "$GOLDEN/fullchain.pem" "$DOMAIN_PATH/fullchain.cer"
        cp "$GOLDEN/fullchain.pem" "$DOMAIN_PATH/${DOMAIN}${ECC}.cer"
        cp "$GOLDEN/privkey.pem"   "$DOMAIN_PATH/${DOMAIN}${ECC}.key"
        cp "$GOLDEN/chain.pem"     "$DOMAIN_PATH/ca.cer"
        if [ "$FORCE" = "true" ]; then
            echo "acme-stub: 强制续期完成 $DOMAIN"
            exit 0
        fi
        echo "Skip, Next renewal time is: acme-stub-skip"
        # 真实的 acme.sh 在「还没到续期窗口」时就是这个退出码
        exit 2
        ;;
    install-cert)
        [ -f "$DOMAIN_PATH/fullchain.cer" ] || { echo "acme-stub: 找不到证书" >&2; exit 1; }
        [ -n "$FULLCHAIN_FILE" ] && cp "$DOMAIN_PATH/fullchain.cer" "$FULLCHAIN_FILE"
        [ -n "$KEY_FILE" ]       && cp "$DOMAIN_PATH/${DOMAIN}${ECC}.key" "$KEY_FILE"
        [ -n "$CERT_FILE" ]      && cp "$DOMAIN_PATH/${DOMAIN}${ECC}.cer" "$CERT_FILE"
        [ -n "$CA_FILE" ]        && cp "$DOMAIN_PATH/ca.cer" "$CA_FILE"
        echo "acme-stub: 证书已复制到稳定路径"
        ;;
    *)
        echo "acme-stub: 未实现的动作（$*）" >&2
        exit 1
        ;;
esac
