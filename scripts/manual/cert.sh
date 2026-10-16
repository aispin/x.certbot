#!/usr/bin/env bash
#
# cert.sh —— 单域名证书：签发（acme.sh + 阿里云 DNS-01） / 同步（腾讯云 SSL → CloudBase）
#
# 合并自 issue-and-install.sh + deploy-cert-to-cloudbase.sh。
# 之所以能合成一个脚本：acme.sh 的 --reloadcmd 只要求「一个可独立执行的入口」，
# 而「同一个脚本 + 子命令」正好满足 —— 钩子就是本脚本的 deploy 子命令。
#
# 子命令：
#   issue   一次性：acme.sh --issue（阿里云 DNS-01）→ --install-cert 到稳定路径
#           → 把 deploy 挂成续期钩子。注意 --install-cert 会【立刻执行一次】钩子，
#           所以 issue 跑完其实已经同步过一次了。
#   deploy  上传腾讯云 SSL → 重绑 CloudBase 自定义域名 → 回读校验。
#           幂等，可反复手工执行；它同时就是 acme.sh 续期钩子的入口。
#   renew   强制续期一次（acme.sh --renew --force），用来演练钩子是否真的会触发。
#
# 依赖：bash + node（>=18）+ openssl + @cloudbase/cli（tcb）。
#       刻意不依赖 jq / tccli / python。
#
# 用法（无参数运行本脚本也会打印下面这段）：
#   export CERT_DOMAIN=your.domain
#   export ALIYUN_SECRET_ID_DNS=...  ALIYUN_SECRET_KEY_DNS=...
#   export CLOUDBASE_SECRET_ID=...   CLOUDBASE_SECRET_KEY=...
#   export CLOUDBASE_ENV_ID=env-xxxxxxxx
#   bash scripts/manual/cert.sh issue      # 首次：签发 + 挂钩子（会立刻跑一次 deploy）
#   bash scripts/manual/cert.sh deploy     # 之后任何时候都可手工重跑
#   bash scripts/manual/cert.sh renew      # 演练：强制续期一次，看钩子会不会被触发
#
# 环境变量（除 CERT_DOMAIN 外都有默认值，见用法输出）：
#   CERT_DOMAIN              必填，证书域名
#   ACME_EMAIL               ACME 账户邮箱；不设时用 admin@<域名去掉首个标签>
#   ALIYUN_SECRET_ID_DNS     阿里云 RAM AccessKeyId，DNS-01 验证用（要能改 DNS 记录）
#   ALIYUN_SECRET_KEY_DNS    同上，AccessKeySecret
#   CLOUDBASE_SECRET_ID      腾讯云 CAM 子账号 SecretId（deploy 登录用，可省略沿用已有登录态）
#   CLOUDBASE_SECRET_KEY     同上，SecretKey
#   CLOUDBASE_ENV_ID         CloudBase 环境 ID，issue / deploy 必填
#   LOG_FILE                 钩子日志文件，默认 /var/log/cert-sync.log
#   进阶（一般不用动）：ACME_SERVER / KEY_LENGTH / ACME_HOME / ACME / SSL_DIR /
#   CERT_FULLCHAIN / CERT_PRIVKEY / CERT_ALIAS / STATE_DIR / DELETE_OLD_CERT /
#   TCB_BIN / NODE_BIN / REPO_ROOT
#   兼容旧名（两个旧脚本里的写法）：Ali_Key / Ali_Secret / TCB_SECRET_ID / TCB_SECRET_KEY
#
# 钩子的环境变量从哪来：钩子是 acme.sh 的子进程，只继承 acme.sh 自己的环境。
# 手工跑 issue / renew 时本脚本会把这些变量 export 给 acme.sh，所以没问题；
# 但 cron 里直接跑 `acme.sh --cron` 时，只有 cron 环境里【存在】的变量才看得到 ——
# 请把这几个 export 写进 cron 的环境（或自备 wrapper），否则续期会成功、同步会失败。
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 自身路径（--reloadcmd 必须用绝对路径：acme.sh 从 cron 触发时工作目录不是这里）
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
SELF="$SCRIPT_DIR/$SCRIPT_NAME"

