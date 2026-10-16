#!/bin/bash

# X Certbot - CI 单域名证书签发/续期
#
# 用途: 在 GitHub Actions（或任何有 bash+node+git 的机器）上，用 acme.sh 为「一个域名条目」
#       签发或续期证书，并 --install-cert 复制到稳定路径，供后续同步目标使用。
#
# 为什么用 acme.sh 而不是本仓库容器里的 certbot（docs/cert-automation/README.md §1 的结论）:
#   - acme.sh 官方内置并持续维护阿里云 DNS 插件 dns_ali，纯 curl+openssl，零额外依赖；
#   - 官方没有腾讯云 deploy hook，CloudBase/腾讯云 SSL 那一步本来就要自己写，用 certbot 并不会更省事；
#   - 一个条目 = 一个域名（可含泛域名），配置驱动比容器里的单个 DOMAIN_ARG 更适合多域名集中管理。
#   本仓库原有的 Docker + certbot 用法完全不受影响，两套可以并存。
#
# 关键事实（都已核实，写死在这里避免后人踩坑）:
#   1. acme.sh 默认 CA 是 ZeroSSL，必须显式 --server letsencrypt 才能拿到 Let's Encrypt 证书；
#   2. 证书目录 <ACME_HOME>/<主域名>（ECC 时是 <主域名>_ecc），所有后续命令都要带 --ecc；
#   3. ~/.acme.sh 内部结构官方声明「仅供内部使用，可能变化」，所以对外只暴露 --install-cert
#      复制出来的稳定路径；
#   4. acme.sh 用非零退出码表示「跳过续期」（还没到续期窗口），不能简单当成失败。
#
# 幂等:
#   - 已有域名配置 -> 走 --renew（acme.sh 自己判断是否需要续期，没到期就跳过）
#   - 没有域名配置 -> 走 --issue 首签
#   - --install-cert 每次都会把当前证书复制到稳定路径，所以「上次同步失败、这次补同步」也能工作
#
# 用法:
#   scripts/ci/issue-cert.sh --domain example.com --dns-provider aliyun \
#       --email ops@example.com --wildcard --out-dir /tmp/certs/example.com
#
# 常用参数:
#   --domain <域名>            必填，punycode 形式（config.cjs 已转换）
#   --dns-provider <名称>      aliyun | tencentcloud，必填
#   --out-dir <目录>           必填，证书复制目标目录
#   --email <邮箱>             ACME 账户邮箱（首次注册用；可留空但会告警）
#   --wildcard                 追加 *.域名（泛域名只能走 DNS-01）
#   --key-length <长度>        2048 / 3072 / 4096 / ec-256 / ec-384 / ec-521（默认 2048）
#   --server <CA>              acme.sh --server 值（默认 letsencrypt）
#   --dns-wait <秒>            DNS 记录传播等待（默认 60）
#   --force                    强制续期（演练用；生产别开）
#   --dry-run                  只打印将要执行的命令，不真的调用
#
# 需要的环境变量（DNS 凭据，二选一）:
#   aliyun:       ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS
#                 （与 GitHub Environment `PROD` 里配置的名字一致）
#   tencentcloud: CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY
#                 （腾讯云只配了这一对，DNSPod 的 DNS-01 复用同一对）
#   本机手动运行时也接受 acme.sh 插件原生的 Ali_Key/Ali_Secret、
#   Tencent_SecretId/Tencent_SecretKey（它们不是 GitHub 配置项，只是插件变量名）。
#
# 其他环境变量:
#   ACME_HOME          默认 $HOME/.acme.sh
#   ACME_SH_REPO       默认 https://github.com/acmesh-official/acme.sh.git
#   ACME_SH_REF        git ref（分支/标签/commit），默认 master；生产建议钉一个 tag
#   ACME_BIN           显式指定 acme.sh 路径（不设则在 ACME_HOME 下找）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/console_compat.sh
source "$SCRIPT_DIR/lib/console_compat.sh"

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
DOMAIN=""
DNS_PROVIDER=""
OUT_DIR=""
# 邮箱不是机密，只从 deploy/domains.yml 的 defaults.email / domains[].email 读，
# 由 run-all.sh 通过 --email 传进来；这里不再读任何邮箱环境变量。
EMAIL=""
WILDCARD="false"
KEY_LENGTH="2048"
ACME_SERVER="letsencrypt"
DNS_WAIT="60"
FORCE="false"
DRY_RUN="false"
INSTALL_ONLY="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --domain)       DOMAIN="$2"; shift 2 ;;
        --dns-provider) DNS_PROVIDER="$2"; shift 2 ;;
        --out-dir)      OUT_DIR="$2"; shift 2 ;;
        --email)        EMAIL="$2"; shift 2 ;;
        --wildcard)     WILDCARD="true"; shift ;;
        --key-length)   KEY_LENGTH="$2"; shift 2 ;;
        --server)       ACME_SERVER="$2"; shift 2 ;;
        --dns-wait)     DNS_WAIT="$2"; shift 2 ;;
        --force)        FORCE="true"; shift ;;
        --install-only) INSTALL_ONLY="true"; shift ;;
        --dry-run)      DRY_RUN="true"; shift ;;
        -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
        *) print_error "未知参数: $1"; exit 1 ;;
    esac
