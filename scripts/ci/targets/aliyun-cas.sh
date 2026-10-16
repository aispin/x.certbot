#!/bin/bash

# X Certbot - 同步目标: 阿里云 数字证书管理服务（CAS，原「SSL 证书」服务）
#
# 用途: 把证书上传到阿里云「数字证书管理服务」，作为阿里云侧的证书底座。
#       CDN / DCDN 等目标随后直接引用这里返回的证书 ID（CertType=cas），
#       证书只在阿里云存一份，避免多份副本各自过期。
#
# 官方接口（已核对官方文档）:
#   Action    : UploadUserCertificate
#   Product   : cas         Version: 2020-04-07      Endpoint: cas.aliyuncs.com
#   文档      : https://help.aliyun.com/zh/ssl-certificate/developer-reference/api-cas-2020-04-07-uploadusercertificate
#   请求参数  : Name(必填, 同账号内不能重名) / Cert / Key / ClientToken(幂等) / ResourceGroupId / Tags
#   返回      : CertId(integer) / ResourceId / RequestId
#   RAM 权限  : yundun-cert:UploadUserCertificate
#
# 查询接口（用于幂等判断）:
#   Action    : ListUserCertificateOrder
#   Product   : cas         Version: 2020-04-07
#   文档      : https://help.aliyun.com/zh/ssl-certificate/developer-reference/api-cas-2020-04-07-listusercertificateorder
#   请求参数  : OrderType=UPLOAD / CurrentPage / ShowSize
#   返回字段  : CertificateId / Name / Sha2 / Fingerprint / CommonName / Sans / Expired
#   RAM 权限  : yundun-cert:ListUserCertificateOrder
#
# 幂等设计（重要）:
#   CAS 的 Name 在同一账号下不允许重复，而 Let's Encrypt 每次续期都是新证书，
#   所以既不能固定名字（第二次会失败），也不能用时间戳（每次跑都产生垃圾证书）。
#   做法是把证书指纹写进名字: Name = "<前缀>-<域名>-<SHA256(叶子证书 DER) 前12位>"。
#   - 同一张证书重复运行 -> 名字相同 -> 先查列表命中 -> 直接复用 CertId，不上传
#   - 新证书 -> 名字不同 -> 正常上传
#   另外还会用列表里的 Sha2 字段做一次指纹比对（双保险）。
#
# 依赖: bash + node（scripts/ci/lib/aliyun-api.cjs）。刻意不依赖 aliyun CLI / python / jq。
#
# 输入环境变量:
#   CERT_DOMAIN / CERT_FULLCHAIN / CERT_PRIVKEY / TARGET_CONFIG / TARGET_OUTPUT_FILE
#   ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT  阿里云证书同步凭据
#       未配置时自动回退到 ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS（DNS 那一对）。
#       解析逻辑在 scripts/ci/lib/aliyun-api.cjs，权限不足时的补配方法见 docs/07 第 4.3 节。
#   NODE_BIN / DRY_RUN

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/console_compat.sh
source "$SCRIPT_DIR/../lib/console_compat.sh"

CERT_DOMAIN="${CERT_DOMAIN:?缺少 CERT_DOMAIN}"
CERT_FULLCHAIN="${CERT_FULLCHAIN:?缺少 CERT_FULLCHAIN}"
CERT_PRIVKEY="${CERT_PRIVKEY:?缺少 CERT_PRIVKEY}"
TARGET_CONFIG="${TARGET_CONFIG:?缺少 TARGET_CONFIG}"
TARGET_OUTPUT_FILE="${TARGET_OUTPUT_FILE:-}"
DRY_RUN="${DRY_RUN:-false}"

[ -s "$CERT_FULLCHAIN" ] || { print_error "找不到证书文件: $CERT_FULLCHAIN"; exit 1; }
[ -s "$CERT_PRIVKEY" ]   || { print_error "找不到私钥文件: $CERT_PRIVKEY"; exit 1; }

REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || { print_error "找不到 node"; exit 1; }
ALIYUN_API="$SCRIPT_DIR/../lib/aliyun-api.cjs"
[ -f "$ALIYUN_API" ] || { print_error "找不到 $ALIYUN_API"; exit 1; }

CAS_VERSION="2020-04-07"

record_output() {
    [ -n "$TARGET_OUTPUT_FILE" ] || return 0
    printf '%s=%s\n' "$1" "$2" >> "$TARGET_OUTPUT_FILE"
}