# ---------------------------------------------------------------------------
# 配置（都可用环境变量覆盖）
# ---------------------------------------------------------------------------
CERT_DOMAIN="${CERT_DOMAIN:-}"

# 阿里云凭据：本脚本只用阿里云做 DNS-01 验证（增删 _acme-challenge TXT），
# 不碰阿里云的证书 / CDN / DCDN，所以这里要的是 DNS 那一对，
# 不是证书同步用的 ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT。
# 旧名 Ali_Key / Ali_Secret 是 acme.sh dns_ali 插件自己的变量名，仍然接受。
ALIYUN_SECRET_ID_DNS="${ALIYUN_SECRET_ID_DNS:-${Ali_Key:-}}"
ALIYUN_SECRET_KEY_DNS="${ALIYUN_SECRET_KEY_DNS:-${Ali_Secret:-}}"

# 腾讯云 / CloudBase（旧名 TCB_SECRET_ID / TCB_SECRET_KEY 仍然接受）
CLOUDBASE_ENV_ID="${CLOUDBASE_ENV_ID:-}"
CLOUDBASE_SECRET_ID="${CLOUDBASE_SECRET_ID:-${TCB_SECRET_ID:-}}"
CLOUDBASE_SECRET_KEY="${CLOUDBASE_SECRET_KEY:-${TCB_SECRET_KEY:-}}"

ACME_EMAIL="${ACME_EMAIL:-}"
ACME_SERVER="${ACME_SERVER:-letsencrypt}"   # 必须显式指定：acme.sh 默认 CA 是 ZeroSSL
KEY_LENGTH="${KEY_LENGTH:-2048}"            # RSA 2048；首次落地不要用默认的 ec-256，见 README

ACME_HOME="${ACME_HOME:-$HOME/.acme.sh}"
ACME="${ACME:-$ACME_HOME/acme.sh}"

SSL_DIR="${SSL_DIR:-/etc/ssl/${CERT_DOMAIN}}"
CERT_FULLCHAIN="${CERT_FULLCHAIN:-$SSL_DIR/fullchain.pem}"
CERT_PRIVKEY="${CERT_PRIVKEY:-$SSL_DIR/privkey.pem}"

LOG_FILE="${LOG_FILE:-/var/log/cert-sync.log}"

# 证书在腾讯云 SSL 控制台里显示的名字；留空则按时间戳生成，方便区分是哪一次续期。
CERT_ALIAS="${CERT_ALIAS:-}"

# 记录上一次的 CertificateId，用于识别「内容没变」和清理旧证书
STATE_DIR="${STATE_DIR:-/var/lib/cloudbase-cert}"

# 是否删除上一张证书（1=删，0=保留）。默认保留：域名上正在用的那张千万别删。
# 注意 CloudBase 绑定的是 CertId，重绑瞬间旧证书就不再被引用，但为稳妥起见默认不动它。
DELETE_OLD_CERT="${DELETE_OLD_CERT:-0}"

# 上传请求体的临时文件（deploy 里赋值；必须是全局变量，EXIT trap 才能读到它）
REQ_FILE=""

# tcb / node：不设置时按「仓库本地 bin → PATH」顺序找
TCB_BIN="${TCB_BIN:-}"
NODE_BIN="${NODE_BIN:-}"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# deploy 子命令（以及 acme.sh eval 钩子时的子进程）只继承导出过的变量。
# 这里显式 export 一遍，避免「手工跑没事、钩子里却报缺少 CLOUDBASE_ENV_ID」。
export CERT_DOMAIN CLOUDBASE_ENV_ID CLOUDBASE_SECRET_ID CLOUDBASE_SECRET_KEY
export CERT_FULLCHAIN CERT_PRIVKEY STATE_DIR DELETE_OLD_CERT
export CERT_ALIAS LOG_FILE TCB_BIN NODE_BIN REPO_ROOT

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

# 把参数包成 shell 单引号字面量。
# --reloadcmd 是一段会被 acme.sh eval 的 shell 代码，路径里可能有空格，必须转义。
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

require_domain() {
  [ -n "$CERT_DOMAIN" ] || { echo "CERT_DOMAIN is required: export CERT_DOMAIN=your.domain" >&2; exit 1; }
}

