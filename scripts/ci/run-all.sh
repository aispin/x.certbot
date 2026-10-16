#!/bin/bash

# X Certbot - CI 主循环（逐个域名：签发/续期 -> 同步）
#
# 用途: 把「按域名串行处理、单域名失败不影响其它域名、最后统一给出失败明细」这套编排
#       从 workflow YAML 里搬到脚本里，这样逻辑可以本机跑、可以 bash -n、可以 stub 演练。
#
# 为什么串行而不是矩阵并行:
#   acme.sh 的状态（~/.acme.sh）是多个域名共享的同一份目录，并行 job 抢同一份缓存
#   会互相覆盖。串行还顺带让日志按域名聚合成一个 group，失败定位更直接。
#
# 用法:
#   scripts/ci/run-all.sh --plan /tmp/cert-sync/plan.json --run-dir /tmp/cert-sync \
#       [--mode full|sync-only|issue-only] [--only-targets a,b] [--force] [--dry-run]
#
# 输出: $RUN_DIR/results.jsonl（由 sync-cert.sh 追加）、$RUN_DIR/domain-results.jsonl（本脚本追加）
# 退出码: 0 全部成功；1 有任一域名失败

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/console_compat.sh
source "$SCRIPT_DIR/lib/console_compat.sh"

PLAN=""
RUN_DIR=""
MODE="full"
ONLY_TARGETS=""
FORCE="false"
DRY_RUN="${DRY_RUN:-false}"

while [ $# -gt 0 ]; do
    case "$1" in
        --plan)         PLAN="$2"; shift 2 ;;
        --run-dir)      RUN_DIR="$2"; shift 2 ;;
        --mode)         MODE="$2"; shift 2 ;;
        --only-targets) ONLY_TARGETS="$2"; shift 2 ;;
        --force)        FORCE="true"; shift ;;
        --dry-run)      DRY_RUN="true"; shift ;;
        -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
        *) print_error "未知参数: $1"; exit 1 ;;
    esac
done

[ -n "$PLAN" ] || { print_error "缺少 --plan"; exit 1; }
[ -n "$RUN_DIR" ] || { print_error "缺少 --run-dir"; exit 1; }
case "$MODE" in
    full|sync-only|issue-only) : ;;
    *) print_error "--mode 只支持 full / sync-only / issue-only，当前值: $MODE"; exit 1 ;;
esac

NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
[ -n "$NODE_BIN" ] || { print_error "找不到 node"; exit 1; }

mkdir -p "$RUN_DIR"
DOMAIN_RESULTS="$RUN_DIR/domain-results.jsonl"
: > "$DOMAIN_RESULTS"

# 可替换的子脚本路径: 自带 stub 演练脚本时用它把 acme.sh 那一步换掉
ISSUE_SCRIPT="${ISSUE_SCRIPT:-$SCRIPT_DIR/issue-cert.sh}"
SYNC_SCRIPT="${SYNC_SCRIPT:-$SCRIPT_DIR/sync-cert.sh}"
[ -f "$ISSUE_SCRIPT" ] || { print_error "找不到签发脚本: $ISSUE_SCRIPT"; exit 1; }
[ -f "$SYNC_SCRIPT" ] || { print_error "找不到同步脚本: $SYNC_SCRIPT"; exit 1; }

# 读取某个域名的字段（不依赖 jq）
plan_field() {
    "$NODE_BIN" -e '
      const fs = require("fs");
      const plan = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const d = plan.domains.find((x) => x.name === process.argv[2]);
      if (!d) process.exit(0);
      const v = d[process.argv[3]];
      if (v === undefined || v === null) process.exit(0);
      process.stdout.write(typeof v === "object" ? JSON.stringify(v) : String(v));
    ' "$PLAN" "$1" "$2"
}

group_start() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::group::%s\n' "$1"
    else
        print_header "$1"
    fi
}
group_end() {
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
        printf '::endgroup::\n'
    fi
}

DOMAIN_COUNT="$("$NODE_BIN" -e '
  const fs = require("fs");
  const plan = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(plan.domains.length));
' "$PLAN")"

print_header "证书自动化：$DOMAIN_COUNT 个域名（模式: $MODE）"

