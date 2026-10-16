#!/bin/bash

# X Certbot - CI 自动化「零凭据」端到端演练
#
# 用途: 在没有真实阿里云/腾讯云凭据、不触碰任何真实接口的前提下，用 stub 把整条链路跑通，
#       并断言关键行为（幂等 / 失败定位 / 凭据映射 / 配置校验）。
#
# 这一套覆盖:
#   - 语法: 所有 shell 脚本 bash -n；所有 .cjs 文件 node --check
#   - YAML: deploy/domains.yml 与 .github/workflows/cert-sync.yml 可解析
#   - 签名: aliyun-api.cjs 与阿里云官方文档给出的签名向量逐字节一致
#   - 端到端: run-all.sh -> issue-cert.sh(假 acme.sh) -> sync-cert.sh -> 目标脚本
#             -> 假 tcb + 假阿里云端点
#   - 幂等: 跑第二遍不重复上传证书、不重复重绑域名
#   - 失败定位: 目标失败时退出码与 results.jsonl 能指明是哪个域名/哪个平台
#   - 负例: 缺凭据 / 配置非法 / 缺 CAS 证书 ID 时都会明确报错
#
# 不覆盖（无人能覆盖，需要真实凭据）:
#   - 真实的 acme.sh 向 Let's Encrypt 签发、真实的 DNS TXT 写入
#   - 真实的 tcb / 腾讯云 SSL / 阿里云 CAS、CDN、DCDN 接口
#
# 用法: bash scripts/ci/selftest/run.sh
# 依赖: bash + node + openssl（npm 可选，仅在缺 js-yaml 时用来拉依赖）

set -uo pipefail

SELFTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CI_DIR="$(cd "$SELFTEST_DIR/.." && pwd)"
REPO_ROOT="$(cd "$CI_DIR/../.." && pwd)"
STUBS="$SELFTEST_DIR/stubs"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/x-certbot-selftest.XXXXXX")"
STUB_PID=""
PASS=0
FAIL=0