usage() {
  cat <<EOF
用法：$SCRIPT_NAME <子命令>

子命令：
  issue    首次签发：acme.sh --issue（阿里云 DNS-01）→ --install-cert 到稳定路径
           → 把「$SCRIPT_NAME deploy」挂成 acme.sh 的续期钩子（--reloadcmd）
  deploy   上传腾讯云 SSL → 重绑 CloudBase 自定义域名 → 回读校验（幂等；钩子入口）
  renew    强制续期一次（acme.sh --renew --force），用来演练钩子是否真的会触发

所需环境变量：
  CERT_DOMAIN              必填，证书域名
  ACME_EMAIL               ACME 账户邮箱（可选，默认 admin@<域名去掉首个标签>）
  ALIYUN_SECRET_ID_DNS     阿里云 RAM AccessKeyId，DNS-01 验证用
  ALIYUN_SECRET_KEY_DNS    阿里云 RAM AccessKeySecret，DNS-01 验证用
  CLOUDBASE_SECRET_ID      腾讯云 CAM 子账号 SecretId（可选，省略则沿用已有登录态）
  CLOUDBASE_SECRET_KEY     腾讯云 CAM 子账号 SecretKey
  CLOUDBASE_ENV_ID         CloudBase 环境 ID（issue / deploy 必填）
  LOG_FILE                 钩子日志文件（默认 /var/log/cert-sync.log）

示例：
  export CERT_DOMAIN=your.domain
  export ALIYUN_SECRET_ID_DNS=...  ALIYUN_SECRET_KEY_DNS=...
  export CLOUDBASE_SECRET_ID=...   CLOUDBASE_SECRET_KEY=...
  export CLOUDBASE_ENV_ID=env-xxxxxxxx
  bash $SCRIPT_NAME issue      # 首次：签发 + 挂钩子（会立刻跑一次 deploy）
  bash $SCRIPT_NAME deploy     # 之后任何时候都可手工重跑
  bash $SCRIPT_NAME renew      # 演练：强制续期一次
EOF
}