print_deploy "同步目标: 阿里云 数字证书管理服务 (CAS)（证书 $CERT_DOMAIN）"

# ---------------------------------------------------------------------------
# 1. 计算证书指纹，生成确定性的证书名称
#    SHA-256 取「叶子证书的 DER 字节」，与 CAS 列表里的 Sha2 字段同源。
# ---------------------------------------------------------------------------
NAME_PREFIX="$("$NODE_BIN" -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(cfg.name_prefix || "LE"));
' "$TARGET_CONFIG")"

FP12="$("$NODE_BIN" -e '
  const crypto = require("crypto");
  const fs = require("fs");
  const pem = fs.readFileSync(process.argv[1], "utf8");
  // fullchain 里的第一段就是叶子证书
  const m = pem.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/);
  if (!m) { process.stderr.write("证书文件里找不到 PEM 证书块\n"); process.exit(2); }
  const der = Buffer.from(m[0].replace(/-----[^-]+-----/g, "").replace(/\s+/g, ""), "base64");
  process.stdout.write(crypto.createHash("sha256").update(der).digest("hex").toUpperCase());
  // 完整摘要写到 stderr 便于排障，stdout 只给前 12 位
  ' "$CERT_FULLCHAIN" | head -c 80)"
FP12="${FP12:0:12}"
[ -n "$FP12" ] || { print_error "无法计算证书指纹"; exit 1; }

# Name 最长 63 字符: <前缀>-<域名>-<12位指纹>
CERT_NAME="$("$NODE_BIN" -e '
  const prefix = process.argv[1], domain = process.argv[2], fp = process.argv[3];
  const suffix = "-" + fp;                 // 13 字符
  let room = 63 - suffix.length - 1;       // 再留 1 个连字符分隔域名
  let d = domain;
  if (prefix.length + 1 + d.length > room) {
    d = d.slice(0, Math.max(1, room - prefix.length - 1));
  }
  process.stdout.write(prefix + "-" + d + suffix);
' "$NAME_PREFIX" "$CERT_DOMAIN" "$FP12")"

print_key_value "证书名称" "$CERT_NAME"
print_key_value "SHA256 前12位" "$FP12"

aliyun_call() {
    # 所有调用都经过这里，保证凭据只从环境变量读、日志里不出现私钥
    "$NODE_BIN" "$ALIYUN_API" --product cas --version "$CAS_VERSION" "$@"
}

# ---------------------------------------------------------------------------
# 2. 先查列表，命中同名 / 同指纹就复用，不上传
# ---------------------------------------------------------------------------
find_existing_cert_id() {
    local page=1
    while [ "$page" -le 30 ]; do
        local listing
        if ! listing="$(aliyun_call --action ListUserCertificateOrder \
                --param OrderType=UPLOAD \
                --param CurrentPage="$page" \
                --param ShowSize=100 2>/dev/null)"; then
            print_warning "ListUserCertificateOrder 第 $page 页查询失败（继续尝试上传路径）"
            return 0
        fi
        local hit
        hit="$(printf '%s' "$listing" | "$NODE_BIN" -e '
          let raw = "";
          process.stdin.on("data", (d) => (raw += d));
          process.stdin.on("end", () => {
            let parsed;
            try { parsed = JSON.parse(raw); } catch (e) { process.exit(0); }
            const wantName = process.argv[1], wantSha2 = process.argv[2].toUpperCase();
            const list = Array.isArray(parsed.CertificateOrderList) ? parsed.CertificateOrderList : [];
            for (const item of list) {
              if (!item || !item.CertificateId) continue;
              const nameHit = item.Name && item.Name === wantName;
              const shaHit = item.Sha2 && String(item.Sha2).toUpperCase() === wantSha2;
              if (nameHit || shaHit) {
                process.stdout.write(JSON.stringify({
                  id: String(item.CertificateId),
                  by: nameHit ? "name" : "sha2",
                  name: item.Name || "",
                }));
                return;
              }
            }
            // 没有命中: 用总条数判断是否还有下一页
            const total = Number(parsed.TotalCount || 0);
            const size = Number(parsed.ShowSize || 100);
            const current = Number(parsed.CurrentPage || 1);
            if (total > current * size) process.stdout.write("NEXT_PAGE");
          });
        ' "$CERT_NAME" "$FP12")"
        if [ -z "$hit" ]; then
            return 0
        elif [ "$hit" = "NEXT_PAGE" ]; then
            page=$((page + 1))
            continue
        else
            printf '%s' "$hit"
            return 0
        fi
    done
    return 0
}

