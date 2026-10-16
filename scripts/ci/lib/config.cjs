#!/usr/bin/env node
/**
 * X Certbot - CI 配置解析器
 *
 * 用途: 读取声明式配置文件（默认 deploy/domains.yml），校验后输出一份「执行计划」JSON，
 *       交给 scripts/ci/issue-cert.sh 和 scripts/ci/sync-cert.sh 使用。
 *
 * 依赖: 只依赖 Node（本仓库 CI 用 ubuntu-latest，自带 Node）+ js-yaml。
 *       刻意不依赖 jq / python / tccli。
 *
 * 用法:
 *   node scripts/ci/lib/config.cjs --config deploy/domains.yml --out plan.json
 *   node scripts/ci/lib/config.cjs --config deploy/domains.yml --list
 *   node scripts/ci/lib/config.cjs --config deploy/domains.yml --domain example.com --out one.json
 *   node scripts/ci/lib/config.cjs --config deploy/domains.yml --domain example.com --emit-domain example.com --out d.json
 *
 * 退出码: 0 成功；1 配置错误（信息里会指出是哪一项）。
 */

'use strict';

const fs = require('fs');
const path = require('path');

// ---------------------------------------------------------------------------
// 同步目标注册表
//
// 这里是「配置里能写哪些同步目标」以及「每个目标由哪个脚本执行」的唯一来源。
// 新增一个同步目标 = 在这里加一条 + 在 scripts/ci/targets/ 下加一个脚本。
// ---------------------------------------------------------------------------
const TARGET_REGISTRY = {
  'cloudbase.domain': {
    script: 'scripts/ci/targets/cloudbase.sh',
    platform: 'cloudbase',
    label: '腾讯云 CloudBase 自定义域名',
  },
  'aliyun.cas': {
    script: 'scripts/ci/targets/aliyun-cas.sh',
    platform: 'aliyun',
    label: '阿里云 数字证书管理服务(CAS)',
  },
  'aliyun.cdn': {
    script: 'scripts/ci/targets/aliyun-cdn.sh',
    platform: 'aliyun',
    product: 'cdn',
    label: '阿里云 CDN',
  },
  'aliyun.dcdn': {
    script: 'scripts/ci/targets/aliyun-cdn.sh',
    platform: 'aliyun',
    product: 'dcdn',
    label: '阿里云 DCDN(全站加速)',
  },
};

// 目标执行顺序（固定，保证 aliyun.cas 先于依赖它的 cdn/dcdn 产出证书 ID）
const TARGET_ORDER = ['cloudbase.domain', 'aliyun.cas', 'aliyun.cdn', 'aliyun.dcdn'];

const DNS_PROVIDERS = {
  aliyun: { plugin: 'dns_ali', label: '阿里云 DNS' },
  tencentcloud: { plugin: 'dns_tencent', label: '腾讯云 DNSPod' },
};

const SUPPORTED_VERSION = 1;

// deploy/domains.yml 里邮箱的占位值: 用户必须改成真实邮箱，否则直接报错。
// 邮箱不是机密，所以只从配置文件读，不再从环境变量 / GitHub Secrets 读。
const EMAIL_PLACEHOLDER = 'CHANGE_ME@example.com';

class ConfigError extends Error {}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------
function fail(message) {
  throw new ConfigError(message);
}

/**
 * 把域名规范化为 punycode（ASCII）。
 * 中文域名（国际化域名）必须转成 punycode 才能提交给 Let's Encrypt，
 * 这也是本仓库 plugins/dns/aliyun.sh + scripts/domain_utils.sh 一贯的处理方式。
 */
function toAsciiDomain(domain) {
  const trimmed = String(domain).trim().replace(/\.$/, '');
  if (!trimmed) fail('域名不能为空');
  if (trimmed.startsWith('*.')) {
    return '*' + '.' + toAsciiDomain(trimmed.slice(2));
  }
  try {
    // WHATWG URL 会按 IDNA 规则把 Unicode 域名转成 punycode
    const host = new URL(`http://${trimmed}`).hostname;
    if (!host || host.includes('/')) fail(`域名格式不正确: ${domain}`);
    return host;
  } catch (e) {
    fail(`无法把域名转换为 punycode: ${domain}（${e.message}）`);
  }
}

/** 是否包含非 ASCII 字符（用于提示用户「已自动转码」） */
function hasNonAscii(value) {
  return /[^\x00-\x7F]/.test(String(value));
}

function asArray(value, ctx) {
  if (value === undefined || value === null) return [];
  if (Array.isArray(value)) return value;
  fail(`${ctx} 必须是列表（YAML 数组）`);
}