# ---------------------------------------------------------------------------
# 通用：从「仓库本地 bin → 常见绝对路径 → PATH」里解析可执行文件
# ---------------------------------------------------------------------------
resolve_bin() {
  local explicit="$1" name="$2"; shift 2
  if [ -n "$explicit" ]; then
    [ -x "$explicit" ] || die "$name 指向的文件不可执行：$explicit"
    printf '%s' "$explicit"; return 0
  fi
  local cand
  for cand in "$@"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then printf '%s' "$cand"; return 0; fi
  done
  local found
  found="$(command -v "$name" 2>/dev/null || true)"
  [ -n "$found" ] && { printf '%s' "$found"; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# 通用 JSON 助手（对响应结构不敏感：tcb 会把结果包一层 data，tccli 是 Response）
# 都走 node，不依赖 jq / python。
# ---------------------------------------------------------------------------

# 从任意形状的 JSON 里找出目标域名的 CertId。
# 兼容 {data:{Domains:[...]}} / {Domains:[...]} / {data:{...}} / 直接数组 等所有形态，
# 做法是递归遍历，找到 .Domain === 目标域名的对象再取 .CertId。
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
# 优先 CertificateId；当 Repeatable=false 命中同指纹证书时，腾讯云可能只回 RepeatCertId，
# 这时必须回退到 RepeatCertId —— 否则「第二次执行」会因为拿不到 ID 而失败。
json_find_certificate_id() {
  "$NODE_BIN" -e '
    let raw = "";
    process.stdin.on("data", (d) => (raw += d));
    process.stdin.on("end", () => {
      let parsed;
      try { parsed = JSON.parse(raw); } catch (e) {
        process.stderr.write("上传响应不是合法 JSON：\n" + raw.slice(0, 800) + "\n");
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

# ---------------------------------------------------------------------------
# issue：首次签发 + 安装到稳定路径 + 挂本脚本的 deploy 子命令当续期钩子
# ---------------------------------------------------------------------------
cmd_issue() {
  require_domain

  # --- 前置检查 ---
  [ -n "$ALIYUN_SECRET_ID_DNS" ]  || die "缺少 ALIYUN_SECRET_ID_DNS（阿里云 RAM AccessKeyId，DNS-01 用）"
  [ -n "$ALIYUN_SECRET_KEY_DNS" ] || die "缺少 ALIYUN_SECRET_KEY_DNS（阿里云 RAM AccessKeySecret，DNS-01 用）"
  [ -n "$CLOUDBASE_ENV_ID" ]      || die "缺少 CLOUDBASE_ENV_ID"
  [ -x "$SELF" ] || die "本脚本不可执行，--reloadcmd 无法执行它：$SELF（chmod +x \"$SELF\"）"

  # acme.sh 的 dns_ali 插件读的是 Ali_Key / Ali_Secret，这里做一次名字映射。
  if [ -n "$ALIYUN_SECRET_ID_DNS" ];  then export Ali_Key="$ALIYUN_SECRET_ID_DNS";    fi
  if [ -n "$ALIYUN_SECRET_KEY_DNS" ]; then export Ali_Secret="$ALIYUN_SECRET_KEY_DNS"; fi

  if [ ! -x "$ACME" ]; then
    log "未找到 $ACME，开始安装 acme.sh"
    curl -sS https://get.acme.sh | sh -s email="${ACME_EMAIL:-admin@${CERT_DOMAIN#*.}}"
    [ -x "$ACME" ] || die "acme.sh 安装后仍找不到：$ACME"
  fi
  log "acme.sh = $ACME"

  mkdir -p "$SSL_DIR"
  chmod 750 "$SSL_DIR" || true

  # --- 1. 签发（DNS-01 / 阿里云）---
  # acme.sh 用退出码 2 表示「证书还在有效期内，跳过签发」，这不是失败：
  # 允许重复执行 issue（比如钩子之前没挂上，重跑一次把它补上）。
  log "签发证书：$CERT_DOMAIN（CA=$ACME_SERVER, keylength=$KEY_LENGTH）"
  local rc=0
  "$ACME" --issue \
    --server "$ACME_SERVER" \
    -d "$CERT_DOMAIN" \
    --dns dns_ali \
    --keylength "$KEY_LENGTH" || rc=$?
  case "$rc" in
    0) : ;;
    2) log "acme.sh 报告未到续期时间（exit 2），跳过签发，继续安装 / 同步已有证书" ;;
    *) die "acme.sh --issue 失败（exit $rc）" ;;
  esac

  # --- 2. 复制到稳定路径 + 挂钩子 ---
  # 注意：--install-cert 会【立刻执行一次】--reloadcmd，
  # 所以这一步同时完成「上传腾讯云 SSL + 重绑 CloudBase 域名」。
  # （源码 _installcert()：先复制证书文件，之后才 eval 钩子。）
  local reload_cmd
  reload_cmd="$(shq "$SELF") deploy >>$(shq "$LOG_FILE") 2>&1"
  log "安装证书到 $SSL_DIR，并注册 --reloadcmd：$reload_cmd"
  "$ACME" --install-cert -d "$CERT_DOMAIN" \
    --key-file       "$CERT_PRIVKEY" \
    --fullchain-file "$CERT_FULLCHAIN" \
    --reloadcmd      "$reload_cmd"

  # --- 3. 结果提示 ---
  log "完成。证书文件："
  log "  fullchain = $CERT_FULLCHAIN"
  log "  privkey   = $CERT_PRIVKEY"
  log "钩子日志：$LOG_FILE"

  cat <<EOF

-------------------------------- 接下来 ---------------------------------
1) 确认钩子跑通了：
     tail -n 50 $LOG_FILE

2) 拷出刚上传得到的 CertificateId（钩子日志里有一行 "腾讯云 SSL CertificateId = ..."）。
   如果这是【首次】绑定该域名，执行一次 add：
     tcb login --apiKeyId "\$CLOUDBASE_SECRET_ID" --apiKey "\$CLOUDBASE_SECRET_KEY" -y
     tcb domains add $CERT_DOMAIN --certid <CertificateId> -e $CLOUDBASE_ENV_ID -y

   如果域名已经绑定过，钩子里的 domains edit 已经改好了，不需要做任何事。

3) 去阿里云 DNS 给 $CERT_DOMAIN 加 CNAME 记录，
   值从下面这条命令的输出里取：
     tcb domains ls -e $CLOUDBASE_ENV_ID --filter "Domain=$CERT_DOMAIN" --json -y

4) 演练一次续期，别等 60 天后才发现钩子坏了：
     bash $SELF renew
     tail -n 50 $LOG_FILE
