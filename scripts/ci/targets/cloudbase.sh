#!/bin/bash

# X Certbot - 同步目标: 腾讯云 CloudBase
#
# 用途: 把一张新签发的证书上传到【腾讯云 SSL 证书】，然后把 CloudBase HTTP 网关的
#       自定义域名重新指向新证书（tcb domains edit --certid）。
#
# 为什么必须显式重绑（docs/cert-automation/README.md §4.2 的结论）:
#   CloudBase 存的是证书 ID 指针，不是证书内容。Let's Encrypt 每次续期都会生成
#   新序列号的证书 -> 上传得到新的 CertificateId -> 与域名上记录的旧 ID 必然不等。
#   「什么都不做就自动续上」是走不通的，必须 edit。
#
# 幂等:
#   1) 上传时带 Repeatable=false —— 同指纹证书不会重复创建；
#   2) 上传后先读云端当前绑定的 CertId，若与本次的相同就直接跳过重绑；
#   3) 重绑后再回读校验，确保真的生效。
#   因此每天重复跑是安全的，且「上次同步失败」会在下一次运行里被自动补上。
#
# 本脚本改编自已验证过的 gitalk 版实现
#   gitalk/docs/cert-automation/deploy-cert-to-cloudbase.sh
# 主要差异:
#   - 由 workflow 调用（参数走环境变量 + TARGET_CONFIG JSON），不再依赖 acme.sh 的 reloadcmd 环境
#   - 支持一个条目同步多个自定义域名
#   - 支持可选的触发路径（tcb routes add），默认关闭
#   - 支持 DRY_RUN
#
# 依赖: bash + node + @cloudbase/cli(tcb)。刻意不依赖 jq / tccli / python。
#
# 输入环境变量:
#   CERT_DOMAIN        证书主域名（日志/别名用）
#   CERT_FULLCHAIN     完整证书链 PEM 路径
#   CERT_PRIVKEY       私钥 PEM 路径
#   TARGET_CONFIG      该目标的配置 JSON 文件（config.cjs 生成）
#   TARGET_OUTPUT_FILE 目标输出 key=value 文件（供后续目标/汇总使用）
#   TCB_BIN / NODE_BIN 可执行文件路径（不设则自动解析）
#   CLOUDBASE_SECRET_ID / CLOUDBASE_SECRET_KEY  腾讯云 CAM 子账号密钥（ID 走 Variables，Key 走 Secrets）
#   STATE_DIR          跨运行状态目录（可选，用于 delete_old_cert）
#   DRY_RUN            true 时只打印计划不调用接口

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/console_compat.sh
source "$SCRIPT_DIR/../lib/console_compat.sh"

# ---------------------------------------------------------------------------
# 输入
# ---------------------------------------------------------------------------
CERT_DOMAIN="${CERT_DOMAIN:?缺少 CERT_DOMAIN}"
CERT_FULLCHAIN="${CERT_FULLCHAIN:?缺少 CERT_FULLCHAIN}"
CERT_PRIVKEY="${CERT_PRIVKEY:?缺少 CERT_PRIVKEY}"
TARGET_CONFIG="${TARGET_CONFIG:?缺少 TARGET_CONFIG}"
TARGET_OUTPUT_FILE="${TARGET_OUTPUT_FILE:-}"
STATE_DIR="${STATE_DIR:-}"
DRY_RUN="${DRY_RUN:-false}"
TCB_BIN="${TCB_BIN:-}"
NODE_BIN="${NODE_BIN:-}"

[ -s "$CERT_FULLCHAIN" ] || { print_error "找不到证书文件: $CERT_FULLCHAIN"; exit 1; }
[ -s "$CERT_PRIVKEY" ]   || { print_error "找不到私钥文件: $CERT_PRIVKEY"; exit 1; }
[ -s "$TARGET_CONFIG" ]  || { print_error "找不到目标配置: $TARGET_CONFIG"; exit 1; }