cleanup() {
    if [ -n "$STUB_PID" ] && kill -0 "$STUB_PID" 2>/dev/null; then
        kill "$STUB_PID" 2>/dev/null || true
        wait "$STUB_PID" 2>/dev/null || true
    fi
    if [ "${KEEP_WORK:-0}" = "1" ]; then
        echo "[selftest] 保留工作目录: $WORK"
    else
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
section() { printf '\n\033[1;36m== %s ==\033[0m\n' "$1"; }

assert_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望 [$2]，实际 [$3]"; fi; }
assert_ne0() { if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1" "期望非零退出码，实际 0"; fi; }
assert_zero(){ if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1" "期望退出码 0，实际 $2"; fi; }

# 读取 stub 状态文件里的表达式；文件不存在时返回兜底值（避免演练里刷一堆 node 堆栈）
state_num() {
    # $1 = 状态文件, $2 = 以 s 为状态对象的 JS 表达式, $3 = 兜底值（默认 0）
    "$NODE_BIN" -e '
      const fs = require("fs");
      const file = process.argv[1], expr = process.argv[2], fallback = process.argv[3];
      let s;
      try { s = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { process.stdout.write(fallback); process.exit(0); }
      let v;
      try { v = eval(expr); } catch (e) { v = undefined; }
      process.stdout.write(v === undefined || v === null ? fallback : String(v));
    ' "$1" "$2" "${3:-0}"
}

json_count() {
    # $1 = 状态文件, $2 = 点号路径（指向数组）, $3 = 可选过滤表达式
    local dotted="$2" expr="${3:-}"
    state_num "$1" "(() => { let cur = s; for (const p of '${dotted}'.split('.')) cur = cur == null ? undefined : cur[p]; if (!Array.isArray(cur)) return 0; return ('${expr}' ? cur.filter((x) => eval('${expr}')) : cur).length; })()"
}

# ---------------------------------------------------------------------------
# 0. 环境准备
# ---------------------------------------------------------------------------
section "环境准备"
command -v openssl >/dev/null 2>&1 || { echo "需要 openssl"; exit 1; }
NODE_BIN="$(command -v node)" || { echo "需要 node"; exit 1; }
export NODE_BIN

# js-yaml（配置解析用）。CI 里由 workflow 安装；这里缺了就现装。
if ! node -e 'require("js-yaml")' >/dev/null 2>&1; then
    echo "  未找到 js-yaml，尝试安装到 $WORK/nm ..."
    npm install --no-save --no-audit --no-fund --prefix "$WORK/nm" js-yaml@4.1.0 >/dev/null 2>&1 \
        || { echo "  js-yaml 安装失败，请手动 npm install --no-save js-yaml@4.1.0"; exit 1; }
    export NODE_PATH="$WORK/nm/node_modules"
fi
echo "  工作目录: $WORK"

# 假的 HOME / acme.sh 布局（issue-cert.sh 要求 ACME_HOME 在 $HOME 下）
export HOME="$WORK/home"
mkdir -p "$HOME"
export ACME_HOME="$HOME/.acme.sh"
export ACME_BIN="$STUBS/acme.sh"
chmod +x "$STUBS/acme.sh" "$STUBS/tcb.cjs"

# 生成自签证书作为「acme.sh 签发结果」
GOLDEN="$WORK/golden"
mkdir -p "$GOLDEN"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$GOLDEN/privkey.pem" \
    -out "$GOLDEN/cert.pem" -days 30 -subj "/CN=example.com" >/dev/null 2>&1
# 演练里把 chain 简化成叶子证书的副本（真实场景是中间 CA 链）
cp "$GOLDEN/cert.pem" "$GOLDEN/chain.pem"
cat "$GOLDEN/cert.pem" "$GOLDEN/chain.pem" > "$GOLDEN/fullchain.pem"
export STUB_ACME_GOLDEN="$GOLDEN"
export STUB_ACME_CALL_LOG="$WORK/acme-calls.log"

# 假的 CloudBase CLI 状态
export STUB_TCB_STATE="$WORK/tcb-state.json"
export STUB_TCB_CALL_LOG="$WORK/tcb-calls.log"
export TCB_BIN="$STUBS/tcb.cjs"

# 假的阿里云端点
export STUB_ALIYUN_STATE="$WORK/aliyun-state.json"
export STUB_ALIYUN_PORT_FILE="$WORK/aliyun-port"
node "$STUBS/aliyun-server.cjs" > "$WORK/aliyun-server.log" 2>&1 &
STUB_PID=$!
for _ in $(seq 1 50); do
    [ -s "$STUB_ALIYUN_PORT_FILE" ] && break
    sleep 0.1
done
[ -s "$STUB_ALIYUN_PORT_FILE" ] || { echo "假阿里云端点启动失败:"; cat "$WORK/aliyun-server.log"; exit 1; }
STUB_PORT="$(cat "$STUB_ALIYUN_PORT_FILE")"
export ALIYUN_API_ENDPOINT="http://127.0.0.1:${STUB_PORT}"
echo "  假阿里云端点: $ALIYUN_API_ENDPOINT"

# 假凭据（不是真密钥，仅用于让校验通过）。
# 变量名刻意用 GitHub Environment `PROD` 里实际配置的那四个名字，
# 这样演练走的就是线上同一条路径（ID 走 vars / Key 走 secrets 的命名约定）。
export ALIYUN_SECRET_ID_DNS="testid"
export ALIYUN_SECRET_KEY_DNS="testsecret"
export CLOUDBASE_SECRET_ID="fake-secret-id"
export CLOUDBASE_SECRET_KEY="fake-secret-key"

# 演练用配置
cat > "$WORK/domains.yml" <<'YAML'
version: 1
defaults:
  server: letsencrypt
  key_length: 2048
  dns_propagation_seconds: 0
  email: selftest@example.com
sync:
  cloudbase:
    enabled: false
  aliyun:
    cas: { enabled: false }
    cdn: { enabled: false, domains: [] }
    dcdn: { enabled: false, domains: [] }
domains:
  - name: example.com
    dns_provider: aliyun
    wildcard: true
    sync:
      cloudbase:
        enabled: true
        env_id: env-selftest
        domains:
          - example.com
          - www.example.com
      aliyun:
        cas:
          enabled: true
          name_prefix: LE
        cdn:
          enabled: true
          domains: [example.com]
        dcdn:
          enabled: true
          domains: [example.com]
  - name: another-example.cn
    dns_provider: tencentcloud
    wildcard: false
YAML

mkdir -p "$WORK/run"
PLAN="$WORK/run/plan.json"

# ---------------------------------------------------------------------------
# 1. 语法检查
# ---------------------------------------------------------------------------
section "语法检查"
SYNTAX_FAIL=0
while IFS= read -r f; do
    if ! bash -n "$f" 2>"$WORK/syntax.err"; then
        bad "bash -n $f" "$(cat "$WORK/syntax.err")"
        SYNTAX_FAIL=1
    fi
done < <(find "$CI_DIR" -name '*.sh' -type f | sort)
while IFS= read -r f; do
    if ! "$NODE_BIN" --check "$f" 2>"$WORK/syntax.err"; then
        bad "node --check $f" "$(cat "$WORK/syntax.err")"
        SYNTAX_FAIL=1
    fi
done < <(find "$CI_DIR" -name '*.cjs' -type f | sort)
[ "$SYNTAX_FAIL" -eq 0 ] && ok "所有 shell / JS 文件语法通过"

# ---------------------------------------------------------------------------
# 2. YAML 可解析性
# ---------------------------------------------------------------------------
section "YAML 校验"
if "$NODE_BIN" -e '
  const fs=require("fs"), yaml=require("js-yaml");
  for (const f of process.argv.slice(1)) yaml.load(fs.readFileSync(f,"utf8"));
' "$REPO_ROOT/deploy/domains.yml" "$REPO_ROOT/.github/workflows/cert-sync.yml" >/dev/null 2>"$WORK/yaml.err"; then
    ok "deploy/domains.yml 与 .github/workflows/cert-sync.yml 都是合法 YAML"
else
    bad "YAML 解析" "$(cat "$WORK/yaml.err")"
fi

# ---------------------------------------------------------------------------
# 3. 阿里云签名实现 vs 官方文档向量
# ---------------------------------------------------------------------------
section "阿里云签名实现自检"
"$NODE_BIN" "$CI_DIR/lib/aliyun-api.cjs" --selftest > "$WORK/selftest-sign.log" 2>&1
assert_zero "签名与官方文档向量一致" $?
grep -q 'Signature' "$WORK/selftest-sign.log" && ok "自检输出包含 Signature 校验项"

# ---------------------------------------------------------------------------
# 4. 配置校验：合法配置 -> 计划
# ---------------------------------------------------------------------------
section "配置解析"
"$NODE_BIN" "$CI_DIR/lib/config.cjs" --config "$WORK/domains.yml" --out "$PLAN" >/dev/null 2>"$WORK/config.err"
assert_zero "合法配置解析成功" $?
assert_eq "计划里域名数量" "2" "$(json_count "$PLAN" "domains")"
assert_eq "example.com 的目标数" "4" \
    "$("$NODE_BIN" -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(p.domains.find(x=>x.name==="example.com").targets.length))' "$PLAN")"
assert_eq "example.com 含泛域名" "true" \
    "$("$NODE_BIN" -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String(p.domains.find(x=>x.name==="example.com").wildcard))' "$PLAN")"

# 中文域名 -> punycode
cat > "$WORK/idn.yml" <<'YAML'
version: 1
defaults:
  email: ops@example.com
domains:
  - name: 例子.测试
    dns_provider: aliyun
YAML
IDN_NAME="$("$NODE_BIN" "$CI_DIR/lib/config.cjs" --config "$WORK/idn.yml" 2>/dev/null | "$NODE_BIN" -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).domains[0].name))')"
case "$IDN_NAME" in
    xn--*) ok "中文域名已转 punycode: $IDN_NAME" ;;
    *) bad "中文域名 punycode 转换" "得到 $IDN_NAME" ;;
esac

# ACME 邮箱: 只从配置文件读（不再有 ACME_EMAIL Secret）
assert_eq "计划里的 ACME 邮箱来自 deploy/domains.yml" "selftest@example.com" \
    "$("$NODE_BIN" -e 'const p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(p.domains[0].email)' "$PLAN")"

cat > "$WORK/no-email.yml" <<'YAML'
version: 1
domains:
  - name: example.com
    dns_provider: aliyun
YAML
"$NODE_BIN" "$CI_DIR/lib/config.cjs" --config "$WORK/no-email.yml" >/dev/null 2>"$WORK/no-email.err"
assert_ne0 "没填邮箱时按预期失败" $?
grep -q 'email 还没有填写' "$WORK/no-email.err" \
    && ok "错误信息指出要改 deploy/domains.yml 的 email" \
    || bad "错误信息指出要改 deploy/domains.yml 的 email" "$(cat "$WORK/no-email.err")"

# 负例：启用 cdn 但没启用 cas
cat > "$WORK/bad.yml" <<'YAML'
version: 1
defaults:
  email: ops@example.com
domains:
  - name: example.com
    dns_provider: aliyun
    sync:
      aliyun:
        cdn:
          enabled: true
          domains: [example.com]
YAML
"$NODE_BIN" "$CI_DIR/lib/config.cjs" --config "$WORK/bad.yml" >/dev/null 2>"$WORK/bad.err"
assert_ne0 "配置非法（cdn 未启用 cas）时按预期失败" $?
grep -q '必须同时启用 cas' "$WORK/bad.err" && ok "错误信息指出原因" || bad "错误信息指出原因" "$(cat "$WORK/bad.err")"

# 负例：dns_provider 非法
cat > "$WORK/bad2.yml" <<'YAML'
version: 1
defaults:
  email: ops@example.com
domains:
  - name: example.com
    dns_provider: cloudflare
YAML
"$NODE_BIN" "$CI_DIR/lib/config.cjs" --config "$WORK/bad2.yml" >/dev/null 2>"$WORK/bad2.err"
assert_ne0 "dns_provider 非法时按预期失败" $?

# ---------------------------------------------------------------------------
# 5. 凭据预检（正例 / 负例）
# ---------------------------------------------------------------------------
section "凭据预检"
bash "$CI_DIR/preflight.sh" --plan "$PLAN" >/dev/null 2>&1
assert_zero "凭据齐全时预检通过" $?

( unset ALIYUN_SECRET_ID_DNS ALIYUN_SECRET_KEY_DNS ALIYUN_SECRET_ID_CERT ALIYUN_SECRET_KEY_CERT
  bash "$CI_DIR/preflight.sh" --plan "$PLAN" ) >/dev/null 2>"$WORK/preflight.err"
assert_ne0 "缺阿里云凭据时预检失败" $?
grep -q 'ALIYUN_SECRET_ID_DNS' "$WORK/preflight.err" && ok "预检信息列出缺失的变量名" || bad "预检信息列出缺失的变量名"

# ---------------------------------------------------------------------------
# 5.1 凭据名映射 / environment 声明（防止回退到旧名，这是本次交付最容易配错的地方）
# ---------------------------------------------------------------------------
section "凭据名与环境声明校验"
WF="$REPO_ROOT/.github/workflows/cert-sync.yml"

if grep -Eq '^[[:space:]]*environment:[[:space:]]*PROD[[:space:]]*$' "$WF"; then
    ok "workflow 的 job 声明了 environment: PROD"
else
    bad "workflow 的 job 声明了 environment: PROD"
fi

# Environment 下的四个配置项: ID 走 vars，Key 走 secrets
for spec in \
    'vars.ALIYUN_SECRET_ID_DNS' \
    'secrets.ALIYUN_SECRET_KEY_DNS' \
    'vars.CLOUDBASE_SECRET_ID' \
    'secrets.CLOUDBASE_SECRET_KEY'
do
    if grep -qF "\${{ $spec }}" "$WF"; then
        ok "workflow 注入了 $spec"
    else
        bad "workflow 注入了 $spec"
    fi
done

# 旧凭据名（含 ACME_EMAIL）不允许再出现在 workflow / 脚本里
LEGACY_RE='ALIYUN_DNS_ACCESS_KEY_ID|ALIYUN_DNS_ACCESS_KEY_SECRET|ALIYUN_ACCESS_KEY_ID|ALIYUN_ACCESS_KEY_SECRET|ALIYUN_CERT_ACCESS_KEY_ID|ALIYUN_CERT_ACCESS_KEY_SECRET|TENCENTCLOUD_SECRETID|TENCENTCLOUD_SECRETKEY|TENCENTCLOUD_SECRET_ID|TENCENTCLOUD_SECRET_KEY|TENCENT_DNS_SECRET_ID|TENCENT_DNS_SECRET_KEY|ACME_EMAIL'
LEGACY_HITS="$(grep -Ern "$LEGACY_RE" "$WF" "$CI_DIR"/*.sh "$CI_DIR"/lib/*.cjs "$CI_DIR"/targets/*.sh "$CI_DIR"/selftest/stubs/* 2>/dev/null | head -5 || true)"
if [ -z "$LEGACY_HITS" ]; then
    ok "旧凭据名已全部清除（只剩四个新名字）"
else
    bad "旧凭据名已全部清除（只剩四个新名字）" "$LEGACY_HITS"
fi

# ---------------------------------------------------------------------------
# 6. 端到端：第一次运行（签发 + 同步）
# ---------------------------------------------------------------------------
section "端到端演练 1/2：首次签发 + 同步"
RUN_DIR="$WORK/run"
bash "$CI_DIR/run-all.sh" --plan "$PLAN" --run-dir "$RUN_DIR" --mode full > "$WORK/run1.log" 2>&1
assert_zero "run-all.sh 首次运行成功" $?

BOUND_COUNT="$(state_num "$STUB_TCB_STATE" 'Object.keys(s.bound).length')"
assert_eq "CloudBase 已绑定域名数" "2" "$BOUND_COUNT"
assert_eq "CAS 里上传的证书数" "1" "$(state_num "$STUB_ALIYUN_STATE" 's.certs.length')"
assert_eq "CDN 部署次数" "1" "$(json_count "$STUB_ALIYUN_STATE" "deployments" 'x.product === "cdn"')"
assert_eq "DCDN 部署次数" "1" "$(json_count "$STUB_ALIYUN_STATE" "deployments" 'x.product === "dcdn"')"
assert_eq "腾讯云 SSL 上传次数" "1" "$(json_count "$STUB_ALIYUN_STATE" "calls" 'x.action === "UploadUserCertificate"')"
assert_eq "domains edit 调用次数" "2" "$(grep -c 'domains edit' "$STUB_TCB_CALL_LOG" || true)"
assert_eq "结果记录里无失败" "0" "$(grep -c '"status":"failed"' "$RUN_DIR/domain-results.jsonl" || true)"

# 第二个域名没有同步目标，不应产生任何云调用
grep -q '没有启用任何同步目标' "$WORK/run1.log" && ok "无同步目标的域名被正确跳过" || bad "无同步目标的域名被正确跳过"

# ---------------------------------------------------------------------------
# 7. 端到端：第二次运行（幂等）
# ---------------------------------------------------------------------------
section "端到端演练 2/2：重复运行（幂等）"
bash "$CI_DIR/run-all.sh" --plan "$PLAN" --run-dir "$RUN_DIR" --mode full > "$WORK/run2.log" 2>&1
assert_zero "run-all.sh 第二次运行成功" $?

assert_eq "CAS 证书数仍然为 1（没重复上传）" "1" "$(state_num "$STUB_ALIYUN_STATE" 's.certs.length')"
assert_eq "CAS 上传接口累计只调了 1 次" "1" "$(json_count "$STUB_ALIYUN_STATE" "calls" 'x.action === "UploadUserCertificate"')"
assert_eq "domains edit 累计仍为 2（没重复重绑）" "2" "$(grep -c 'domains edit' "$STUB_TCB_CALL_LOG" || true)"
grep -q '云端已绑定该证书，无需重绑' "$WORK/run2.log" && ok "CloudBase 幂等分支被命中" || bad "CloudBase 幂等分支被命中"
grep -q 'CAS 里已存在该证书' "$WORK/run2.log" && ok "CAS 幂等分支被命中" || bad "CAS 幂等分支被命中"
grep -q '尚未到续期窗口' "$WORK/run2.log" && ok "acme.sh 退出码 2（跳过续期）被正确识别" || bad "acme.sh 退出码 2（跳过续期）被正确识别"

# ---------------------------------------------------------------------------
# 8. 失败定位：让目标脚本失败，确认退出码与结果记录能指明位置
# ---------------------------------------------------------------------------
section "失败定位"
BROKEN_RUN="$WORK/run-broken"
ALIYUN_API_ENDPOINT="http://127.0.0.1:1" \
    bash "$CI_DIR/run-all.sh" --plan "$PLAN" --run-dir "$BROKEN_RUN" --mode sync-only > "$WORK/run-broken.log" 2>&1
assert_ne0 "某个平台不可达时 run-all.sh 返回非零" $?
grep -q '"status":"failed"' "$BROKEN_RUN/results.jsonl" && ok "results.jsonl 记录了失败目标" || bad "results.jsonl 记录了失败目标"
grep -q '"target":"aliyun.cas"' "$BROKEN_RUN/results.jsonl" && ok "失败记录指明了具体目标 id" || bad "失败记录指明了具体目标 id"
grep -q 'aliyun.cas 失败' "$WORK/run-broken.log" && ok "日志明确指出失败目标" || bad "日志明确指出失败目标"

# ---------------------------------------------------------------------------
# 9. 目标脚本负例：缺少 CAS 证书 ID
# ---------------------------------------------------------------------------
section "目标脚本负例"
cat > "$WORK/cdn-only.json" <<'JSON'
{"domains":["example.com"]}
JSON
( unset ALIYUN_CAS_CERT_ID
  TARGET=aliyun.cdn TARGET_CONFIG="$WORK/cdn-only.json" CERT_DOMAIN=example.com \
  bash "$CI_DIR/targets/aliyun-cdn.sh" ) >/dev/null 2>"$WORK/cdn.err"
assert_ne0 "CDN 目标缺少 ALIYUN_CAS_CERT_ID 时失败" $?
grep -q 'aliyun.cas' "$WORK/cdn.err" && ok "错误信息指向缺失的上游目标" || bad "错误信息指向缺失的上游目标"

# ---------------------------------------------------------------------------
# 10. workflow dry-run 演练
# ---------------------------------------------------------------------------
section "DRY-RUN 演练"
DRY_RUN_DIR="$WORK/run-dry"
# 预置一份上一轮产出的证书，模拟「本地已有证书」的状态，
# 这样 DRY-RUN 也能把同步目标的参数拼装走一遍（但不会发出任何云请求）。
mkdir -p "$DRY_RUN_DIR/certs/example.com"
cp "$RUN_DIR/certs/example.com/fullchain.pem" "$DRY_RUN_DIR/certs/example.com/fullchain.pem"
cp "$RUN_DIR/certs/example.com/privkey.pem"   "$DRY_RUN_DIR/certs/example.com/privkey.pem"
bash "$CI_DIR/run-all.sh" --plan "$PLAN" --run-dir "$DRY_RUN_DIR" --mode full --dry-run > "$WORK/run-dry.log" 2>&1
assert_zero "DRY-RUN 运行成功" $?
assert_eq "DRY-RUN 不产生新的 CDN 部署" "2" "$(json_count "$STUB_ALIYUN_STATE" "deployments" 'x.product === "cdn"')"
grep -q 'DRY-RUN: 跳过 SetCdnDomainSSLCertificate' "$WORK/run-dry.log" \
    && ok "DRY-RUN 下 CDN 目标只演练不调用" \
    || bad "DRY-RUN 下 CDN 目标只演练不调用"
grep -q 'DRY-RUN: 跳过 tcb login' "$WORK/run-dry.log" \
    && ok "DRY-RUN 下 CloudBase 目标只演练不调用" \
    || bad "DRY-RUN 下 CloudBase 目标只演练不调用"

# ---------------------------------------------------------------------------
# 11. 汇总输出
# ---------------------------------------------------------------------------
section "Step Summary 渲染"
"$NODE_BIN" "$CI_DIR/summary.cjs" --plan "$PLAN" --run-dir "$RUN_DIR" --mode full > "$WORK/summary.md" 2>&1
assert_zero "summary.cjs 渲染成功" $?
grep -q '| 域名 |' "$WORK/summary.md" && ok "汇总包含域名表格" || bad "汇总包含域名表格"
grep -q 'cloudbase.domain' "$WORK/summary.md" && ok "汇总包含同步目标明细" || bad "汇总包含同步目标明细"

# ---------------------------------------------------------------------------
# 结果
# ---------------------------------------------------------------------------
printf '\n\033[1m==== 演练结果: %s 通过, %s 失败 ====\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf '日志目录: %s（用 KEEP_WORK=1 重跑可保留）\n' "$WORK"
    exit 1
fi
printf '全部通过。\n'