function asBool(value, ctx, defaultValue) {
  if (value === undefined || value === null || value === '') return defaultValue;
  if (typeof value === 'boolean') return value;
  if (value === 'true') return true;
  if (value === 'false') return false;
  fail(`${ctx} 必须是 true 或 false，当前值: ${JSON.stringify(value)}`);
}

function asInt(value, ctx, defaultValue, min, max) {
  if (value === undefined || value === null || value === '') return defaultValue;
  const n = Number(value);
  if (!Number.isInteger(n)) fail(`${ctx} 必须是整数，当前值: ${JSON.stringify(value)}`);
  if (min !== undefined && n < min) fail(`${ctx} 不能小于 ${min}，当前值: ${n}`);
  if (max !== undefined && n > max) fail(`${ctx} 不能大于 ${max}，当前值: ${n}`);
  return n;
}

/** 展开字符串里的 ${VAR} / $VAR 环境变量引用（密钥走环境变量，不写进配置文件） */
function expandEnv(value) {
  if (typeof value !== 'string') return value;
  return value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, name) =>
    process.env[name] === undefined ? '' : process.env[name]
  );
}

/**
 * ACME 账户邮箱。
 * 邮箱不是机密，所以【只从 deploy/domains.yml 读】（defaults.email 或某个域名的 email），
 * 不再从环境变量 / GitHub Secrets 读。
 * 空值或占位值直接报错: 与其静默用空邮箱注册 ACME 账户，不如让用户在第一眼就看到要改哪里。
 */
function resolveEmail(acme, ctx) {
  const value = expandEnv(String(acme.email || '')).trim();
  if (!value || value === EMAIL_PLACEHOLDER) {
    fail(
      `${ctx}.email 还没有填写（当前值: ${value ? JSON.stringify(value) : '<空>'}）。\n` +
      '  邮箱不是机密，请直接在 deploy/domains.yml 里把 defaults.email（或该域名的 email）\n' +
      "  改成你自己的邮箱，例如 ops@example.com。Let's Encrypt 会用它发送证书到期提醒。"
    );
  }
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(value)) {
    fail(`${ctx}.email 不像一个合法邮箱: ${JSON.stringify(value)}`);
  }
  return value;
}