-------------------------------------------------------------------------

EOF
}

# ---------------------------------------------------------------------------
# deploy：上传腾讯云 SSL → 重绑 CloudBase 域名 → 回读校验（幂等）
# 设计为 acme.sh 的 --reloadcmd 钩子：acme.sh 会用同一个脚本的 deploy 子命令调用它。
# ---------------------------------------------------------------------------
cmd_deploy() {
  require_domain

  # --- 0. 解析依赖 ---
  NODE_BIN="$(resolve_bin "$NODE_BIN" node \
    "$REPO_ROOT/node_modules/.bin/node" \
    /usr/local/bin/node /opt/homebrew/bin/node /usr/bin/node)" \
    || die "找不到 node。请显式设置 NODE_BIN=/绝对路径/node"

  TCB_BIN="$(resolve_bin "$TCB_BIN" tcb \
    "$REPO_ROOT/node_modules/.bin/tcb" \
    /usr/local/bin/tcb /opt/homebrew/bin/tcb /usr/bin/tcb)" \
    || die "找不到 tcb。请先安装 @cloudbase/cli，或设置 TCB_BIN=/绝对路径/tcb"

  log "node  = $NODE_BIN"
  log "tcb   = $TCB_BIN"
  log "域名  = $CERT_DOMAIN"

  # --- 1. 找证书文件 ---
  # 证书文件：优先用 --install-cert 复制出来的稳定路径；
  # 找不到时回退到 acme.sh 在 reloadcmd 环境里 export 的 CERT_FULLCHAIN_PATH / CERT_KEY_PATH。
  if [ ! -s "$CERT_FULLCHAIN" ] && [ -n "${CERT_FULLCHAIN_PATH:-}" ] && [ -s "${CERT_FULLCHAIN_PATH}" ]; then
    CERT_FULLCHAIN="$CERT_FULLCHAIN_PATH"
  fi
  if [ ! -s "$CERT_PRIVKEY" ] && [ -n "${CERT_KEY_PATH:-}" ] && [ -s "${CERT_KEY_PATH}" ]; then
    CERT_PRIVKEY="$CERT_KEY_PATH"
  fi
  [ -s "$CERT_FULLCHAIN" ] || die "找不到 fullchain：$CERT_FULLCHAIN"
  [ -s "$CERT_PRIVKEY" ]   || die "找不到私钥：$CERT_PRIVKEY"
  log "fullchain = $CERT_FULLCHAIN"
  log "privkey   = $CERT_PRIVKEY"

  # --- 2. 自检：证书和私钥是否配对、是否已过期 ---
  if command -v openssl >/dev/null 2>&1; then
    local pub_from_cert pub_from_key not_after
    pub_from_cert="$(openssl x509 -in "$CERT_FULLCHAIN" -noout -pubkey 2>/dev/null || true)"
    pub_from_key="$(openssl pkey -in "$CERT_PRIVKEY" -pubout 2>/dev/null || true)"
    if [ -z "$pub_from_cert" ] || [ -z "$pub_from_key" ]; then
      log "WARN: openssl 无法解析证书/私钥，跳过配对校验"
    elif [ "$pub_from_cert" != "$pub_from_key" ]; then
      die "证书与私钥不匹配（腾讯云会报 FailedOperation.CertificateMatchError）：
  fullchain = $CERT_FULLCHAIN
  privkey   = $CERT_PRIVKEY
请确认这两个文件来自同一次签发（acme.sh --install-cert 的 --fullchain-file / --key-file 是否写到了别处）"
    else
      log "证书 / 私钥配对校验通过"
    fi

    not_after="$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    [ -n "$not_after" ] && log "证书到期时间：$not_after"
  fi

  [ -n "$CLOUDBASE_ENV_ID" ] || die "缺少 CLOUDBASE_ENV_ID"

  # --- 3. 登录（可选；已有登录态时可省略 CLOUDBASE_SECRET_ID/CLOUDBASE_SECRET_KEY）---
  # CLOUDBASE_CI=1 让 CLI 的 autoConfirm() 直接返回默认值而不提问（源码 isYesMode()），
  # cron 里没有 TTY，不设这个会卡在确认提示上。
  export CLOUDBASE_CI=1

  if [ -n "$CLOUDBASE_SECRET_ID" ] && [ -n "$CLOUDBASE_SECRET_KEY" ]; then
    log "使用腾讯云 API 密钥登录 CloudBase CLI（子账号）"
    "$TCB_BIN" login --apiKeyId "$CLOUDBASE_SECRET_ID" --apiKey "$CLOUDBASE_SECRET_KEY" -y >/dev/null
  else
    log "未提供 CLOUDBASE_SECRET_ID/CLOUDBASE_SECRET_KEY，沿用已有登录态"
  fi

  # --- 4. 记录当前域名绑定的 CertId（用于幂等判断）---
  # 状态文件只服务于「可选地清理旧证书」，不可写时降级为警告，不能因此让同步失败。
  local last_cert_file=""
  if mkdir -p "$STATE_DIR" 2>/dev/null; then
    last_cert_file="$STATE_DIR/${CERT_DOMAIN}.last-cert-id"
  else
    log "WARN: 状态目录不可写（$STATE_DIR），本次不记录 CertId（只影响可选的旧证书清理）"
  fi

  local bound_before=""
  local ls_out=""
  if ls_out="$("$TCB_BIN" domains ls -e "$CLOUDBASE_ENV_ID" --filter "Domain=${CERT_DOMAIN}" --json -y 2>/dev/null)"; then
    bound_before="$(printf '%s' "$ls_out" | json_find_certid "$CERT_DOMAIN" || true)"
  fi
  log "云端当前绑定的 CertId：${bound_before:-<无>}"

  # --- 5. 上传证书到腾讯云 SSL  →  ssl.UploadCertificate ---
  REQ_FILE="$(mktemp)"
  trap 'rm -f "$REQ_FILE"' EXIT

  local cert_alias="${CERT_ALIAS:-LE-${CERT_DOMAIN}-$(date -u +%Y%m%dT%H%M%SZ)}"
  CERT_FULLCHAIN="$CERT_FULLCHAIN" CERT_PRIVKEY="$CERT_PRIVKEY" \
  CERT_ALIAS="$cert_alias" REQ_FILE="$REQ_FILE" "$NODE_BIN" -e '
    const fs = require("fs");
    const body = {
      CertificatePublicKey: fs.readFileSync(process.env.CERT_FULLCHAIN, "utf8"),
      CertificatePrivateKey: fs.readFileSync(process.env.CERT_PRIVKEY, "utf8"),
      CertificateType: "SVR",   // SVR = 服务器证书（CA 才不用传私钥）
      Repeatable: false,        // 同指纹不重复上传；命中已有证书时返回 RepeatCertId
      Alias: process.env.CERT_ALIAS
    };
    fs.writeFileSync(process.env.REQ_FILE, JSON.stringify(body));
  '

  log "上传证书到腾讯云 SSL（ssl.UploadCertificate）"
  # 显式传 --api-version 2019-12-05：CLI 内置的 ServiceVersionMap 不一定覆盖 ssl，
  # 不传时可能报 version=undefined；显式传对它没有副作用。
  local upload_out new_cert_id
  upload_out="$("$TCB_BIN" api ssl UploadCertificate \
    --api-version 2019-12-05 \
    --body "$(cat "$REQ_FILE")" \
    --json -y)"
  new_cert_id="$(printf '%s' "$upload_out" | json_find_certificate_id)"
  log "腾讯云 SSL CertificateId = $new_cert_id"

  # --- 6. 幂等：已绑定同一张 → 直接结束 ---
  if [ "$new_cert_id" = "$bound_before" ]; then
    log "云端已绑定该证书，无需操作"
    [ -n "$last_cert_file" ] && printf '%s' "$new_cert_id" > "$last_cert_file"
    exit 0
  fi

  # --- 7. 让 CloudBase 域名使用新证书  →  ModifyHTTPServiceRoute ---
  log "重绑 CloudBase 域名 [${CERT_DOMAIN}] → CertId ${new_cert_id}"
  "$TCB_BIN" domains edit "$CERT_DOMAIN" \
    --certid "$new_cert_id" \
    -e "$CLOUDBASE_ENV_ID" \
    --json -y >/dev/null

  # --- 8. 校验 ---
  local verify_out bound_after
  verify_out="$("$TCB_BIN" domains ls -e "$CLOUDBASE_ENV_ID" --filter "Domain=${CERT_DOMAIN}" --json -y)"
  bound_after="$(printf '%s' "$verify_out" | json_find_certid "$CERT_DOMAIN" || true)"
  if [ "$bound_after" != "$new_cert_id" ]; then
    die "重绑后校验失败：期望 CertId=${new_cert_id}，实际=${bound_after:-<空>}"
  fi
  log "校验通过：${CERT_DOMAIN} 当前 CertId = ${bound_after}"

  # --- 9. 可选：删除上一张证书 ---
  local old_cert_id=""
  [ -n "$last_cert_file" ] && [ -f "$last_cert_file" ] && old_cert_id="$(cat "$last_cert_file")"
  if [ "$DELETE_OLD_CERT" = "1" ] && [ -n "$old_cert_id" ] && [ "$old_cert_id" != "$new_cert_id" ]; then
    # IsCheckResource 保持默认 false：默认不检查云资源关联。
    # 注意：如果旧证书还被别的云资源（CDN/CLB/WAF）引用，这里会把它删掉。确认无引用再开。
    log "删除旧证书 $old_cert_id"
    if "$TCB_BIN" api ssl DeleteCertificate \
      --api-version 2019-12-05 \
      --body "{\"CertificateId\":\"$old_cert_id\"}" --json -y >/dev/null; then
      log "旧证书已删除"
    else
      log "WARN: 旧证书删除失败（不影响本次部署，可事后在控制台清理）"
    fi
  fi

  [ -n "$last_cert_file" ] && printf '%s' "$new_cert_id" > "$last_cert_file"
  log "完成。"
}

