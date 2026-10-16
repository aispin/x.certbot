#!/usr/bin/env node
/**
 * X Certbot - CI 结果汇总（GitHub Step Summary）
 *
 * 用途: 把「哪个域名、哪个平台成功/失败」渲染成 Markdown 表格，写到 GitHub Actions 的
 *       Step Summary（$GITHUB_STEP_SUMMARY）。失败时也能一眼看出问题面，
 *       不用在几千行日志里翻。
 *
 * 用法:
 *   node scripts/ci/summary.cjs --plan /tmp/cert-sync/plan.json --run-dir /tmp/cert-sync
 *   （本机运行时直接打印到 stdout）
 */

'use strict';

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = { plan: '', runDir: '', mode: '' };
  for (let i = 2; i < argv.length; i++) {
    switch (argv[i]) {
      case '--plan': args.plan = argv[++i]; break;
      case '--run-dir': args.runDir = argv[++i]; break;
      case '--mode': args.mode = argv[++i]; break;
      default: throw new Error(`未知参数: ${argv[i]}`);
    }
  }
  return args;
}

function readJsonl(file) {
  if (!fs.existsSync(file)) return [];
  const out = [];
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      out.push(JSON.parse(trimmed));
    } catch (e) {
      out.push({ domain: '?', target: '?', status: 'unknown', raw: trimmed });
    }
  }
  return out;
}

function icon(status) {
  switch (status) {
    case 'success': return '✅';
    case 'ok': return '✅';
    case 'failed': return '❌';
    case 'error': return '❌';
    case 'installed': return '📦';
    case 'skipped': return '⏭️';
    default: return '❔';
  }
}

function esc(value) {
  return String(value === undefined || value === null ? '' : value).replace(/\|/g, '\\|');
}

function main() {
  const args = parseArgs(process.argv);
  if (!args.plan) throw new Error('缺少 --plan');
  if (!args.runDir) throw new Error('缺少 --run-dir');

  const plan = JSON.parse(fs.readFileSync(args.plan, 'utf8'));
  const domainResults = readJsonl(path.join(args.runDir, 'domain-results.jsonl'));
  const targetResults = readJsonl(path.join(args.runDir, 'results.jsonl'));

  const domainStatus = new Map(domainResults.map((r) => [r.domain, r]));
  const targetByDomain = new Map();
  for (const r of targetResults) {
    if (!targetByDomain.has(r.domain)) targetByDomain.set(r.domain, []);
    targetByDomain.get(r.domain).push(r);
  }

  const lines = [];
  lines.push('## 证书自动化结果');
  lines.push('');
  if (args.mode) lines.push(`运行模式：\`${esc(args.mode)}\``);
  lines.push(`执行计划：\`${esc(plan.config_path)}\`（${plan.domains.length} 个域名，生成于 ${esc(plan.generated_at)}）`);
  lines.push('');

  lines.push('| 域名 | DNS 验证 | 证书准备 | 同步目标 | 结果 |');
  lines.push('|---|---|---|---|---|');
  for (const d of plan.domains) {
    const res = domainStatus.get(d.name) || {};
    const targets = d.targets.length ? d.targets.map((t) => t.id).join('<br>') : '(不同步)';
    const statusIcon = icon(res.status);
    lines.push(
      `| \`${esc(d.name)}\`${d.wildcard ? '<br>*(含泛域名)*' : ''} | ${esc(d.dns_provider_label)} | ` +
      `${icon(res.issue)} ${esc(res.issue || '-')} | ${targets} | ${statusIcon} ${esc(res.status || '未执行')} |`
    );
  }
  lines.push('');

  // 每个目标的结果明细（失败时这一节最关键）
  const failedTargets = targetResults.filter((r) => r.status !== 'success');
  lines.push('### 同步目标明细');
  lines.push('');
  if (targetResults.length === 0) {
    lines.push('_本次没有任何同步目标被执行。_');
  } else {
    lines.push('| 域名 | 目标 | 说明 | 结果 |');
    lines.push('|---|---|---|---|');
    for (const r of targetResults) {
      lines.push(
        `| \`${esc(r.domain)}\` | \`${esc(r.target)}\` | ${esc(r.label)} | ` +
        `${icon(r.status)} ${esc(r.status)}${r.exit_code ? ` (exit ${r.exit_code})` : ''} |`
      );
    }
  }
  lines.push('');

  // 下一步提示
  if (failedTargets.length) {
    lines.push('### 需要处理');
    lines.push('');
    for (const r of failedTargets) {
      lines.push(`- \`${esc(r.domain)}\` -> \`${esc(r.target)}\`：本次未同步成功。重新运行 workflow 即可重试（同步是幂等的），不需要重新签发证书。`);
    }
    lines.push('');
  }

  lines.push('---');
  lines.push('');
  lines.push(
    '> 说明：acme.sh 的证书状态通过 `actions/cache` 在工作流之间保持；' +
    '每次运行都会把当前证书重新同步一遍，靠各目标自身的幂等性保证不产生重复资源。'
  );
  lines.push('');

  const markdown = lines.join('\n');
  const summaryFile = process.env.GITHUB_STEP_SUMMARY;
  if (summaryFile) {
    fs.appendFileSync(summaryFile, markdown);
  }
  process.stdout.write(markdown);
}

try {
  main();
} catch (e) {
  process.stderr.write(`[summary] 生成汇总失败: ${e.message}\n`);
  // 汇总失败不应让整个 job 变成失败
  process.exit(0);
}
