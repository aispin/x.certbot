#!/usr/bin/env node
/**
 * X Certbot - 阿里云 OpenAPI 调用器（RPC 风格 V1 签名）
 *
 * 为什么自己写签名而不是用 aliyun CLI:
 *   本仓库的 CI 只保证有 bash + node（见 Dockerfile 与 docs/07-*.md 的说明）。
 *   `aliyun` CLI 是 Python 写的，装它要拖一整套 Python 依赖；
 *   RPC V1 签名本身只是 HMAC-SHA1 + Base64，用 node 内置 crypto 即可，零第三方依赖。
 *
 * 签名算法依据（官方文档《V2版本RPC风格请求体&签名机制》）:
 *   https://www.alibabacloud.com/help/zh/sdk/product-overview/rpc-mechanism
 *   1. 公共参数 + 业务参数按参数名 ASCII 升序排序
 *   2. RFC3986 编码后以 & 连接 -> CanonicalizedQueryString
 *   3. StringToSign = HTTPMethod + "&" + percentEncode("/") + "&" + percentEncode(CanonicalizedQueryString)
 *   4. Signature = Base64(HMAC-SHA1(AccessKeySecret + "&", StringToSign))
 *   文档同时给出了一个官方向量（testid/testsecret -> 9NaGiOspFP5UPcwX8Iwt2YJXXuk=），
 *   本文件用 --selftest 复现它，用来证明签名实现正确。
 *
 * 安全: 调用参数里会包含证书私钥。本脚本 **永远不打印请求体/私钥内容**，
 *       出错时只回显阿里云返回的 Code / Message。
 *
 * 用法:
 *   node aliyun-api.js --product cas --version 2020-04-07 --action UploadUserCertificate \
 *        --param Name=LE-example.com-ab12cd34ef56 \
 *        --param Cert=@/tmp/fullchain.pem --param Key=@/tmp/privkey.pem \
 *        --extract CertId
 *
 *   # 只算签名不发请求
 *   node aliyun-api.js ... --dry-run
 *   # 校验签名实现是否与阿里云官方文档的向量一致
 *   node aliyun-api.js --selftest
 *
 * 环境变量:
 *   ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT  阿里云【证书同步】凭据（优先使用）
 *   ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS    未配置上面那对时【回退】到这一对（DNS 凭据）
 *                                                   （必需，除非 --selftest/--dry-run）
 *   ALIYUN_API_ENDPOINT                              强制覆盖 endpoint（用于 stub 演练）
 *   ALIYUN_API_TRANSPORT                             form（默认）| query
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const https = require('https');
const querystring = require('querystring');

const DEFAULT_TIMEOUT_MS = 30000;

class ApiError extends Error {}

// ---------------------------------------------------------------------------
// 签名实现
// ---------------------------------------------------------------------------

/** RFC3986 编码：与官方文档一致（+ -> %20，* -> %2A，%7E -> ~） */
function percentEncode(value) {
  return encodeURIComponent(String(value))
    .replace(/\+/g, '%20')
    .replace(/\*/g, '%2A')
    .replace(/%7E/g, '~');
}

/** 构造规范化请求字符串（不含 Signature 参数，按 key ASCII 升序） */
function canonicalizedQueryString(params) {
  return Object.keys(params)
    .filter((key) => key !== 'Signature')
    .sort()
    .map((key) => `${percentEncode(key)}=${percentEncode(params[key])}`)
    .join('&');
}

/** 计算签名 */
function sign(httpMethod, params, accessKeySecret) {
  const canonical = canonicalizedQueryString(params);
  const stringToSign = `${httpMethod}&${percentEncode('/')}&${percentEncode(canonical)}`;
  return {
    canonical,
    stringToSign,
    signature: crypto
      .createHmac('sha1', `${accessKeySecret}&`)
      .update(stringToSign, 'utf8')
      .digest('base64'),
  };
}