# ---------------------------------------------------------------------------
# renew：强制续期一次 —— 续期成功会触发 --reloadcmd，也就是本脚本的 deploy
# ---------------------------------------------------------------------------
cmd_renew() {
  require_domain

  [ -x "$ACME" ] || die "找不到 acme.sh：$ACME（先跑 issue 子命令）"

  if [ -z "$ALIYUN_SECRET_ID_DNS" ] || [ -z "$ALIYUN_SECRET_KEY_DNS" ]; then
    log "WARN: 未设置 ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS；"
    log "      只有 acme.sh 已经保存过这对凭据（$ACME_HOME/account.conf 里的 SAVED_Ali_Key）才能续期成功"
  fi
  if [ -n "$ALIYUN_SECRET_ID_DNS" ];  then export Ali_Key="$ALIYUN_SECRET_ID_DNS";    fi
  if [ -n "$ALIYUN_SECRET_KEY_DNS" ]; then export Ali_Secret="$ALIYUN_SECRET_KEY_DNS"; fi

  log "强制续期 $CERT_DOMAIN（acme.sh --renew --force）；成功后 acme.sh 会执行 --reloadcmd → $SCRIPT_NAME deploy"
  "$ACME" --renew -d "$CERT_DOMAIN" --force

  log "续期流程结束。钩子日志：$LOG_FILE"
  log "如果日志里看不到 deploy 的输出，说明 --reloadcmd 没被触发，检查 $ACME_HOME/$CERT_DOMAIN/$CERT_DOMAIN.conf 里的 Le_ReloadCmd"
}

# ---------------------------------------------------------------------------
# 子命令分派
# ---------------------------------------------------------------------------
case "${1:-}" in
  issue)  cmd_issue ;;
  deploy) cmd_deploy ;;
  renew)  cmd_renew ;;
  ''|-h|--help|help)
    usage
    exit 1
    ;;
  *)
    printf '未知子命令：%s\n\n' "$1" >&2
    usage >&2
    exit 2
    ;;
esac
