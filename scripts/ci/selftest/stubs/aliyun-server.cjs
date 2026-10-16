#!/usr/bin/env node
/**
 * X Certbot - stub 演练用的「假阿里云 OpenAPI 端点」
 *
 * 用途: 只用于 scripts/ci/selftest/run.sh。它在本机起一个 HTTP 服务，
 *       让 scripts/ci/lib/aliyun-api.cjs 把请求发给它（ALIYUN_API_ENDPOINT=http://127.0.0.1:<port>），
 *       从而在没有真实凭据的情况下，端到端验证:
 *         - 请求参数拼装（含把 PEM 内容当参数传）
 *         - 签名计算（本文件用独立实现复算一遍并比对，算法依据官方文档）
 *         - CAS 上传/查询的幂等逻辑（同名拒绝、Sha2 指纹比对、分页）
 *         - CDN / DCDN 部署是否引用了 CAS 里真实存在的证书 ID
 *
 * 实现的接口:
 *   cas  2020-04-07  UploadUserCertificate / ListUserCertificateOrder
 *   cdn  2018-05-10  SetCdnDomainSSLCertificate
 *   dcdn 2018-01-15  SetDcdnDomainSSLCertificate
 *
 * 环境变量:
 *   STUB_ALIYUN_PORT_FILE  把实际监听端口写到这里（用 0 端口时必需）
 *   STUB_ALIYUN_STATE      状态文件路径（演练脚本读它做断言）
 *   ALIYUN_SECRET_ID_CERT / ALIYUN_SECRET_KEY_CERT  校验签名用（优先）
 *   ALIYUN_SECRET_ID_DNS / ALIYUN_SECRET_KEY_DNS    未配置上面那对时回退（默认 testid/testsecret）
 *                                                   （解析顺序与 aliyun-api.cjs 保持一致）
 *
 * 额外路由:
 *   GET /__state  返回当前状态 JSON
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const http = require('http');
const querystring = require('querystring');

const STATE_FILE = process.env.STUB_ALIYUN_STATE || '/tmp/x-certbot-stub-aliyun.json';
const AK_ID = process.env.ALIYUN_SECRET_ID_CERT || process.env.ALIYUN_SECRET_ID_DNS || 'testid';
const AK_SECRET = process.env.ALIYUN_SECRET_KEY_CERT || process.env.ALIYUN_SECRET_KEY_DNS || 'testsecret';

let state = { certs: [], nextCertId: 1000, deployments: [], calls: [] };

function loadState() {
  if (fs.existsSync(STATE_FILE)) {
    try {
      state = Object.assign(state, JSON.parse(fs.readFileSync(STATE_FILE, 'utf8')));
    } catch (e) { /* 首次运行 */ }
  }
}
function saveState() {
  fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
}

// --- 与 scripts/ci/lib/aliyun-api.cjs 独立的一份签名实现（用于交叉校验）-----------
function percentEncode(value) {
  return encodeURIComponent(String(value)).replace(/\+/g, '%20').replace(/\*/g, '%2A').replace(/%7E/g, '~');
}
function expectedSignature(params, method) {
  const canonical = Object.keys(params)
    .filter((k) => k !== 'Signature')
    .sort()
    .map((k) => `${percentEncode(k)}=${percentEncode(params[k])}`)
    .join('&');
  const stringToSign = `${method}&${percentEncode('/')}&${percentEncode(canonical)}`;
  return crypto.createHmac('sha1', `${AK_SECRET}&`).update(stringToSign, 'utf8').digest('base64');
}

/** CAS 的 Sha2 字段: 叶子证书 DER 的 SHA-256（大写十六进制，无分隔符） */
function certSha2(pem) {
  const m = String(pem).match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/);
  if (!m) return '';
  const der = Buffer.from(m[0].replace(/-----[^-]+-----/g, '').replace(/\s+/g, ''), 'base64');
  return crypto.createHash('sha256').update(der).digest('hex').toUpperCase();
}

function send(res, statusCode, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(body) });
  res.end(body);
}

function rpcError(res, code, message, statusCode = 400) {
  send(res, statusCode, { RequestId: 'stub-' + crypto.randomUUID(), Code: code, Message: message });
}

// Action 名在阿里云各产品间是唯一的，所以直接用 Action 反推产品，
// 不依赖 Host（演练时 endpoint 是 127.0.0.1，Host 里没有产品名）。
const ACTIONS = {
  UploadUserCertificate: { service: 'cas', version: '2020-04-07' },
  ListUserCertificateOrder: { service: 'cas', version: '2020-04-07' },
  SetCdnDomainSSLCertificate: { service: 'cdn', version: '2018-05-10' },
  SetDcdnDomainSSLCertificate: { service: 'dcdn', version: '2018-01-15' },
};