/** 用官方文档给出的向量自检签名实现 */
function selftest() {
  const params = {
    AccessKeyId: 'testid',
    Action: 'DescribeDedicatedHosts',
    Format: 'JSON',
    RegionId: 'cn-beijing',
    SignatureMethod: 'HMAC-SHA1',
    SignatureNonce: 'edb2b34af0af9a6d14deaf7c1a5315eb',
    SignatureVersion: '1.0',
    Timestamp: '2023-03-13T08:34:30Z',
    Version: '2014-05-26',
  };
  const expectedCanonical =
    'AccessKeyId=testid&Action=DescribeDedicatedHosts&Format=JSON&RegionId=cn-beijing' +
    '&SignatureMethod=HMAC-SHA1&SignatureNonce=edb2b34af0af9a6d14deaf7c1a5315eb' +
    '&SignatureVersion=1.0&Timestamp=2023-03-13T08%3A34%3A30Z&Version=2014-05-26';
  const expectedStringToSign =
    'GET&%2F&AccessKeyId%3Dtestid%26Action%3DDescribeDedicatedHosts%26Format%3DJSON' +
    '%26RegionId%3Dcn-beijing%26SignatureMethod%3DHMAC-SHA1' +
    '%26SignatureNonce%3Dedb2b34af0af9a6d14deaf7c1a5315eb%26SignatureVersion%3D1.0' +
    '%26Timestamp%3D2023-03-13T08%253A34%253A30Z%26Version%3D2014-05-26';
  const expectedSignature = '9NaGiOspFP5UPcwX8Iwt2YJXXuk=';

  const got = sign('GET', params, 'testsecret');
  const checks = [
    ['CanonicalizedQueryString', got.canonical, expectedCanonical],
    ['StringToSign', got.stringToSign, expectedStringToSign],
    ['Signature', got.signature, expectedSignature],
  ];
  let ok = true;
  for (const [name, actual, want] of checks) {
    if (actual === want) {
      process.stdout.write(`[selftest] OK   ${name}\n`);
    } else {
      ok = false;
      process.stdout.write(`[selftest] FAIL ${name}\n  期望: ${want}\n  实际: ${actual}\n`);
    }
  }
  process.stdout.write(ok ? '[selftest] 签名实现与阿里云官方文档向量一致\n' : '[selftest] 签名实现不一致\n');
  process.exit(ok ? 0 : 1);
}

// ---------------------------------------------------------------------------
// 参数解析
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const args = {
    product: '',
    version: '',
    action: '',
    endpoint: '',
    method: 'POST',
    transport: process.env.ALIYUN_API_TRANSPORT || 'form',
    extract: '',
    params: [],
    dryRun: false,
    selftest: false,
    timeout: DEFAULT_TIMEOUT_MS,
  };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--product': args.product = argv[++i]; break;
      case '--version': args.version = argv[++i]; break;
      case '--action': args.action = argv[++i]; break;
      case '--endpoint': args.endpoint = argv[++i]; break;
      case '--method': args.method = argv[++i]; break;
      case '--transport': args.transport = argv[++i]; break;
      case '--param': args.params.push(argv[++i]); break;
      case '--extract': args.extract = argv[++i]; break;
      case '--timeout': args.timeout = Number(argv[++i]); break;
      case '--dry-run': args.dryRun = true; break;
      case '--selftest': args.selftest = true; break;
      case '--help':
      case '-h':
        process.stdout.write(fs.readFileSync(__filename, 'utf8').split('*/')[0].replace(/^\/\*\*?/, ''));
        process.exit(0);
        break;
      default:
        throw new ApiError(`未知参数: ${arg}`);
    }
  }
  if (!['form', 'query'].includes(args.transport)) {
    throw new ApiError(`--transport 只能是 form 或 query，当前值: ${args.transport}`);
  }
  return args;
}

/** --param Key=@file 表示把文件内容当作参数值 */
function parseParam(spec) {
  const eq = spec.indexOf('=');
  if (eq <= 0) throw new ApiError(`--param 需要 Key=Value 形式，当前值: ${spec}`);
  const key = spec.slice(0, eq);
  let value = spec.slice(eq + 1);
  if (value.startsWith('@')) {
    const file = value.slice(1);
    if (!fs.existsSync(file)) throw new ApiError(`--param ${key} 引用的文件不存在: ${file}`);
    value = fs.readFileSync(file, 'utf8');
  }
  return [key, value];
}

/** 从响应里按点号路径取值（只支持普通字段，不处理数组展开） */
function extractPath(obj, dotted) {
  let cur = obj;
  for (const part of dotted.split('.')) {
    if (cur === null || cur === undefined || typeof cur !== 'object') return undefined;
    cur = cur[part];
  }
  return cur;
}