# ---------------------------------------------------------------------------
# 解析 node / tcb
# ---------------------------------------------------------------------------
resolve_bin() {
    local explicit="$1" name="$2"; shift 2
    if [ -n "$explicit" ]; then
        [ -x "$explicit" ] || { print_error "$name 指向的文件不可执行: $explicit"; exit 1; }
        printf '%s' "$explicit"; return 0
    fi
    local cand
    for cand in "$@"; do
        [ -n "$cand" ] && [ -x "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
    command -v "$name" 2>/dev/null || return 1
}

REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
NODE_BIN="$(resolve_bin "$NODE_BIN" node /usr/local/bin/node /usr/bin/node || true)"
[ -n "$NODE_BIN" ] || { print_error "找不到 node"; exit 1; }
TCB_BIN="$(resolve_bin "$TCB_BIN" tcb "$REPO_ROOT/node_modules/.bin/tcb" /usr/local/bin/tcb /usr/bin/tcb || true)"
[ -n "$TCB_BIN" ] || { print_error "找不到 tcb（请先 npm i -g @cloudbase/cli，或设置 TCB_BIN）"; exit 1; }

print_deploy "同步目标: 腾讯云 CloudBase（证书 $CERT_DOMAIN）"
print_debug "node = $NODE_BIN"
print_debug "tcb  = $TCB_BIN"

# ---------------------------------------------------------------------------
# 通用 JSON 助手（递归查找，对响应结构不敏感）
# 思路沿用 gitalk 版脚本: 云端响应可能被包一层 data，也可能是 Response，
# 所以不写死路径，而是递归找到目标对象再取字段。
# ---------------------------------------------------------------------------
json_field() {
    # $1 = 点号路径（不支持数组下标）
    local dotted="$1"
    "$NODE_BIN" -e '
      const fs = require("fs");
      const dotted = process.argv[2];
      let cur = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      for (const part of dotted.split(".")) {
        if (cur === null || cur === undefined || typeof cur !== "object") { cur = undefined; break; }
        cur = cur[part];
      }
      if (cur === undefined || cur === null) process.exit(3);
      process.stdout.write(typeof cur === "object" ? JSON.stringify(cur) : String(cur));
    ' "$TARGET_CONFIG" "$dotted"
}

# 从任意形状的 JSON 里找出目标域名的 CertId
json_find_certid() {
    local domain="$1"
    "$NODE_BIN" -e '
      const domain = process.argv[1];
      let raw = "";
      process.stdin.on("data", (d) => (raw += d));
      process.stdin.on("end", () => {
        let parsed;
        try { parsed = JSON.parse(raw); } catch (e) {
          process.stderr.write("无法解析 JSON：" + raw.slice(0, 500) + "\n");
          process.exit(3);
        }
        const seen = new Set();
        let hit = null;
        (function walk(node) {
          if (!node || typeof node !== "object" || seen.has(node)) return;
          seen.add(node);
          if (Array.isArray(node)) { node.forEach(walk); return; }
          if (node.Domain === domain && node.CertId) { hit = node.CertId; return; }
          for (const v of Object.values(node)) walk(v);
        })(parsed);
        if (hit) process.stdout.write(hit);
      });
    ' "$domain"
}

# 从 UploadCertificate 响应里取证书 ID。
# 优先 CertificateId；当 Repeatable=false 命中同指纹证书时，腾讯云可能只回 RepeatCertId。
json_find_certificate_id() {
    "$NODE_BIN" -e '
      let raw = "";
      process.stdin.on("data", (d) => (raw += d));
      process.stdin.on("end", () => {
        let parsed;
        try { parsed = JSON.parse(raw); } catch (e) {
          process.stderr.write("上传响应不是合法 JSON：" + raw.slice(0, 800) + "\n");
          process.exit(3);
        }
        const seen = new Set();
        let first = null, repeat = null;
        (function walk(node) {
          if (!node || typeof node !== "object" || seen.has(node)) return;
          seen.add(node);
          if (Array.isArray(node)) { node.forEach(walk); return; }
          if (!first && typeof node.CertificateId === "string" && node.CertificateId) first = node.CertificateId;
          if (!repeat && typeof node.RepeatCertId === "string" && node.RepeatCertId) repeat = node.RepeatCertId;
          for (const v of Object.values(node)) walk(v);
        })(parsed);
        const hit = first || repeat;
        if (!hit) {
          process.stderr.write("响应里既没有 CertificateId 也没有 RepeatCertId：\n" + raw.slice(0, 800) + "\n");
          process.exit(4);
        }
        process.stdout.write(hit);
      });
    '
}

record_output() {
    [ -n "$TARGET_OUTPUT_FILE" ] || return 0
    printf '%s=%s\n' "$1" "$2" >> "$TARGET_OUTPUT_FILE"
}

# ---------------------------------------------------------------------------
# 读取目标配置
# ---------------------------------------------------------------------------
ENV_ID="$(json_field env_id || true)"
[ -n "$ENV_ID" ] || { print_error "目标配置里缺少 env_id"; exit 1; }
ROUTES_APPLY="$(json_field routes_apply || echo false)"
DELETE_OLD_CERT="$(json_field delete_old_cert || echo false)"
# 域名列表: 空则用证书主域名自身
# （不用 mapfile: 本仓库脚本要能在 macOS 自带的 bash 3.2 下直接跑，方便本机演练）
CB_DOMAINS=()
while IFS= read -r _d; do
    if [ -n "$_d" ]; then CB_DOMAINS+=("$_d"); fi
done < <("$NODE_BIN" -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  let list = Array.isArray(cfg.domains) ? cfg.domains.filter(Boolean) : [];
  if (list.length === 0) list = [process.argv[2]];
  list.forEach((d) => process.stdout.write(d + "\n"));
' "$TARGET_CONFIG" "$CERT_DOMAIN")
if [ "${#CB_DOMAINS[@]}" -eq 0 ]; then
    print_error "目标配置里没有可用的 CloudBase 域名"
    exit 1
fi

print_key_value "环境 ID" "$ENV_ID"
print_key_value "重绑域名" "${CB_DOMAINS[*]}"

# ---------------------------------------------------------------------------
# 证书 / 私钥配对自检（腾讯云会报 FailedOperation.CertificateMatchError）
# ---------------------------------------------------------------------------
if command -v openssl >/dev/null 2>&1; then
    pub_cert="$(openssl x509 -in "$CERT_FULLCHAIN" -noout -pubkey 2>/dev/null || true)"
    pub_key="$(openssl pkey -in "$CERT_PRIVKEY" -pubout 2>/dev/null || true)"
    if [ -n "$pub_cert" ] && [ -n "$pub_key" ] && [ "$pub_cert" != "$pub_key" ]; then
        print_error "证书与私钥不匹配，腾讯云会拒绝（FailedOperation.CertificateMatchError）"
        exit 1
    fi
    print_success "证书 / 私钥配对校验通过"
    not_after="$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    [ -n "$not_after" ] && print_info "证书到期时间: $not_after"
else
    print_warning "未找到 openssl，跳过配对校验"
fi

if [ "$DRY_RUN" = "true" ]; then
    print_warning "DRY-RUN: 跳过 tcb login / UploadCertificate / domains edit"
    record_output CLOUDBASE_DRY_RUN "true"
    exit 0
fi

# ---------------------------------------------------------------------------
# 登录
# ---------------------------------------------------------------------------
# CLOUDBASE_CI=1 让 CLI 的 autoConfirm() 直接返回默认值而不提问（源码 isYesMode()）；
# CI 里没有 TTY，不设这个会卡在确认提示上。所有命令另外都带 -y。
export CLOUDBASE_CI=1

if [ -n "${CLOUDBASE_SECRET_ID:-}" ] && [ -n "${CLOUDBASE_SECRET_KEY:-}" ]; then
    print_info "使用腾讯云 CAM 子账号密钥登录 CloudBase CLI（请用子账号，不要主账号）"
    # 凭据只通过命令行参数传给 tcb，不依赖 CLI 自己读环境变量。
    "$TCB_BIN" login --apiKeyId "$CLOUDBASE_SECRET_ID" --apiKey "$CLOUDBASE_SECRET_KEY" -y >/dev/null
else
    print_warning "未提供 CLOUDBASE_SECRET_ID/CLOUDBASE_SECRET_KEY，尝试沿用已有登录态"
fi

# ---------------------------------------------------------------------------
# 上传证书到腾讯云 SSL
# ---------------------------------------------------------------------------
CERT_ALIAS="${CERT_ALIAS:-LE-${CERT_DOMAIN}-$(date -u +%Y%m%dT%H%M%SZ)}"
REQ_FILE="$(mktemp)"
trap 'rm -f "$REQ_FILE"' EXIT

CERT_FULLCHAIN="$CERT_FULLCHAIN" CERT_PRIVKEY="$CERT_PRIVKEY" \
CERT_ALIAS="$CERT_ALIAS" REQ_FILE="$REQ_FILE" "$NODE_BIN" -e '
  const fs = require("fs");
  const body = {
    CertificatePublicKey: fs.readFileSync(process.env.CERT_FULLCHAIN, "utf8"),
    CertificatePrivateKey: fs.readFileSync(process.env.CERT_PRIVKEY, "utf8"),
    CertificateType: "SVR",   // SVR = 服务器证书（只有 CA 证书才不用传私钥）
    Repeatable: false,        // 同指纹不重复上传；命中已有证书时返回 RepeatCertId
    Alias: process.env.CERT_ALIAS
  };
  fs.writeFileSync(process.env.REQ_FILE, JSON.stringify(body));
'

print_info "上传证书到腾讯云 SSL（ssl.UploadCertificate）"
# --api-version 显式传 2019-12-05: 实测不传会报 version=undefined
UPLOAD_OUT="$("$TCB_BIN" api ssl UploadCertificate \
    --api-version 2019-12-05 \
    --body "$(cat "$REQ_FILE")" \
    --json -y)"
NEW_CERT_ID="$(printf '%s' "$UPLOAD_OUT" | json_find_certificate_id)"
print_success "腾讯云 SSL CertificateId = $NEW_CERT_ID"
record_output CLOUDBASE_CERT_ID "$NEW_CERT_ID"

# ---------------------------------------------------------------------------
# 逐域名重绑（幂等: 已绑定同一张就跳过）
# ---------------------------------------------------------------------------
FAILED=0
BOUND_LIST=""
for cb_domain in "${CB_DOMAINS[@]}"; do
    print_subheader "CloudBase 域名: $cb_domain"

    bound_before=""
    if ls_out="$("$TCB_BIN" domains ls -e "$ENV_ID" --filter "Domain=${cb_domain}" --json -y 2>/dev/null)"; then
        bound_before="$(printf '%s' "$ls_out" | json_find_certid "$cb_domain" || true)"
    fi
    print_key_value "云端当前 CertId" "${bound_before:-<无>}"

    if [ "$bound_before" = "$NEW_CERT_ID" ]; then
        print_success "云端已绑定该证书，无需重绑（幂等跳过）"
        BOUND_LIST="${BOUND_LIST}${cb_domain}=${NEW_CERT_ID} "
        continue
    fi

    print_info "重绑 [$cb_domain] -> CertId $NEW_CERT_ID（domains edit，不是 add；add 会撞 RESOURCE_ALREADY_EXISTS）"
    if ! "$TCB_BIN" domains edit "$cb_domain" \
        --certid "$NEW_CERT_ID" \
        -e "$ENV_ID" \
        --json -y >/dev/null; then
        print_error "重绑失败: $cb_domain"
        FAILED=1
        continue
    fi

    verify_out="$("$TCB_BIN" domains ls -e "$ENV_ID" --filter "Domain=${cb_domain}" --json -y)"
    bound_after="$(printf '%s' "$verify_out" | json_find_certid "$cb_domain" || true)"
    if [ "$bound_after" != "$NEW_CERT_ID" ]; then
        print_error "重绑后校验失败: $cb_domain 期望 ${NEW_CERT_ID}，实际 ${bound_after:-<空>}"
        FAILED=1
        continue
    fi
    print_success "校验通过: $cb_domain 当前 CertId = $bound_after"
    BOUND_LIST="${BOUND_LIST}${cb_domain}=${bound_after} "
done

# ---------------------------------------------------------------------------
# 可选: 触发路径（tcb routes add）
# 这是【一次性】动作: 重复执行会新增路由，所以默认关闭，只在配置里显式打开时才跑。
# routes add 没有 -y，会交互确认，所以用 yes 喂它。
# ---------------------------------------------------------------------------
if [ "$ROUTES_APPLY" = "true" ]; then
    print_subheader "触发路径（一次性动作，配置里 routes_apply=true 才执行）"
    while IFS= read -r route_json; do
        [ -n "$route_json" ] || continue
        print_info "routes add: $(printf '%s' "$route_json" | "$NODE_BIN" -e '
          let raw=""; process.stdin.on("data",d=>raw+=d);
          process.stdin.on("end",()=>{ const o=JSON.parse(raw);
            process.stdout.write(o.domain + o.routes.map(r=>r.path).join(",")); });')"
        if ! yes | "$TCB_BIN" routes add -e "$ENV_ID" --json -d "$route_json"; then
            print_error "routes add 失败"
            FAILED=1
        fi
    done < <("$NODE_BIN" -e '
      const fs = require("fs");
      const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const byDomain = new Map();
      for (const r of (cfg.routes || [])) {
        if (!byDomain.has(r.domain)) byDomain.set(r.domain, []);
        byDomain.get(r.domain).push({
          path: r.path,
          upstreamResourceType: r.upstream_resource_type,
          upstreamResourceName: r.upstream_resource_name,
          enable: r.enable,
          enableAuth: r.enable_auth,
          enableSafeDomain: r.enable_safe_domain,
          enablePathTransmission: r.enable_path_transmission
        });
      }
      for (const [domain, routes] of byDomain) {
        process.stdout.write(JSON.stringify({ domain, routes }) + "\n");
      }
    ' "$TARGET_CONFIG")
fi

record_output CLOUDBASE_BOUND_DOMAINS "${BOUND_LIST% }"

# ---------------------------------------------------------------------------
# 可选: 删除上一张证书
# ---------------------------------------------------------------------------
if [ "$DELETE_OLD_CERT" = "true" ]; then
    if [ -z "$STATE_DIR" ]; then
        print_warning "delete_old_cert=true 但未设置 STATE_DIR，跳过旧证书清理"
    else
        mkdir -p "$STATE_DIR"
        last_file="$STATE_DIR/${CERT_DOMAIN}.cloudbase-cert-id"
        if [ -f "$last_file" ]; then
            old_id="$(cat "$last_file")"
            if [ -n "$old_id" ] && [ "$old_id" != "$NEW_CERT_ID" ]; then
                print_info "删除旧证书 $old_id"
                # IsCheckResource 默认 false（不检查云资源关联）。
                # 注意: 如果旧证书还被别的云资源（CDN/CLB/WAF）引用，这里会把它删掉，确认无引用再开。
                if "$TCB_BIN" api ssl DeleteCertificate \
                    --api-version 2019-12-05 \
                    --body "{\"CertificateId\":\"$old_id\"}" --json -y >/dev/null; then
                    print_success "旧证书已删除"
                else
                    print_warning "旧证书删除失败（不影响本次同步，可事后在控制台清理）"
                fi
            fi
        fi
        printf '%s' "$NEW_CERT_ID" > "$last_file"
    fi
fi

if [ "$FAILED" -ne 0 ]; then
    print_error "CloudBase 同步有失败项（见上面的日志）"
    exit 1
fi
print_success "CloudBase 同步完成"
