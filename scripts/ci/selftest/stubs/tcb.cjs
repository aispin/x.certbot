#!/usr/bin/env node
/**
 * X Certbot - stub 演练用的假 CloudBase CLI（tcb）
 *
 * 用途: 只用于 scripts/ci/selftest/run.sh，不联网、不用真凭据，但复现 tcb 对我们有影响的语义:
 *   - `tcb login --apiKeyId ... --apiKey ... -y`
 *   - `tcb api ssl UploadCertificate --api-version 2019-12-05 --body <json> --json -y`
 *       -> Repeatable=false 且同指纹已存在时，只回 RepeatCertId（不留 CertificateId），
 *          用来验证上游脚本对「回退字段」的处理；
 *       -> 新证书返回稳定 ID（同内容 => 同 ID），用来验证幂等。
 *   - `tcb api ssl DeleteCertificate --body ...`
 *   - `tcb domains ls -e <env> --filter Domain=<d> --json -y`
 *   - `tcb domains edit <d> --certid <id> -e <env> --json -y`
 *   - `tcb domains add ...` -> 一律返回 RESOURCE_ALREADY_EXISTS（验证脚本用的是 edit 而不是 add）
 *   - `tcb routes add -e <env> --json -d <json>`
 *
 * 状态文件: $STUB_TCB_STATE（默认 /tmp/x-certbot-stub-tcb.json），演练脚本会直接读它做断言。
 * 调用日志: $STUB_TCB_CALL_LOG
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');

const STATE_FILE = process.env.STUB_TCB_STATE || path.join(os.tmpdir(), 'x-certbot-stub-tcb.json');
const CALL_LOG = process.env.STUB_TCB_CALL_LOG || '';

function logCall(argv) {
  if (!CALL_LOG) return;
  try {
    fs.appendFileSync(CALL_LOG, `tcb ${argv.join(' ')}\n`);
  } catch (e) { /* 演练用，忽略 */ }
}

function loadState() {
  if (!fs.existsSync(STATE_FILE)) {
    return { certs: {}, bound: {}, routes: [], deleted: [] };
  }
  try {
    const s = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    s.certs = s.certs || {};
    s.bound = s.bound || {};
    s.routes = s.routes || [];
    s.deleted = s.deleted || [];
    return s;
  } catch (e) {
    return { certs: {}, bound: {}, routes: [], deleted: [] };
  }
}

function saveState(state) {
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + '\n');
}

function flagValue(argv, ...names) {
  for (let i = 0; i < argv.length; i++) {
    if (names.includes(argv[i])) return argv[i + 1];
  }
  return undefined;
}

/** 腾讯云侧指纹: 这里用证书全文的 SHA-256 前 16 位做稳定代理 */
function fingerprint(pub) {
  return crypto.createHash('sha256').update(String(pub)).digest('hex').slice(0, 16);
}

function main() {
  const argv = process.argv.slice(2);
  logCall(argv);

  if (argv.length === 0 || argv[0] === '--version' || argv[0] === '-v') {
    process.stdout.write('stub-tcb 0.0.0\n');
    return;
  }

  const cmd = argv[0];
  const state = loadState();

  if (cmd === 'login') {
    process.stdout.write('[stub-tcb] 已登录（假）\n');
    return;
  }

  if (cmd === 'api') {
    const action = argv[2];
    const body = flagValue(argv, '--body');
    const apiVersion = flagValue(argv, '--api-version');
    let parsed = {};
    try {
      parsed = body ? JSON.parse(body) : {};
    } catch (e) {
      process.stderr.write('[stub-tcb] --body 不是合法 JSON\n');
      process.exit(1);
    }

    if (action === 'UploadCertificate') {
      // 检查脚本是否显式传了版本（不传在真实环境会报 version=undefined）
      if (!apiVersion) {
        process.stderr.write('[stub-tcb] ERROR: version=undefined（缺少 --api-version）\n');
        process.exit(255);
      }
      const pub = parsed.CertificatePublicKey || '';
      if (!pub || !parsed.CertificatePrivateKey) {
        process.stderr.write('[stub-tcb] ERROR: 缺少证书内容或私钥\n');
        process.exit(1);
      }
      const fp = fingerprint(pub);
      const existing = Object.entries(state.certs).find(([, v]) => v.fingerprint === fp);
      if (parsed.Repeatable === false && existing) {
        // 命中同指纹: 只回已存在的 ID（走 RepeatCertId 回退分支）
        out({ data: { CertificateId: '', RepeatCertId: existing[0], RequestId: 'stub-req' } });
        return;
      }
      const id = `SSL-${fp}`;
      state.certs[id] = {
        fingerprint: fp,
        alias: parsed.Alias || '',
        certificate_type: parsed.CertificateType || 'SVR',
      };
      saveState(state);
      out({ data: { CertificateId: id, RepeatCertId: '', RequestId: 'stub-req' } });
      return;
    }

    if (action === 'DeleteCertificate') {
      if (parsed.CertificateId) {
        delete state.certs[parsed.CertificateId];
        state.deleted.push(parsed.CertificateId);
        saveState(state);
      }
      out({ data: { RequestId: 'stub-req' } });
      return;
    }

    process.stderr.write(`[stub-tcb] 未实现的 api 动作: ssl.${action}\n`);
    process.exit(1);
  }

  if (cmd === 'domains') {
    const sub = argv[1];
    if (sub === 'ls') {
      const filter = flagValue(argv, '--filter') || '';
      const m = /^Domain=(.+)$/.exec(filter);
      const wanted = m ? m[1] : '';
      const domains = Object.entries(state.bound)
        .filter(([d]) => !wanted || d === wanted)
        .map(([d, certId]) => ({ Domain: d, CertId: certId }));
      out({ data: { Domains: domains } });
      return;
    }
    if (sub === 'edit') {
      const domain = argv[2];
      const certId = flagValue(argv, '--certid');
      if (!domain || !certId) {
        process.stderr.write('[stub-tcb] domains edit 需要 <域名> 与 --certid\n');
        process.exit(1);
      }
      state.bound[domain] = certId;
      saveState(state);
      out({ data: { Domain: domain, CertId: certId, RequestId: 'stub-req' } });
      return;
    }
    if (sub === 'add') {
      const domain = argv[2];
      if (state.bound[domain]) {
        process.stderr.write(
          '[stub-tcb] ERROR: RESOURCE_ALREADY_EXISTS（已绑定的域名必须用 domains edit）\n'
        );
        process.exit(1);
      }
      state.bound[domain] = flagValue(argv, '--certid') || '';
      saveState(state);
      out({ data: { Domain: domain, RequestId: 'stub-req' } });
      return;
    }
    process.stderr.write(`[stub-tcb] 未实现的 domains 子命令: ${sub}\n`);
    process.exit(1);
  }

  if (cmd === 'routes') {
    const sub = argv[1];
    if (sub === 'add') {
      // 注意: 这里只取 -d 的值。--json 是布尔开关，不能当成「带值参数」，
      // 否则会把紧随其后的 '-d' 当成它的值。
      const payload = flagValue(argv, '-d');
      state.routes.push({ at: new Date().toISOString(), payload });
      saveState(state);
      out({ data: { RequestId: 'stub-req', Routes: state.routes.length } });
      return;
    }
    process.stderr.write(`[stub-tcb] 未实现的 routes 子命令: ${sub}\n`);
    process.exit(1);
  }

  process.stderr.write(`[stub-tcb] 未实现的命令: ${argv.join(' ')}\n`);
  process.exit(1);
}

main();