/** 只在目标是普通对象时做浅合并；数组整体覆盖 */
function mergePlain(base, override) {
  const out = Object.assign({}, base || {});
  for (const [key, val] of Object.entries(override || {})) {
    if (val === undefined) continue;
    if (
      val && typeof val === 'object' && !Array.isArray(val) &&
      out[key] && typeof out[key] === 'object' && !Array.isArray(out[key])
    ) {
      out[key] = mergePlain(out[key], val);
    } else {
      out[key] = val;
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// YAML 读取
// ---------------------------------------------------------------------------
function loadYaml(filePath) {
  if (!fs.existsSync(filePath)) fail(`配置文件不存在: ${filePath}`);
  let yaml;
  try {
    yaml = require('js-yaml');
  } catch (e) {
    fail(
      '缺少 js-yaml 依赖。CI 工作流会执行 `npm install --no-save js-yaml@4.1.0`；\n' +
      '本机运行时请先安装: npm install --no-save js-yaml@4.1.0'
    );
  }
  let raw;
  try {
    raw = yaml.load(fs.readFileSync(filePath, 'utf8'));
  } catch (e) {
    fail(`YAML 解析失败（${filePath}）: ${e.message}`);
  }
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    fail(`配置文件内容必须是一个 YAML 映射（${filePath}）`);
  }
  return raw;
}

// ---------------------------------------------------------------------------
// 同步目标解析
// ---------------------------------------------------------------------------
function buildTargets(syncConfig, domainCtx) {
  const sync = syncConfig || {};
  const targets = [];

  // --- 腾讯云 CloudBase ---
  const cb = mergePlain({ enabled: false }, sync.cloudbase || {});
  if (asBool(cb.enabled, `${domainCtx}.sync.cloudbase.enabled`, false)) {
    const envId = expandEnv(String(cb.env_id || '')) || process.env.CLOUDBASE_ENV_ID || '';
    if (!envId) {
      fail(
        `${domainCtx}.sync.cloudbase.env_id 为空，且环境变量 CLOUDBASE_ENV_ID 也没有设置。` +
        '请二选一填好（env_id 非敏感，可直接写在配置里）。'
      );
    }
    targets.push({
      id: 'cloudbase.domain',
      ...TARGET_REGISTRY['cloudbase.domain'],
      config: {
        env_id: envId,
        domains: asArray(cb.domains, `${domainCtx}.sync.cloudbase.domains`).map((d) => toAsciiDomain(d)),
        // 留空表示用本域名自身，在 runDomain 里补齐
        routes_apply: asBool(cb.routes_apply, `${domainCtx}.sync.cloudbase.routes_apply`, false),
        routes: asArray(cb.routes, `${domainCtx}.sync.cloudbase.routes`).map((r, i) => {
          if (!r || typeof r !== 'object') fail(`${domainCtx}.sync.cloudbase.routes[${i}] 必须是映射`);
          const routeDomain = String(r.domain || '').trim();
          const routePath = String(r.path || '').trim();
          if (!routeDomain) fail(`${domainCtx}.sync.cloudbase.routes[${i}].domain 必填`);
          if (!routePath) fail(`${domainCtx}.sync.cloudbase.routes[${i}].path 必填`);
          return {
            domain: toAsciiDomain(routeDomain),
            path: routePath,
            upstream_resource_type: String(r.upstream_resource_type || 'WEB_SCF'),
            upstream_resource_name: String(r.upstream_resource_name || ''),
            enable: asBool(r.enable, `${domainCtx}.sync.cloudbase.routes[${i}].enable`, true),
            enable_auth: asBool(r.enable_auth, `${domainCtx}.sync.cloudbase.routes[${i}].enable_auth`, false),
            enable_safe_domain: asBool(
              r.enable_safe_domain, `${domainCtx}.sync.cloudbase.routes[${i}].enable_safe_domain`, false
            ),
            enable_path_transmission: asBool(
              r.enable_path_transmission, `${domainCtx}.sync.cloudbase.routes[${i}].enable_path_transmission`, false
            ),
          };
        }),
        delete_old_cert: asBool(cb.delete_old_cert, `${domainCtx}.sync.cloudbase.delete_old_cert`, false),
      },
    });
  }

  // --- 阿里云 ---
  const ali = sync.aliyun || {};
  const cas = mergePlain({ enabled: false }, ali.cas || {});
  const cdn = mergePlain({ enabled: false }, ali.cdn || {});
  const dcdn = mergePlain({ enabled: false }, ali.dcdn || {});
  const casEnabled = asBool(cas.enabled, `${domainCtx}.sync.aliyun.cas.enabled`, false);
  const cdnEnabled = asBool(cdn.enabled, `${domainCtx}.sync.aliyun.cdn.enabled`, false);
  const dcdnEnabled = asBool(dcdn.enabled, `${domainCtx}.sync.aliyun.dcdn.enabled`, false);

  if ((cdnEnabled || dcdnEnabled) && !casEnabled) {
    fail(
      `${domainCtx}.sync.aliyun: 启用 cdn/dcdn 时必须同时启用 cas。\n` +
      '  原因: 本方案让 CDN/DCDN 直接引用「数字证书管理服务(CAS)」里的证书 ID（CertType=cas），\n' +
      '        证书只上传一份，避免多份副本各自过期。'
    );
  }

  if (casEnabled) {
    const prefix = String(cas.name_prefix || 'LE').trim();
    if (!prefix) fail(`${domainCtx}.sync.aliyun.cas.name_prefix 不能为空`);
    targets.push({
      id: 'aliyun.cas',
      ...TARGET_REGISTRY['aliyun.cas'],
      config: { name_prefix: prefix.slice(0, 40) },
    });
  }
  for (const [product, cfg, enabled] of [['cdn', cdn, cdnEnabled], ['dcdn', dcdn, dcdnEnabled]]) {
    if (!enabled) continue;
    const domains = asArray(cfg.domains, `${domainCtx}.sync.aliyun.${product}.domains`).map((d) => toAsciiDomain(d));
    if (domains.length === 0) {
      fail(`${domainCtx}.sync.aliyun.${product}.enabled 为 true，但 domains 列表为空`);
    }
    targets.push({
      id: `aliyun.${product}`,
      ...TARGET_REGISTRY[`aliyun.${product}`],
      config: { domains },
    });
  }

  // 固定执行顺序，保证 aliyun.cas 先产出证书 ID
  targets.sort((a, b) => TARGET_ORDER.indexOf(a.id) - TARGET_ORDER.indexOf(b.id));
  return targets;
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------
function buildPlan(raw, configPath) {
  const version = asInt(raw.version, 'version', SUPPORTED_VERSION);
  if (version !== SUPPORTED_VERSION) {
    fail(`不支持的配置版本 version=${version}，当前只支持 ${SUPPORTED_VERSION}`);
  }

  const defaults = mergePlain(
    {
      server: 'letsencrypt',
      key_length: 2048,
      dns_propagation_seconds: 60,
      email: '',
    },
    raw.defaults || {}
  );

  const rawDomains = asArray(raw.domains, 'domains');
  if (rawDomains.length === 0) fail('domains 不能为空，至少要写一个域名');

  const defaultSync = raw.sync || {};
  const seenNames = new Map();
  const domains = [];

  rawDomains.forEach((entry, index) => {
    const ctx = `domains[${index}]`;
    if (!entry || typeof entry !== 'object') fail(`${ctx} 必须是映射`);
    if (!entry.name) fail(`${ctx}.name 必填`);

    const originalName = String(entry.name).trim();
    let name = toAsciiDomain(originalName);
    let wildcard = asBool(entry.wildcard, `${ctx}.wildcard`, false);
    // 用户如果直接写了 *.example.com，自动识别为泛域名
    if (name.startsWith('*.')) {
      wildcard = true;
      name = name.slice(2);
    }

    if (seenNames.has(name)) {
      fail(`域名重复: ${name}（第 ${seenNames.get(name) + 1} 个和第 ${index + 1} 个条目）。一张证书请写在同一个条目里。`);
    }
    seenNames.set(name, index);

    const providerKey = String(entry.dns_provider || '').trim();
    if (!DNS_PROVIDERS[providerKey]) {
      fail(
        `${ctx}.dns_provider 必须是 ${Object.keys(DNS_PROVIDERS).join(' 或 ')}，当前值: ` +
        `${JSON.stringify(entry.dns_provider)}`
      );
    }

    const keyLength = String(
      mergePlain(defaults, entry).key_length
    ).trim();
    if (!/^(2048|3072|4096|ec-256|ec-384|ec-521)$/.test(keyLength)) {
      fail(`${ctx}.key_length 只支持 2048 / 3072 / 4096 / ec-256 / ec-384 / ec-521，当前值: ${keyLength}`);
    }

    const acme = mergePlain(defaults, entry);
    const syncConfig = mergePlain(defaultSync, entry.sync || {});

    const certNames = [name];
    if (wildcard) certNames.push(`*.${name}`);

    domains.push({
      name,
      display_name: hasNonAscii(originalName) ? originalName : name,
      idn: hasNonAscii(originalName),
      cert_names: certNames,
      wildcard,
      dns_provider: providerKey,
      dns_plugin: DNS_PROVIDERS[providerKey].plugin,
      dns_provider_label: DNS_PROVIDERS[providerKey].label,
      server: String(acme.server || 'letsencrypt').trim(),
      key_length: keyLength,
      ecc: keyLength.startsWith('ec-'),
      dns_propagation_seconds: asInt(
        acme.dns_propagation_seconds, `${ctx}.dns_propagation_seconds`, 60, 0, 3600
      ),
      email: resolveEmail(acme, ctx),
      targets: buildTargets(syncConfig, ctx),
    });
  });

  return { version, config_path: path.resolve(configPath), generated_at: new Date().toISOString(), domains };
}

function parseArgs(argv) {
  const args = { config: 'deploy/domains.yml', out: '', domain: '', list: false };
  for (let i = 2; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--config': args.config = argv[++i]; break;
      case '--out': args.out = argv[++i]; break;
      case '--domain': args.domain = argv[++i]; break;
      case '--list': args.list = true; break;
      case '--help':
      case '-h':
        process.stdout.write(fs.readFileSync(__filename, 'utf8').split('*/')[0].replace(/^\/\*\*?/, ''));
        process.exit(0);
        break;
      default:
        fail(`未知参数: ${arg}`);
    }
  }
  return args;
}

function main() {
  const args = parseArgs(process.argv);
  const plan = buildPlan(loadYaml(args.config), args.config);

  if (args.domain) {
    const wanted = args.domain.split(',').map((d) => String(d).trim()).filter(Boolean);
    const normalized = new Set(wanted.map((d) => {
      let v = toAsciiDomain(d);
      if (v.startsWith('*.')) v = v.slice(2);
      return v;
    }));
    const matched = plan.domains.filter((d) => normalized.has(d.name));
    const missing = [...normalized].filter((n) => !matched.some((d) => d.name === n));
    if (missing.length) {
      fail(`--domain 指定的域名在配置里找不到: ${missing.join(', ')}；配置里有: ${plan.domains.map((d) => d.name).join(', ')}`);
    }
    plan.domains = matched;
  }

  if (args.list) {
    for (const d of plan.domains) {
      const targets = d.targets.map((t) => t.id).join(',') || '(不同步)';
      process.stdout.write(`${d.name}\t${d.dns_provider}\twildcard=${d.wildcard}\ttargets=${targets}\n`);
    }
    return;
  }

  const output = JSON.stringify(plan, null, 2);
  if (args.out) {
    fs.mkdirSync(path.dirname(path.resolve(args.out)), { recursive: true });
    fs.writeFileSync(args.out, output);
    process.stderr.write(`[config] 已写出执行计划: ${args.out}（${plan.domains.length} 个域名）\n`);
  } else {
    process.stdout.write(output + '\n');
  }
}

try {
  main();
} catch (e) {
  if (e instanceof ConfigError) {
    process.stderr.write(`[config] 配置错误: ${e.message}\n`);
    process.exit(1);
  }
  throw e;
}