function handle(params, res) {
  const action = params.Action;
  const version = params.Version;
  const meta = ACTIONS[action];
  if (!meta) {
    state.calls.push({ action, version, unmatched: true, at: new Date().toISOString() });
    return rpcError(res, 'InvalidAction', `stub 未实现 Action=${action}`);
  }
  if (meta.version !== version) {
    state.calls.push({ service: meta.service, action, version, version_mismatch: true, at: new Date().toISOString() });
    return rpcError(res, 'InvalidVersion', `${action} 期望 Version=${meta.version}，实际 ${version}`);
  }
  const service = meta.service;
  state.calls.push({ service, action, version, at: new Date().toISOString() });
  saveState();

  if (service === 'cas' && version === '2020-04-07' && action === 'UploadUserCertificate') {
    const name = params.Name || '';
    if (!name) return rpcError(res, 'MissingParameter', 'Name is mandatory');
    const cert = params.Cert || '';
    const key = params.Key || '';
    if (!cert || !key) return rpcError(res, 'MissingParameter', 'Cert/Key is mandatory for standard certificate');
    if (state.certs.some((c) => c.name === name)) {
      // 真实 CAS: 同账号下证书名称不能重复
      return rpcError(res, 'CertificateNameRepeat', `certificate name ${name} already exists`);
    }
    const id = state.nextCertId++;
    state.certs.push({
      CertificateId: id,
      Name: name,
      Sha2: certSha2(cert),
      CommonName: (cert.match(/CN\s*=\s*([^,\n]+)/) || [])[1] || '',
      Upload: true,
      Expired: false,
    });
    saveState();
    return send(res, 200, {
      CertId: id,
      ResourceId: `cas-upload-stub-${id}`,
      RequestId: 'stub-' + crypto.randomUUID(),
    });
  }

  if (service === 'cas' && version === '2020-04-07' && action === 'ListUserCertificateOrder') {
    const orderType = params.OrderType || 'CPACK';
    if (orderType !== 'UPLOAD' && orderType !== 'CERT') {
      return rpcError(res, 'InvalidParameter', `OrderType=${orderType} 在 stub 里没有数据`);
    }
    const page = Number(params.CurrentPage || 1);
    const size = Number(params.ShowSize || 50);
    const all = state.certs.slice();
    const slice = all.slice((page - 1) * size, page * size);
    return send(res, 200, {
      RequestId: 'stub-' + crypto.randomUUID(),
      ShowSize: size,
      CurrentPage: page,
      TotalCount: all.length,
      CertificateOrderList: slice,
    });
  }

  if (service === 'cdn' && version === '2018-05-10' && action === 'SetCdnDomainSSLCertificate') {
    return deploySSL(res, 'cdn', params);
  }
  if (service === 'dcdn' && version === '2018-01-15' && action === 'SetDcdnDomainSSLCertificate') {
    return deploySSL(res, 'dcdn', params);
  }

  return rpcError(res, 'InvalidAction', `stub 未实现 ${service}.${action} (Version=${version})`);
}

function deploySSL(res, product, params) {
  const domain = params.DomainName;
  if (!domain) return rpcError(res, 'MissingParameter', 'DomainName is mandatory');
  const certType = params.CertType || 'upload';
  if (certType === 'cas') {
    const certId = Number(params.CertId);
    if (!certId) return rpcError(res, 'MissingParameter', 'CertId is mandatory when CertType=cas');
    if (!state.certs.some((c) => c.CertificateId === certId)) {
      return rpcError(res, 'InvalidParameter', `证书 ${params.CertId} 在 CAS 里不存在`);
    }
  } else if (!params.SSLPub || !params.SSLPri) {
    return rpcError(res, 'MissingParameter', 'CertType=upload 时 SSLPub/SSLPri 必填');
  }
  if (params.SSLProtocol !== 'on' && params.SSLProtocol !== 'off') {
    return rpcError(res, 'InvalidParameter', 'SSLProtocol 只能是 on 或 off');
  }
  state.deployments.push({
    product,
    domain,
    cert_type: certType,
    cert_id: params.CertId ? Number(params.CertId) : null,
    ssl_protocol: params.SSLProtocol,
    cert_region: params.CertRegion || '',
    at: new Date().toISOString(),
  });
  saveState();
  return send(res, 200, { RequestId: 'stub-' + crypto.randomUUID() });
}

function collectBody(req, cb) {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => cb(Buffer.concat(chunks).toString('utf8')));
}

loadState();

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/__state') {
    return send(res, 200, state);
  }
  collectBody(req, (rawBody) => {
    const url = new URL(req.url, 'http://127.0.0.1');
    const query = Object.fromEntries(url.searchParams.entries());
    const form = rawBody ? Object.fromEntries(new URLSearchParams(rawBody).entries()) : {};
    const params = Object.assign({}, query, form);

    // 校验签名（独立实现复算）
    if (!params.Signature) return rpcError(res, 'MissingSignature', 'missing Signature');
    const want = expectedSignature(params, req.method);
    if (want !== params.Signature) {
      return rpcError(res, 'SignatureDoesNotMatch', '签名不一致（stub 用独立实现复算）');
    }
    if (params.AccessKeyId !== AK_ID) {
      return rpcError(res, 'InvalidAccessKeyId.NotFound', 'AccessKeyId 不匹配');
    }

    handle(params, res);
  });
});

const port = Number(process.env.STUB_ALIYUN_PORT || 0);
server.listen(port, '127.0.0.1', () => {
  const actual = server.address().port;
  const portFile = process.env.STUB_ALIYUN_PORT_FILE;
  if (portFile) fs.writeFileSync(portFile, String(actual));
  process.stdout.write(`[stub-aliyun] listening on http://127.0.0.1:${actual}\n`);
});