// ---------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------
function requestJson({ endpoint, method, path: reqPath, body, headers, timeout, protocol, port }) {
  const transport = protocol === 'http:' ? require('http') : https;
  return new Promise((resolve, reject) => {
    const req = transport.request(
      { host: endpoint, port, method, path: reqPath, headers, timeout },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          const raw = Buffer.concat(chunks).toString('utf8');
          resolve({ statusCode: res.statusCode, raw });
        });
      }
    );
    req.on('timeout', () => {
      req.destroy(new ApiError(`请求超时（${timeout}ms）`));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

/**
 * endpoint 解析。
 * 正常情况是 "cas.aliyuncs.com"（HTTPS + 443）。
 * 但为了让演练能指向本地 stub，这里也接受完整 URL，例如 "http://127.0.0.1:8787"。
 */
function resolveEndpoint(endpoint) {
  if (/^https?:\/\//i.test(endpoint)) {
    const url = new URL(endpoint);
    return {
      host: url.hostname,
      port: Number(url.port || (url.protocol === 'http:' ? 80 : 443)),
      protocol: url.protocol,
      display: url.origin,
    };
  }
  return { host: endpoint, port: 443, protocol: 'https:', display: endpoint };
}

async function main() {
  const args = parseArgs(process.argv);
  if (args.selftest) return selftest();

  if (!args.product || !args.version || !args.action) {
    throw new ApiError('必须指定 --product / --version / --action');
  }

  // 凭据解析: 优先「证书同步专用」那一对（*_CERT），未配置时回退到 DNS 那一对（*_DNS）。
  // 这两对都来自 GitHub Environment `PROD`（ID 走 Variables，Key 走 Secrets）。
  const accessKeyId = process.env.ALIYUN_SECRET_ID_CERT || process.env.ALIYUN_SECRET_ID_DNS || '';
  const accessKeySecret = process.env.ALIYUN_SECRET_KEY_CERT || process.env.ALIYUN_SECRET_KEY_DNS || '';
  if (!args.dryRun && (!accessKeyId || !accessKeySecret)) {
    throw new ApiError(
      '缺少阿里云凭据: 请配置 ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS' +
      '（或证书同步专用的 ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT）。' +
      'CI 里从 GitHub Environment PROD 注入，不要写进任何文件。'
    );
  }

  // 公共请求参数
  const params = {
    Action: args.action,
    Version: args.version,
    Format: 'JSON',
    AccessKeyId: accessKeyId || 'DRYRUN',
    SignatureMethod: 'HMAC-SHA1',
    SignatureVersion: '1.0',
    SignatureNonce: crypto.randomUUID().replace(/-/g, ''),
    Timestamp: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
  };
  for (const spec of args.params) {
    const [key, value] = parseParam(spec);
    params[key] = value;
  }

  const endpointRaw = args.endpoint || process.env.ALIYUN_API_ENDPOINT || `${args.product}.aliyuncs.com`;
  const endpoint = resolveEndpoint(endpointRaw);
  const { signature, canonical } = sign(args.method, params, accessKeySecret || 'DRYRUN');
  params.Signature = signature;

  if (args.dryRun) {
    // 只回显「参数名」和长度，绝不回显值（值里可能有私钥）
    const summary = Object.keys(params)
      .sort()
      .map((k) => (k === 'Signature' ? `${k}=<${signature.length}字节>` : `${k}=<${String(params[k]).length}字节>`))
      .join(' ');
    process.stderr.write(`[aliyun] DRY-RUN endpoint=${endpoint.display} method=${args.method} transport=${args.transport}\n`);
    process.stderr.write(`[aliyun] DRY-RUN 参数: ${summary}\n`);
    process.stderr.write(`[aliyun] DRY-RUN CanonicalizedQueryString 长度=${canonical.length}\n`);
    process.stdout.write(JSON.stringify({ DryRun: true, Action: args.action, Endpoint: endpoint.display }) + '\n');
    return;
  }

  let reqPath = '/';
  let body = '';
  const headers = { Accept: 'application/json' };
  const encoded = querystring.stringify(params);
  if (args.transport === 'form') {
    // 官方文档的 formData 风格: 所有参数放在请求体里，签名包含这些参数
    headers['Content-Type'] = 'application/x-www-form-urlencoded';
    headers['Content-Length'] = Buffer.byteLength(encoded);
    body = encoded;
  } else {
    reqPath = `/?${encoded}`;
    headers['Content-Length'] = 0;
  }

  process.stderr.write(`[aliyun] 调用 ${args.product}.${args.action} (Version=${args.version}, endpoint=${endpoint.display})\n`);

  const res = await requestJson({
    endpoint: endpoint.host,
    port: endpoint.port,
    protocol: endpoint.protocol,
    method: args.method,
    path: reqPath,
    body,
    headers,
    timeout: args.timeout,
  });

  let parsed;
  try {
    parsed = JSON.parse(res.raw);
  } catch (e) {
    // 不打印原始响应体全文，避免任何可能的敏感回显；只给前 300 字符
    throw new ApiError(
      `响应不是合法 JSON（HTTP ${res.statusCode}）: ${String(res.raw).slice(0, 300)}`
    );
  }

  if (parsed.Code || parsed.code) {
    const code = parsed.Code || parsed.code;
    const message = parsed.Message || parsed.message || '';
    throw new ApiError(`阿里云返回错误 ${code}: ${message}（HTTP ${res.statusCode}）`);
  }
  if (res.statusCode !== 200) {
    throw new ApiError(`HTTP ${res.statusCode}（${args.product}.${args.action}）`);
  }

  if (args.extract) {
    const value = extractPath(parsed, args.extract);
    if (value === undefined || value === null || value === '') {
      throw new ApiError(
        `响应里没有字段 ${args.extract}，实际字段: ${Object.keys(parsed).join(', ')}`
      );
    }
    process.stdout.write(String(value) + '\n');
  } else {
    process.stdout.write(JSON.stringify(parsed) + '\n');
  }
}

main().catch((e) => {
  process.stderr.write(`[aliyun] 失败: ${e.message}\n`);
  process.exit(1);
});