FAILED_DOMAINS=0
INDEX=0

"$NODE_BIN" -e '
  const fs = require("fs");
  const plan = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  plan.domains.forEach((d) => process.stdout.write(d.name + "\n"));
' "$PLAN" > "$RUN_DIR/domains.txt"

while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    INDEX=$((INDEX + 1))
    group_start "[$INDEX/$DOMAIN_COUNT] 域名 $domain"

    cert_dir="$RUN_DIR/certs/$domain"
    domain_failed=0
    issue_status="skipped"
    sync_status="skipped"

    # ---------------- 申请 / 续期 ----------------
    if [ "$MODE" = "sync-only" ]; then
        print_info "sync-only 模式：跳过 ACME 签发/续期，只用本地已有证书刷新稳定路径"
        issue_args=(--install-only)
    else
        issue_args=()
        [ "$FORCE" = "true" ] && issue_args+=(--force)
    fi

    issue_args+=(
        --domain "$domain"
        --dns-provider "$(plan_field "$domain" dns_provider)"
        --out-dir "$cert_dir"
        --email "$(plan_field "$domain" email)"
        --key-length "$(plan_field "$domain" key_length)"
        --server "$(plan_field "$domain" server)"
        --dns-wait "$(plan_field "$domain" dns_propagation_seconds)"
    )
    [ "$(plan_field "$domain" wildcard)" = "true" ] && issue_args+=(--wildcard)
    [ "$DRY_RUN" = "true" ] && issue_args+=(--dry-run)

    if bash "$ISSUE_SCRIPT" "${issue_args[@]}"; then
        issue_status="$([ "$MODE" = "sync-only" ] && echo installed || echo ok)"
    else
        issue_status="failed"
        domain_failed=1
        print_error "域名 $domain 的证书准备失败，跳过它的同步步骤"
    fi

    # ---------------- 同步 ----------------
    if [ "$MODE" = "issue-only" ]; then
        print_info "issue-only 模式：不同步到任何云平台"
    elif [ "$domain_failed" -ne 0 ]; then
        print_warning "证书未就绪，跳过同步"
    elif [ "$DRY_RUN" = "true" ] && [ ! -s "$cert_dir/fullchain.pem" ]; then
        # DRY-RUN 不会真的产出证书，本地又没有历史证书时没法构造同步请求，直接说明清楚
        print_warning "DRY-RUN: 本地没有 $domain 的证书，跳过同步目标的参数演练"
    else
        sync_args=(--plan "$PLAN" --domain "$domain" --cert-dir "$cert_dir" --run-dir "$RUN_DIR")
        [ -n "$ONLY_TARGETS" ] && sync_args+=(--only "$ONLY_TARGETS")
        [ "$DRY_RUN" = "true" ] && sync_args+=(--dry-run)

        if bash "$SYNC_SCRIPT" "${sync_args[@]}"; then
            sync_status="ok"
        else
            sync_status="failed"
            domain_failed=1
        fi
    fi

    if [ "$domain_failed" -eq 0 ]; then
        print_success "域名 $domain 处理完成"
        printf '{"domain":"%s","status":"success","issue":"%s","sync":"%s"}\n' \
            "$domain" "$issue_status" "$sync_status" >> "$DOMAIN_RESULTS"
    else
        print_error "域名 $domain 处理失败"
        printf '{"domain":"%s","status":"failed","issue":"%s","sync":"%s"}\n' \
            "$domain" "$issue_status" "$sync_status" >> "$DOMAIN_RESULTS"
        FAILED_DOMAINS=$((FAILED_DOMAINS + 1))
        if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
            # 让失败信息直接出现在 workflow 的错误注解里
            printf '::error::域名 %s 处理失败（issue=%s, sync=%s）\n' "$domain" "$issue_status" "$sync_status"
        fi
    fi

    group_end
done < "$RUN_DIR/domains.txt"

if [ "$FAILED_DOMAINS" -ne 0 ]; then
    print_error "$FAILED_DOMAINS/$DOMAIN_COUNT 个域名处理失败，请查看上面的分组日志与 Step Summary"
    exit 1
fi

print_success "全部 $DOMAIN_COUNT 个域名处理完成"