EXISTING=""
if [ "$DRY_RUN" = "true" ]; then
    print_warning "DRY-RUN: 跳过 ListUserCertificateOrder / UploadUserCertificate"
    aliyun_call --action UploadUserCertificate \
        --param Name="$CERT_NAME" \
        --param Cert=@"$CERT_FULLCHAIN" \
        --param Key=@"$CERT_PRIVKEY" \
        --param ClientToken="$FP12" \
        --dry-run >/dev/null
    record_output ALIYUN_CAS_DRY_RUN "true"
    # 给下游 CDN/DCDN 一个占位 ID，让它们的参数拼装也能在 DRY-RUN 下走一遍
    record_output ALIYUN_CAS_CERT_ID "DRYRUN-${FP12}"
    record_output ALIYUN_CAS_CERT_NAME "$CERT_NAME"
    exit 0
fi

EXISTING="$(find_existing_cert_id)"
if [ -n "$EXISTING" ]; then
    EXISTING_ID="$(printf '%s' "$EXISTING" | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).id))')"
    EXISTING_BY="$(printf '%s' "$EXISTING" | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).by))')"
    print_success "CAS 里已存在该证书（命中方式: $EXISTING_BY），复用 CertId=$EXISTING_ID，跳过上传"
    record_output ALIYUN_CAS_CERT_ID "$EXISTING_ID"
    record_output ALIYUN_CAS_CERT_NAME "$CERT_NAME"
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. 上传
# ---------------------------------------------------------------------------
print_info "上传证书到 CAS（cas.UploadUserCertificate）"
# 注意: stdout（要取的值）和 stderr（诊断信息）必须分开捕获。
# 用 2>&1 会把 aliyun-api.cjs 的诊断行混进 CertId 里 —— 演练时就是这么抓出来的。
UPLOAD_ERR_FILE="$(mktemp)"
set +e
UPLOAD_OUT="$(aliyun_call --action UploadUserCertificate \
    --param Name="$CERT_NAME" \
    --param Cert=@"$CERT_FULLCHAIN" \
    --param Key=@"$CERT_PRIVKEY" \
    --param ClientToken="$FP12" \
    --extract CertId 2>"$UPLOAD_ERR_FILE")"
UPLOAD_RC=$?
set -e
UPLOAD_ERR="$(cat "$UPLOAD_ERR_FILE")"
rm -f "$UPLOAD_ERR_FILE"

if [ "$UPLOAD_RC" -ne 0 ]; then
    # CAS 的 Name 不允许重复。如果并发或查询滞后导致重名，退回到「按名字重查再复用」，
    # 而不是让整条流水线失败（这也是「重复运行不产生垃圾资源」的最后一道保险）。
    print_warning "上传失败: $UPLOAD_ERR"
    print_info "尝试按证书名重查，若已存在则直接复用"
    RETRY="$(find_existing_cert_id)"
    if [ -n "$RETRY" ]; then
        RETRY_ID="$(printf '%s' "$RETRY" | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).id))')"
        print_success "复用已存在的证书 CertId=$RETRY_ID"
        record_output ALIYUN_CAS_CERT_ID "$RETRY_ID"
        record_output ALIYUN_CAS_CERT_NAME "$CERT_NAME"
        exit 0
    fi
    print_error "CAS 上传失败且重查未命中，请检查 RAM 权限（yundun-cert:UploadUserCertificate）"
    exit 1
fi

# 只接受纯数字 ID: 万一将来又有什么东西污染了 stdout，这里会立刻挡住而不是把脏值传给下游
CERT_ID="$(printf '%s' "$UPLOAD_OUT" | tr -d '[:space:]')"
case "$CERT_ID" in
    '') print_error "上传成功但没拿到 CertId"; exit 1 ;;
    *[!0-9]*) print_error "CertId 不是纯数字（实际值: $CERT_ID），可能是诊断输出混进了 stdout"; exit 1 ;;
esac

print_success "CAS CertId = $CERT_ID"
record_output ALIYUN_CAS_CERT_ID "$CERT_ID"
record_output ALIYUN_CAS_CERT_NAME "$CERT_NAME"
print_success "CAS 同步完成"