done

[ -n "$DOMAIN" ] || { print_error "缺少 --domain"; exit 1; }
[ -n "$DNS_PROVIDER" ] || { print_error "缺少 --dns-provider"; exit 1; }
[ -n "$OUT_DIR" ] || { print_error "缺少 --out-dir"; exit 1; }

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
ACME_SH_REPO="${ACME_SH_REPO:-https://github.com/acmesh-official/acme.sh.git}"
ACME_SH_REF="${ACME_SH_REF:-master}"
ACME_BIN="${ACME_BIN:-$ACME_HOME/acme.sh}"

# 安全护栏: 下面会为了重建损坏的缓存而 rm -rf $ACME_HOME，
# 所以这里强制它必须是绝对路径、且在 $HOME 下、且不是 / 或 $HOME 本身。
case "$ACME_HOME" in
    "$HOME"/*) : ;;
    *) print_error "ACME_HOME 必须是 \$HOME 下的绝对路径，当前值: ${ACME_HOME:-<空>}"; exit 1 ;;
esac
[ "$ACME_HOME" != "$HOME" ] || { print_error "ACME_HOME 不能是 \$HOME 本身"; exit 1; }

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || { print_error "找不到 node"; exit 1; }

# ---------------------------------------------------------------------------
# DNS 凭据（只从环境变量读，任何文件里都不落明文）
# ---------------------------------------------------------------------------
export_aliyun_credentials() {
    # 优先用 acme.sh 插件原生变量（本机手动运行时可直接设），
    # 否则用 workflow 从 Environment PROD 注入的名字。
    local key="${Ali_Key:-${ALIYUN_SECRET_ID_DNS:-}}"
    local secret="${Ali_Secret:-${ALIYUN_SECRET_KEY_DNS:-}}"
    if [ -z "$key" ] || [ -z "$secret" ]; then
        print_error "缺少阿里云 DNS 凭据。请设置 ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS（本机也可直接用 Ali_Key/Ali_Secret）"
        exit 1
    fi
    # acme.sh dns_ali 插件认的就是这两个变量名（大小写敏感）
    export Ali_Key="$key"
    export Ali_Secret="$secret"
    print_dns "使用阿里云 DNS 插件 dns_ali（凭据已从环境变量注入）"
}

export_tencent_credentials() {
    # 腾讯云只有一对 CAM 密钥（CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY），DNSPod 复用。
    local id="${Tencent_SecretId:-${CLOUDBASE_SECRET_ID:-}}"
    local key="${Tencent_SecretKey:-${CLOUDBASE_SECRET_KEY:-}}"
    if [ -z "$id" ] || [ -z "$key" ]; then
        print_error "缺少腾讯云 DNS 凭据。请设置 CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY（本机也可直接用 Tencent_SecretId/Tencent_SecretKey）"
        exit 1
    fi
    # acme.sh dns_tencent 插件认的就是这两个变量名
    export Tencent_SecretId="$id"
    export Tencent_SecretKey="$key"
    print_dns "使用腾讯云 DNS 插件 dns_tencent（DNSPod，凭据已从环境变量注入）"
}

case "$DNS_PROVIDER" in
    aliyun)       DNS_PLUGIN="dns_ali";     export_aliyun_credentials ;;
    tencentcloud) DNS_PLUGIN="dns_tencent"; export_tencent_credentials ;;
    *) print_error "不支持的 dns-provider: $DNS_PROVIDER（只支持 aliyun / tencentcloud）"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# 安装 acme.sh（幂等）
# ---------------------------------------------------------------------------
ensure_acme() {
    if [ -x "$ACME_BIN" ]; then
        print_info "已存在 acme.sh: $ACME_BIN"
        return 0
    fi
    if [ -e "$ACME_HOME" ]; then
        print_warning "缓存目录存在但 acme.sh 不可执行，重建: $ACME_HOME"
        rm -rf "$ACME_HOME"
    fi
    mkdir -p "$(dirname "$ACME_HOME")"
    print_info "安装 acme.sh（repo=$ACME_SH_REPO ref=$ACME_SH_REF）"
    # 直接 clone 成 acme.sh 的布局，避免跑官方 install.sh 去装 cron（CI 里没有 crontab，
    # 而且续期由本 workflow 的 schedule 负责）。
    git clone --depth 1 --branch "$ACME_SH_REF" "$ACME_SH_REPO" "$ACME_HOME" >/dev/null 2>&1 \
        || git clone --depth 1 "$ACME_SH_REPO" "$ACME_HOME" >/dev/null 2>&1 \
        || { print_error "acme.sh 安装失败（$ACME_SH_REPO @ $ACME_SH_REF）"; exit 1; }
    [ -x "$ACME_BIN" ] || { print_error "安装后仍找不到 $ACME_BIN"; exit 1; }
    print_success "acme.sh 安装完成"
}

# ---------------------------------------------------------------------------
# 执行 acme.sh
# ---------------------------------------------------------------------------
ECC_FLAG=""
ECC_SUFFIX=""
case "$KEY_LENGTH" in
    ec-*) ECC_FLAG="--ecc"; ECC_SUFFIX="_ecc" ;;
esac

CERT_NAMES=("-d" "$DOMAIN")
if [ "$WILDCARD" = "true" ]; then
    CERT_NAMES+=("-d" "*.${DOMAIN}")
fi

run_acme() {
    if [ "$DRY_RUN" = "true" ]; then
        print_warning "DRY-RUN: $ACME_BIN $*"
        return 0
    fi
    "$ACME_BIN" "$@"
}

mkdir -p "$OUT_DIR"
chmod 750 "$OUT_DIR" 2>/dev/null || true

# acme.sh 的布局: $ACME_HOME/<域名>[_ecc]/<域名>[_ecc].conf
DOMAIN_PATH="$ACME_HOME/${DOMAIN}${ECC_SUFFIX}"
DOMAIN_CONF="$DOMAIN_PATH/${DOMAIN}${ECC_SUFFIX}.conf"

# ---------------------------------------------------------------------------
# 1. 签发 或 续期
# ---------------------------------------------------------------------------
if [ "$INSTALL_ONLY" = "true" ]; then
    print_subheader "install-only 模式：跳过 ACME 签发/续期，只用现有证书刷新稳定路径"
    [ -d "$DOMAIN_PATH" ] || {
        print_error "--install-only 需要本地已有 acme.sh 证书状态（$DOMAIN_PATH 不存在）。"
        print_error "缓存可能丢了；请先跑一次不带 --install-only 的完整流程。"
        exit 1
    }
elif [ -f "$DOMAIN_CONF" ]; then
    print_subheader "续期（已有域名配置，acme.sh 自行判断是否需要）"
    RENEW_ARGS=(--renew -d "$DOMAIN")
    [ -n "$ECC_FLAG" ] && RENEW_ARGS+=("$ECC_FLAG")
    [ "$FORCE" = "true" ] && RENEW_ARGS+=(--force)

    if [ "$DRY_RUN" = "true" ]; then
        run_acme "${RENEW_ARGS[@]}"
    else
        set +e
        renew_out="$("$ACME_BIN" "${RENEW_ARGS[@]}" 2>&1)"
        renew_rc=$?
        set -e
        printf '%s\n' "$renew_out"
        case "$renew_rc" in
            0) print_success "acme.sh 续期执行成功" ;;
            2) print_info "acme.sh 判定尚未到续期窗口（退出码 2 = 跳过），继续用现有证书同步" ;;
            *) print_error "acme.sh 续期失败（退出码 $renew_rc）"; exit 1 ;;
        esac
    fi
else
    print_subheader "首次签发"
    if [ -z "$EMAIL" ]; then
        print_warning "未提供邮箱，acme.sh 会跳过账户注册校验提示；请在 deploy/domains.yml 的 defaults.email 里填好邮箱"
    fi
    ISSUE_ARGS=(--issue --server "$ACME_SERVER" "${CERT_NAMES[@]}" --dns "$DNS_PLUGIN")
    [ -n "$ECC_FLAG" ] && ISSUE_ARGS+=("$ECC_FLAG")
    ISSUE_ARGS+=(--keylength "$KEY_LENGTH" --dnssleep "$DNS_WAIT")
    [ -n "$EMAIL" ] && ISSUE_ARGS+=(--accountemail "$EMAIL")

    set +e
    issue_out="$(run_acme "${ISSUE_ARGS[@]}" 2>&1)"
    issue_rc=$?
    set -e
    printf '%s\n' "$issue_out"
    if [ "$issue_rc" -ne 0 ]; then
        print_error "首次签发失败（退出码 $issue_rc）"
        exit 1
    fi
    print_success "首次签发成功"
fi

# ---------------------------------------------------------------------------
# 2. 复制到稳定路径（--install-cert）
#    官方明确警告不要直接用 ~/.acme.sh 里的文件，它的内部结构可能变。
# ---------------------------------------------------------------------------
print_subheader "复制证书到稳定路径"
FULLCHAIN="$OUT_DIR/fullchain.pem"
PRIVKEY="$OUT_DIR/privkey.pem"
CERT_FILE="$OUT_DIR/cert.pem"
CHAIN_FILE="$OUT_DIR/chain.pem"

if [ "$DRY_RUN" = "true" ]; then
    print_warning "DRY-RUN 结束：未真正调用 acme.sh，也没有证书产物"
    exit 0
fi

INSTALL_ARGS=(--install-cert -d "$DOMAIN")
[ -n "$ECC_FLAG" ] && INSTALL_ARGS+=("$ECC_FLAG")
INSTALL_ARGS+=(
    --key-file       "$PRIVKEY"
    --fullchain-file "$FULLCHAIN"
    --cert-file      "$CERT_FILE"
    --ca-file        "$CHAIN_FILE"
)
run_acme "${INSTALL_ARGS[@]}"

[ -s "$FULLCHAIN" ] || { print_error "复制后找不到 $FULLCHAIN"; exit 1; }
[ -s "$PRIVKEY" ]   || { print_error "复制后找不到 $PRIVKEY"; exit 1; }
chmod 600 "$PRIVKEY" 2>/dev/null || true
chmod 644 "$FULLCHAIN" "$CERT_FILE" "$CHAIN_FILE" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 3. 自检：证书能用、不是即将过期
# ---------------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
    subject="$(openssl x509 -in "$FULLCHAIN" -noout -subject 2>/dev/null || true)"
    issuer="$(openssl x509 -in "$FULLCHAIN" -noout -issuer 2>/dev/null || true)"
    enddate="$(openssl x509 -in "$FULLCHAIN" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    print_key_value "Subject" "${subject:-<解析失败>}"
    print_key_value "Issuer" "${issuer:-<解析失败>}"
    print_key_value "到期时间" "${enddate:-<解析失败>}"
    if ! openssl x509 -in "$FULLCHAIN" -noout -checkend 86400 >/dev/null 2>&1; then
        print_error "证书在 24 小时内即将过期或已过期，请检查 acme.sh 续期是否正常"
        exit 1
    fi
    print_success "证书自检通过（>24 小时有效期）"
fi

print_key_value "fullchain" "$FULLCHAIN"
print_key_value "privkey" "$PRIVKEY"
print_success "证书就绪: $DOMAIN"
