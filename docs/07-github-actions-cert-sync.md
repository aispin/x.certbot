# X Certbot - GitHub Actions 证书自动化（多域名 + 腾讯云/阿里云同步）

> 本文档说明 `.github/workflows/cert-sync.yml` 这套新增的自动化：
> 用一个仓库集中管理所有域名的证书申请与续期，并在证书变化后同步到
> **腾讯云 CloudBase** 与 **阿里云**。
>
> 相关文档：
> - 配置选项与既有用法：[使用指南](04-usage-guide.md)
> - 容器内钩子机制：[开发指南](05-development-guide.md#8-钩子脚本与自动化流程)
> - 中文域名处理：[中文域名支持](06-chinese-domain-support.md)

## 目录

- [1. 这套自动化做什么](#1-这套自动化做什么)
- [2. 与现有用法的关系](#2-与现有用法的关系)
- [3. 快速开始](#3-快速开始)
- [4. 需要配置的凭据（Environment PROD）](#4-需要配置的凭据environment-prod)
- [5. 声明式配置 deploy/domains.yml](#5-声明式配置-deploydomainsyml)
- [6. 同步目标清单](#6-同步目标清单)
- [7. 幂等性与状态管理](#7-幂等性与状态管理)
- [8. 手动演练（必做）](#8-手动演练必做)
- [9. 手动触发与运行模式](#9-手动触发与运行模式)
- [10. 本地零凭据演练](#10-本地零凭据演练)
- [11. 故障排查](#11-故障排查)
- [12. 验证边界（哪些验证过、哪些没有）](#12-验证边界哪些验证过哪些没有)
- [13. 新增文件清单](#13-新增文件清单)

---

## 1. 这套自动化做什么

一个仓库、一份配置，管住所有域名：

| 步骤 | 说明 |
|---|---|
| 1. 申请/续期 | 用 [acme.sh](https://github.com/acmesh-official/acme.sh) 通过 DNS-01 向 Let's Encrypt 申请证书（支持泛域名、支持阿里云 DNS 与腾讯云 DNSPod） |
| 2. 落盘 | 把证书复制到稳定路径（`--install-cert`），不再依赖 `~/.acme.sh` 的内部结构 |
| 3. 同步 | 按配置把**当前证书**同步到腾讯云 CloudBase 与阿里云（CAS / CDN / DCDN） |
| 4. 汇报 | 每个域名、每个平台的结果写进 Step Summary，失败位置一眼可见 |

关键设计取舍，先说清楚：

1. **为什么用 acme.sh，而不是本仓库容器里的 certbot？**
   acme.sh 官方内置并持续维护阿里云 DNS 插件（`dns_ali`），只用 curl + openssl；
   而 CloudBase/腾讯云 SSL 那一步 acme.sh 官方**没有** deploy hook，本来就要自己写。
   在 GitHub Actions 的乌班图 runner 上直接跑 acme.sh，比拉起容器再挂钩子更直接。
   本仓库原有的 Docker + certbot 用法**完全不受影响**，两套可以并存。

2. **为什么每次运行都全量同步，而不是「只在续期时同步」？**
   因为「证书换新」和「同步到云平台」是两个会分别失败的动作。
   如果只在本次真的续期了才同步，那么一旦出现「证书已换新 + 同步失败」，
   下次运行时因为没有续期而跳过同步，就会变成**永久性不一致**
   （CloudBase 尤其危险：它存的是证书 ID 指针，不会自己跟着换）。
   所以策略是：每次都把当前证书同步一遍，靠每个目标自身的幂等性把重复调用变成便宜的空操作。
   这样「上次失败」会在下一次定时运行里被自动补上。

3. **续期判定交给 acme.sh。** 没到续期窗口（默认剩余 60 天以内才续）它会直接跳过，
   不会重复签发 —— 这一点对 Let's Encrypt 的速率限制很重要。

---

## 2. 与现有用法的关系

这套自动化是**纯新增**，没有修改任何现有文件，不会影响：

- `entrypoint.sh` / `Dockerfile` 的容器用法
- `plugins/dns/*.sh` 的 certbot DNS 钩子
- `.github/workflows/docker-publish.yml` 的镜像发布
- `docs/01`–`docs/06` 既有文档

它复用并延续了既有约定：同样的中文注释风格、同样的 `scripts/console_utils.sh` 控制台输出、
同样的 punycode 中文域名处理、同样的「声明式配置 + 环境变量注入凭据」。

新增文件见 [第 13 节](#13-新增文件清单)。

---

## 3. 快速开始

1. **建好 Environment `PROD`**，在里面配置四个变量/密钥（见 [第 4 节](#4-需要配置的凭据environment-prod)）
   —— 名字必须完全一致，ID 走 Variables、Key 走 Secrets
2. **编辑 `deploy/domains.yml`**：把 `defaults.email` 的占位邮箱改成你自己的，
   写上你的域名与要同步的目标（见 [第 5 节](#5-声明式配置-deploydomainsyml)）
3. **先干跑一次**：Actions → Certificate Sync → Run workflow → 勾选 `dry_run`
4. **再真跑一次**：`mode=full`，先用 `domain` 只跑**一个**域名
5. **演练一次强制续期**（见 [第 8 节](#8-手动演练必做)），确认同步链路真的通
6. 之后交给 `schedule`，每天自动跑

> workflow 的 job 上写死了 `environment: PROD`。这是**硬性要求**：
> Environment 下的 Variables 与 Secrets 只在声明了 environment 的 job 里才会被注入，
> 否则它们会静默变成空字符串（表现为「凭据预检失败」，或更糟：在错误账号上操作）。

---

## 4. 需要配置的凭据（Environment PROD）

### 4.0 先建好 Environment `PROD`

仓库 `Settings → Environments → New environment`，名字必须**恰好**是 `PROD`（大小写敏感）。
变量与密钥都配置在这个 environment 下，而不是仓库级 —— workflow 里读的是
`${{ vars.* }}` / `${{ secrets.* }}`，job 声明了 `environment: PROD` 后它们才会指向这里。

### 4.1 四个配置项（就这四个）

| 名称 | 位置 | 用途 | 备注 |
|---|---|---|---|
| `ALIYUN_SECRET_ID_DNS` | **Variables**（`${{ vars.* }}`） | 阿里云 RAM AccessKeyId | `LTAI` 前缀 |
| `ALIYUN_SECRET_KEY_DNS` | **Secrets**（`${{ secrets.* }}`） | 阿里云 RAM AccessKeySecret | 与上面配对 |
| `CLOUDBASE_SECRET_ID` | **Variables**（`${{ vars.* }}`） | 腾讯云 SecretId | `AKID` 前缀 |
| `CLOUDBASE_SECRET_KEY` | **Secrets**（`${{ secrets.* }}`） | 腾讯云 SecretKey | 与上面配对 |

> **为什么 ID 走 Variables、Key 走 Secrets？**
> AccessKeyId / SecretId 本身不是机密（控制台里能直接看到），SecretKey 才是。
> 分开存的好处是：即使有人能看到 Variables 列表，也拿不到能用的凭据；
> 日志与审计里也不会把两者一起暴露出来。**不要**把 Key 也放进 Variables。

这一对凭据被用在两处：

| 用途 | 阿里云 | 腾讯云 |
|---|---|---|
| DNS-01 域名所有权验证 | `ALIYUN_SECRET_ID_DNS` / `ALIYUN_SECRET_KEY_DNS`（acme.sh `dns_ali`） | `CLOUDBASE_SECRET_ID` / `CLOUDBASE_SECRET_KEY`（acme.sh `dns_tencent`，DNSPod） |
| 证书同步 | 默认**复用同一对**（CAS/CDN/DCDN，见 4.3） | 同一对（CloudBase：`tcb login` + SSL 上传 + 域名重绑） |

腾讯云只配了这一对，所以 DNSPod 的 DNS-01 与 CloudBase 的证书同步共用它；
阿里云同理，DNS 与证书同步默认共用 `*_DNS` 那一对。

### 4.2 邮箱不在这里配

ACME 账户邮箱**不是机密**，写在 `deploy/domains.yml` 的 `defaults.email`（或单个域名的 `email`）。
留空、或保留占位值 `CHANGE_ME@example.com` 时，workflow 会在「解析配置并生成执行计划」这一步
直接失败并告诉你改哪里 —— 不会带着空邮箱静默注册 ACME 账户。

### 4.3 阿里云 RAM 权限

本方案实际使用的一对阿里云密钥（Environment `PROD`）：

| 名称 | 位置 | 用途 |
| --- | --- | --- |
| `ALIYUN_SECRET_ID_DNS` | Variables | DNS-01 验证（增删 `_acme-challenge` TXT） |
| `ALIYUN_SECRET_KEY_DNS` | Secrets | 与上面配对 |
| `ALIYUN_SECRET_ID_CERT` | Variables | 证书同步（CAS / CDN / DCDN） |
| `ALIYUN_SECRET_KEY_CERT` | Secrets | 与上面配对 |

证书同步那个 RAM 用户挂以下预设策略：

| 策略 | 用途 |
| --- | --- |
| `AliyunYundunCertReadOnlyAccess` | 读取证书列表（幂等判断用） |
| `AliyunYundunCertFullAccess` | 上传证书到证书库（CAS） |
| `AliyunCDNFullAccess` | 部署证书到 CDN |
| `AliyunDCDNFullAccess` | 部署证书到全站加速 DCDN |

> 只挂 DNS 权限的密钥无法调 CAS/CDN/DCDN（会返回 `Forbidden` / `NoPermission`），
> 所以证书同步单独用一对密钥。若不配 `*_CERT`，脚本会回退到 `*_DNS`——那通常不够用。

#### 原最小权限清单（供收敛时参考）（以及为什么可能需要第二对密钥）

创建入口：<https://ram.console.aliyun.com/users>（新建 RAM 用户 → 勾选「OpenAPI 调用访问」→ 保存 AccessKeyId / AccessKeySecret）

**DNS 验证用**（这就是 `ALIYUN_SECRET_ID_DNS` / `ALIYUN_SECRET_KEY_DNS`，可直接用阿里云预置策略 `AliyunDNSFullAccess`）：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "alidns:DescribeDomainRecords",
        "alidns:AddDomainRecord",
        "alidns:DeleteDomainRecord"
      ],
      "Resource": ["acs:alidns:*:*:domain/example.com", "acs:alidns:*:*:domain/*.example.com"]
    }
  ]
}
```

**⚠️ 证书同步需要的权限超出 DNS 权限，而默认是复用 DNS 那一对的。**

- 能力上没问题：workflow 默认就用 `ALIYUN_SECRET_ID_DNS` / `ALIYUN_SECRET_KEY_DNS` 去调 CAS/CDN/DCDN；
- 但只给 DNS 权限的 RAM 用户调 CAS/CDN/DCDN 会返回 `Forbidden` / `NoPermission`。

处理办法（二选一）：

1. **图省事**：给这个 RAM 用户额外挂上下面这些 Action（权限合并到一个用户上）；
2. **最小权限（推荐）**：另建一个 RAM 用户，只给证书同步权限，然后在 Environment `PROD` 里
   再补两个配置项，workflow 会自动优先用它们：

   | 名称 | 位置 | 对应交付物早期的变量名 |
   |---|---|---|
   | `ALIYUN_SECRET_ID_CERT` | **Variables** | `ALIYUN_CERT_ACCESS_KEY_ID` |
   | `ALIYUN_SECRET_KEY_CERT` | **Secrets** | `ALIYUN_CERT_ACCESS_KEY_SECRET` |

   这两个是可选的：**不配就自动回退到 `*_DNS` 那一对**（这就是交付物原有的回退逻辑）。

**证书同步用**（按你实际启用的目标裁剪；默认只启用 CAS，所以最少只需要前两条）：

```json
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "yundun-cert:UploadUserCertificate",
        "yundun-cert:ListUserCertificateOrder",
        "cdn:SetCdnDomainSSLCertificate",
        "dcdn:SetDcdnDomainSSLCertificate"
      ],
      "Resource": ["*"]
    }
  ]
}
```

对应的开放 API（脚本里已在用）：

| 目标 | Action | 需要开启的同步目标 |
|---|---|---|
| CAS 上传（默认开） | `UploadUserCertificate` / `ListUserCertificateOrder` | `sync.aliyun.cas.enabled: true` |
| CDN 部署（默认关） | `SetCdnDomainSSLCertificate` | 需先开 `cas`，再开 `sync.aliyun.cdn` |
| DCDN 部署（默认关） | `SetDcdnDomainSSLCertificate` | 需先开 `cas`，再开 `sync.aliyun.dcdn` |

> `UploadUserCertificate` / `ListUserCertificateOrder` 的授权信息来自阿里云官方 API 文档的
> 「授权信息」表；`cdn:SetCdnDomainSSLCertificate` 同理；DCDN 那条按同样的命名规则给出，
> **未逐字核对官方文档的授权表**，落地时请在控制台的 RAM 策略编辑器里搜一下
> `dcdn:SetDcdnDomainSSLCertificate` 确认。

### 4.4 腾讯云 CAM 最小权限

创建入口：<https://console.cloud.tencent.com/cam>（新建子用户 → 编程访问 → 保存 SecretId / SecretKey，
填进 Environment `PROD` 的 `CLOUDBASE_SECRET_ID` / `CLOUDBASE_SECRET_KEY`）

| 能力 | 需要的策略 | 说明 |
|---|---|---|
| 上传证书到腾讯云 SSL | `QcloudSSLFullAccess` | 官方文档给出的预设策略；也可收敛成自定义策略只给 `ssl:UploadCertificate` / `ssl:DescribeCertificates` / `ssl:DeleteCertificate` |
| CloudBase 域名绑定/重绑 | 云开发预设策略（如 `QcloudAccessForTCBRole`） | 走 `tcb:*` / `cdn:Tcb*` 系列 Action，**不需要额外的 SSL 策略** |
| DNSPod DNS-01 验证 | DNSPod 相关策略（如 `QcloudDNSPodFullAccess`） | 只在域名的 `dns_provider` 写 `tencentcloud` 时需要 |

> **不要用主账号密钥**，也不要用「环境级 API Key」：
> 环境级 API Key 走服务端固定模型，**没有为单个 Key 追加任意 CAM 策略的通道**，
> 大概率传不了证书。必须用子账号的 `SecretId/SecretKey`。

### 4.5 从早期版本迁移：凭据名对照表

如果你之前拿到的交付物里是下面这些旧名字，请按下表替换（旧名字在 workflow 与脚本里**已经全部移除**）：

| 旧名 | 新名 | 位置 |
|---|---|---|
| `ALIYUN_DNS_ACCESS_KEY_ID` / `ALIYUN_ACCESS_KEY_ID` | `ALIYUN_SECRET_ID_DNS` | Variables |
| `ALIYUN_DNS_ACCESS_KEY_SECRET` / `ALIYUN_ACCESS_KEY_SECRET` | `ALIYUN_SECRET_KEY_DNS` | Secrets |
| `ALIYUN_CERT_ACCESS_KEY_ID` | `ALIYUN_SECRET_ID_CERT`（可选，默认回退到 DNS 那对） | Variables |
| `ALIYUN_CERT_ACCESS_KEY_SECRET` | `ALIYUN_SECRET_KEY_CERT`（可选） | Secrets |
| `TENCENTCLOUD_SECRETID` / `TENCENTCLOUD_SECRET_ID` / `TENCENT_DNS_SECRET_ID` | `CLOUDBASE_SECRET_ID` | Variables |
| `TENCENTCLOUD_SECRETKEY` / `TENCENTCLOUD_SECRET_KEY` / `TENCENT_DNS_SECRET_KEY` | `CLOUDBASE_SECRET_KEY` | Secrets |
| `ACME_EMAIL`（Secret） | 删除，改在 `deploy/domains.yml` 的 `defaults.email` | 配置文件 |
| `CLOUDBASE_ENV_ID`（Secret） | `CLOUDBASE_ENV_ID`（Variable，非机密） | Variables |

---

## 5. 声明式配置 `deploy/domains.yml`

一个条目 = 一张证书。可以直接写中文域名，脚本会自动转 punycode。

```yaml
version: 1

defaults:
  server: letsencrypt          # acme.sh 默认 CA 是 ZeroSSL，这里显式用 Let's Encrypt
  key_length: 2048             # RSA 2048（腾讯云 SSL 文档示例只出现 RSA 私钥）
  dns_propagation_seconds: 60  # TXT 记录写入后等待多久再校验
  email: "CHANGE_ME@example.com"  # ⚠️ 必填: 改成你自己的邮箱，否则 workflow 直接报错。
                                  #    邮箱不是机密，所以刻意不放在 Secrets 里。

sync:                          # 目标公共配置，可被单个域名覆盖
  cloudbase: { enabled: false }              # 用 CloudBase 时再打开（需 env_id + 域名已绑定）
  aliyun:
    cas: { enabled: true, name_prefix: LE }  # 阿里云侧默认只开这个: 证书进证书库
    cdn: { enabled: false, domains: [] }     # 默认关闭；确有 CDN 加速域名再逐项打开
    dcdn: { enabled: false, domains: [] }    # 默认关闭；同上

domains:
  - name: example.com
    dns_provider: aliyun       # aliyun | tencentcloud
    wildcard: true             # 自动追加 *.example.com（泛域名只能 DNS-01）
    sync:
      cloudbase:
        enabled: true
        env_id: env-xxxxxxxx   # 非敏感，可直接写；也可留空用 CLOUDBASE_ENV_ID Variable
        domains: [example.com, www.example.com]
        routes_apply: false    # 触发路径是一次性动作，默认关闭
        routes: []
      aliyun:
        cas: { enabled: true, name_prefix: LE }
        cdn: { enabled: false, domains: [example.com] }   # 打开前请确认 6.2 的前置条件
        dcdn: { enabled: false, domains: [] }
```

### 5.1 字段说明

| 字段 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `version` | 是 | `1` | 配置格式版本，目前只支持 `1` |
| `domains[].name` | 是 | — | 域名（支持中文域名）；写 `*.example.com` 会自动识别为泛域名 |
| `domains[].dns_provider` | 是 | — | `aliyun` 或 `tencentcloud` |
| `domains[].wildcard` | 否 | `false` | 是否同时申请 `*.域名` |
| `domains[].email` | 否 | `defaults.email` | 该条目的 ACME 邮箱（最终必须是一个真实邮箱，见下） |
| `domains[].key_length` | 否 | `2048` | `2048`/`3072`/`4096`/`ec-256`/`ec-384`/`ec-521`（选 `ec-*` 时脚本自动加 `--ecc`） |
| `domains[].server` | 否 | `letsencrypt` | acme.sh `--server` 值 |
| `domains[].dns_propagation_seconds` | 否 | `60` | DNS 传播等待秒数，小型 DNS 商可加大 |
| `domains[].sync.*` | 否 | 继承 `sync` | 该域名的同步目标 |

### 5.2 配置校验

配置写错会在 workflow 的「解析配置并生成执行计划」这一步就失败，并指出具体位置，例如：

- `dns_provider` 不在支持列表里
- 启用了 `cdn` / `dcdn` 但没启用 `cas`（见下）
- 同一个域名写了两个条目（同一张证书请写在一个条目里）
- `key_length` 取值非法
- **邮箱没填**、或还是占位值 `CHANGE_ME@example.com`（邮箱只从本文件读，不从 Secrets 读）

```bash
# 本机校验 + 看计划
node scripts/ci/lib/config.cjs --config deploy/domains.yml --list
```

> **为什么启用 CDN/DCDN 必须同时启用 CAS？**
> 本方案让 CDN/DCDN 直接引用「数字证书管理服务(CAS)」里的证书 ID（`CertType=cas`），
> 证书在阿里云只存一份，避免多份副本各自过期。这条路也顺带解决了幂等：
> 上传这一步可以做指纹级去重，而部署这一步只是「改指针」，天然可重复。
> 如果你更想直接把证书内容传给 CDN（`CertType=upload`），
> 可以按 `scripts/ci/targets/aliyun-cdn.sh` 的写法扩展（第 6.2 节有参数说明）。

---

## 6. 同步目标清单

### 6.1 腾讯云 CloudBase（`cloudbase.domain`）

流程：**上传证书到腾讯云 SSL → 拿 `CertificateId` → `tcb domains edit` 重绑域名**。

| 项目 | 值 |
|---|---|
| 上传接口 | `ssl.UploadCertificate`（`--api-version 2019-12-05`，**必须显式传**，否则报 `version=undefined`） |
| 重绑接口 | `tcb domains edit <域名> --certid <CertificateId> -e <envId>`（底层 `ModifyHTTPServiceRoute`） |
| 为什么必须重绑 | CloudBase 存的是 **CertId 指针**，不是证书内容。LE 每次续期都是新证书 → 新 ID → 与旧 ID 必然不等 |
| 为什么用 `edit` 不用 `add` | 对已绑定域名再 `add` 会撞 `RESOURCE_ALREADY_EXISTS` |
| 首次绑定 | 本 workflow 处理的是**已绑定**域名。首次绑定仍需手工执行一次 `tcb domains add <域名> --certid <id> -e <envId> -y`（要求域名已完成 ICP 备案） |
| 幂等 | 上传带 `Repeatable: false`（同指纹不重复建），上传后先比对云端当前 CertId，相同则跳过重绑；重绑后再回读校验 |

配置项：

```yaml
cloudbase:
  enabled: true
  env_id: env-xxxxxxxx        # 或留空并用 Environment PROD 的 Variable CLOUDBASE_ENV_ID
  domains: [example.com]      # 留空 = 用本域名自身
  routes_apply: false         # 见下
  routes: []                  # 触发路径定义
  delete_old_cert: false      # 是否删掉上一张上传的证书（默认保留）
```

`routes_apply` 对应 `tcb routes add`（给域名加触发路径）。这是**一次性**动作，
重复执行会不断新增路由，所以默认关闭；只在首次配置或新增路径时临时改成 `true` 跑一次，
跑完改回 `false`。`tcb routes add` 没有 `-y`，会交互确认，脚本里已经用 `yes |` 喂它。

`delete_old_cert: true` 会删除**上一次由本 workflow 上传**的那张证书 ID
（记录在缓存的状态目录里）。默认关闭 —— 域名正在用的那张千万别删，
而且如果旧证书还被 CDN/CLB/WAF 引用，删除会影响到它们。

### 6.2 阿里云

**默认开关（先看这一段）**：`deploy/domains.yml` 里阿里云侧**默认只开 CAS 上传**，
`cdn` / `dcdn` 一律 `enabled: false`。原因很实际：
CAS 上传只是把证书放进证书库，不碰任何线上流量；而 CDN / DCDN 部署会真的改掉
正在服务的 HTTPS 证书，前提是「你确实有这些产品、域名确实接在它们后面、凭据确实有对应权限」。
逐项打开前请确认：

| 目标 | 默认 | 前置条件 |
|---|---|---|
| `aliyun.cas` | **开** | 凭据能调 `yundun-cert:UploadUserCertificate` / `yundun-cert:ListUserCertificateOrder`。默认复用的那对 `*_DNS` 密钥可能没有这些权限（见 [4.3](#43-阿里云-ram-最小权限以及为什么可能需要第二对密钥)） |
| `aliyun.cdn` | 关 | ① `aliyun.cas.enabled: true`；② `domains` 写的是**已接入 CDN 的加速域名**（不是源站域名）；③ 凭据有 `cdn:SetCdnDomainSSLCertificate`；④ 先只填一个域名试 |
| `aliyun.dcdn` | 关 | 同 CDN，权限换成 `dcdn:SetDcdnDomainSSLCertificate` |

先给结论表（**核实状态逐条标注**）：

| 目标 | API Action | Version | Endpoint | RAM Action | 能否直接引用 CAS 证书 ID | 本方案 |
|---|---|---|---|---|---|---|
| 数字证书管理服务（CAS，原 SSL 证书）上传 | `UploadUserCertificate` | `2020-04-07` | `cas.aliyuncs.com` | `yundun-cert:UploadUserCertificate` | — | ✅ 已实现 |
| CAS 查询证书列表 | `ListUserCertificateOrder` | `2020-04-07` | `cas.aliyuncs.com` | `yundun-cert:ListUserCertificateOrder` | — | ✅ 已实现（幂等判断用） |
| CDN 证书部署 | `SetCdnDomainSSLCertificate` | `2018-05-10` | `cdn.aliyuncs.com` | `cdn:SetCdnDomainSSLCertificate` | ✅ `CertType=cas` + `CertId` | ✅ 已实现 |
| DCDN（全站加速）证书部署 | `SetDcdnDomainSSLCertificate` | `2018-01-15` | `dcdn.aliyuncs.com` | `dcdn:SetDcdnDomainSSLCertificate`（按命名规则，未逐字核对授权表） | ✅ 同上 | ✅ 已实现 |
| SLB（传统型负载均衡）导入服务器证书 | `UploadServerCertificate` | `2014-05-15` | `slb.aliyuncs.com` | `slb:UploadServerCertificate` | ✅ 通过 `AliCloudCertificateId` + `AliCloudCertificateName` 直接引用 CAS 证书 | ⛔ 未实现 |
| SLB HTTPS 监听换证书 | `SetLoadBalancerHTTPSListenerAttribute` | `2014-05-15` | `slb.aliyuncs.com` | `slb:SetLoadBalancerHTTPSListenerAttribute` | ✅ `ServerCertificateId` | ⛔ 未实现 |
| ALB（应用型负载均衡）附加证书 | `AssociateAdditionalCertificatesWithListener` | `2020-06-16` | `alb.aliyuncs.com` | `alb:AssociateAdditionalCertificatesWithListener` | ✅ 参数为 `Certificates.N.CertificateId`（就是 CAS 证书 ID） | ⛔ 未实现 |
| ALB 创建/更新监听时指定证书 | `CreateListener` / `UpdateListener` | `2020-06-16` | `alb.aliyuncs.com` | `alb:CreateListener` / `alb:UpdateListener` | ✅ `Certificates` / `CaCertificates` 数组 | ⛔ 未实现 |
| ESA 边缘安全加速 / WAF / OSS / API 网关等 | — | — | — | — | 未逐一核实 | ⛔ 未实现 |

「核实状态」说明：

- ✅ **已核实**：读过阿里云官方 API 文档页，或阿里云官方 OpenAPI SDK 仓库
  （`aliyun/aliyun-openapi-python-sdk`）里对应产品版本的 request 类源码。
- `cas.aliyuncs.com` / `cdn.aliyuncs.com` / `dcdn.aliyuncs.com` / `slb.aliyuncs.com`
  四个 endpoint 均已实际连通性验证（返回 400 说明服务存在）。
- DCDN 的 RAM Action、ALB 的 endpoint 主机名属于按规则给出，未逐字核对官方页面。

**为什么只实现 CAS / CDN / DCDN？**
这两个平台的心智模型是一致的 —— **先把证书放进证书库，再让别的资源引用 ID**：

```
阿里云:  UploadUserCertificate(CAS) ──► CertId ──► SetCdnDomainSSLCertificate(CertType=cas)
腾讯云:  ssl.UploadCertificate    ──► CertId ──► tcb domains edit --certid
```

SLB/ALB 也遵循同一模型（都能直接引用 CAS 的证书 ID），但「让证书真正生效」还需要
额外指定监听（`ListenerId` / `LoadBalancerId` + `ListenerPort`），配置面更大、
需要用户提供更多资源标识。因此本方案把它们列清楚、留好扩展点，
等你确实需要时按同一套 `scripts/ci/targets/*.sh` 契约加一个目标脚本即可
（契约见 `scripts/ci/sync-cert.sh` 头部注释）。

**CAS 幂等是怎么做的（重要）：**

- CAS 的 `Name` 在同一账号下**不允许重复**，而 LE 每次续期都是新证书：
  固定名字第二次会失败，用时间戳又会每次运行都产生垃圾证书。
- 做法是把证书指纹写进名字：`Name = "<前缀>-<域名>-<SHA256(叶子证书 DER) 前12位>"`。
  同一张证书重复运行 → 名字相同 → 先查列表命中 → 直接复用 `CertId`，**不上传**。
- 查询用 `ListUserCertificateOrder`（`OrderType=UPLOAD`），同时比对 `Name` 和 `Sha2` 字段双保险。
- 如果上传仍因重名失败（并发/查询滞后），会退回到「按名字重查再复用」，而不是让流水线失败。

---

## 7. 幂等性与状态管理

### 7.1 acme.sh 状态缓存（必读）

GitHub 的 runner 是**一次性**的，`~/.acme.sh` 不持久化。
如果不缓存，每次运行都会认为「这个域名从没签过」从而**重新签发一张新证书** ——
Let's Encrypt 对「同一组域名的重复证书」限制为 **每周 5 张**，很快就会撞限流。

所以 workflow 用 `actions/cache` 缓存 `~/.acme.sh` 与 `~/.x-certbot-state`：

```yaml
key: acme-${{ github.ref_name }}-${{ hashFiles('deploy/**') }}-${{ github.run_id }}
restore-keys: |
  acme-${{ github.ref_name }}-${{ hashFiles('deploy/**') }}-
  acme-${{ github.ref_name }}-
  acme-
```

> ⚠️ **安全提示（请认真看这一条）**
> `~/.acme.sh` 里既有 ACME 账户密钥，也有已签发证书的**私钥**。
> GitHub 的 Actions cache 是**仓库级别**的，同仓库内的 workflow（包括来自 PR 的运行）
> 在满足条件时可以恢复它。因此：
> - **建议本仓库设为私有仓库**；
> - 如果你的仓库是公开的，请评估这个风险，或者干脆不用缓存、
>   改成在自托管 runner / 固定机器上跑（此时 `~/.acme.sh` 天然持久化，
>   把 workflow 里的 cache 步骤删掉即可）。
>
> 缓存 key 里带上 `github.run_id`，是为了让每次运行都能写入一份新的缓存快照
> （GitHub 的缓存不可覆盖），`restore-keys` 前缀保证总是恢复最新的一份。
> GitHub 会按 10 GB 上限自动淘汰旧缓存，日常使用无需手工清理。

### 7.2 每个目标各自的幂等依据

| 目标 | 重复运行会发生什么 |
|---|---|
| acme.sh | 已存在域名配置 → 走 `--renew`，没到续期窗口直接跳过（退出码 2）。脚本把退出码 2 识别为「跳过」而不是失败 |
| CloudBase | 上传带 `Repeatable: false`（同指纹不重建）→ 再比对云端当前 `CertId`，相同则跳过重绑 |
| 阿里云 CAS | 证书名称带指纹 → 先查列表命中就复用 `CertId`，不上传 |
| 阿里云 CDN / DCDN | 是「设置型」接口，只是把域名指针指到同一个 CAS `CertId`，重复调用结果一致，不产生新资源 |

### 7.3 为什么「失败可自愈」

因为每次运行都会重新同步当前证书，所以：
**某次运行里 CDN 同步失败 → 下一个定时周期会自动重试，不需要重新签发证书。**
在 Actions 页面点「Re-run」也一样有效（同步是幂等的，不会重复上传）。

---

## 8. 手动演练（必做）

**别等 60 天后才发现坏了。** 按下面顺序演练，每一步都能回退。

### 8.1 第一步：干跑（不碰任何云接口）

Actions → **Certificate Sync (ACME → CloudBase / Aliyun)** → Run workflow：

| 输入 | 值 |
|---|---|
| `dry_run` | ✅ 勾选 |
| `domain` | 留空（或先填一个域名） |

这一步只解析配置、打印计划、生成签名自检结果。`dry_run` 会跳过凭据预检和所有云调用。

### 8.2 第二步：只同步、不申请（验证云平台链路）

| 输入 | 值 |
|---|---|
| `mode` | `sync-only` |
| `domain` | `example.com`（先只跑一个） |

`sync-only` 会用缓存里已有的证书刷新稳定路径并执行同步，
**不会向 Let's Encrypt 发起任何签发/续期请求**。
这一步能把 CAS / CDN / CloudBase 的权限、参数、幂等分支全都走通。

### 8.3 第三步：强制续期演练（验证 acme.sh 与钩子的真实路径）

| 输入 | 值 |
|---|---|
| `mode` | `full` |
| `domain` | `example.com`（**务必只填一个**） |
| `force_renew` | ✅ 勾选 |

等价的命令行语义是 acme.sh 的：

```bash
~/.acme.sh/acme.sh --renew -d example.com --force
```

> ⚠️ 这会**真的重新签发**一张证书，消耗 Let's Encrypt 的速率限制
> （同一组域名每周 5 张重复证书）。所以请只对**一个**域名演练，
> 而且不要在一天里反复点。日常运行**不要**勾选 `force_renew`。

### 8.4 第四步：确认云端真的换了证书

CloudBase 侧：看 Step Summary 里 `cloudbase.domain` 是否 `success`，
以及日志里有没有 `云端已绑定该证书，无需重绑（幂等跳过）`（说明第二次没有重复操作）。
手工核对可以用：

```bash
tcb login --apiKeyId "$CLOUDBASE_SECRET_ID" --apiKey "$CLOUDBASE_SECRET_KEY" -y
tcb domains ls -e "$CLOUDBASE_ENV_ID" --filter "Domain=example.com" --json -y
# 对比 CertId 是否等于日志里 "腾讯云 SSL CertificateId = ..." 的那个值
```

阿里云侧：CAS 控制台的证书列表里，证书名结尾的 12 位指纹应该随新证书变化；
CDN 域名详情里的 HTTPS 证书应该指向新的证书 ID。

### 8.5 演练完记得做的事

- 把 `force_renew` 关掉（它只在手动触发时才生效，不会影响定时任务）
- 如果临时打开过 `routes_apply`，改回 `false`
- 在 CAS 控制台里清理演练产生的多余证书（本方案不会自动删证书）

---

## 9. 手动触发与运行模式

```yaml
on:
  schedule:
    - cron: '17 3 * * *'   # 每天 03:17 UTC（北京时间 11:17）
  workflow_dispatch:       # 手动触发
```

定时任务刻意避开整点：GitHub 的定时任务在整点最拥挤，容易延迟甚至被丢弃。
每天跑一次即可 —— acme.sh 自己判断是否需要续期。

`workflow_dispatch` 的输入：

| 输入 | 说明 |
|---|---|
| `domain` | 只处理指定域名（留空 = 全部；多个用逗号分隔） |
| `mode` | `full`（签发 + 同步，默认）/ `sync-only`（只同步）/ `issue-only`（只签发） |
| `targets` | 只跑这些目标 id，逗号分隔，如 `cloudbase.domain,aliyun.cas` |
| `force_renew` | 强制续期（演练用，见第 8.3 节） |
| `dry_run` | 只解析配置，不调用任何云接口 |

还有几个 Variable 可以配。它们既可以放在环境 `PROD` 下，也可以放在仓库级
`Settings → Secrets and variables → Actions → Variables`（环境级优先）：

| Variable | 默认 | 说明 |
|---|---|---|
| `DOMAINS_CONFIG` | `deploy/domains.yml` | 配置文件路径，想用别的文件时改它 |
| `ACME_SH_REF` | `master` | acme.sh 的 git ref，**生产建议钉一个 tag**，避免上游 master 变动影响你 |
| `ALIYUN_CERT_REGION` | `cn-hangzhou` | CAS 证书地域（国际站可用 `ap-southeast-1`） |
| `CLOUDBASE_ENV_ID` | 空 | CloudBase 环境 ID（非机密）。留空时请直接写在 `deploy/domains.yml` 的 `env_id` |

---

## 10. 本地零凭据演练

新增了一套完整的 stub 演练，**不联网、不用真凭据**，把整条链路跑通并断言关键行为：

```bash
bash scripts/ci/selftest/run.sh
```

它用假的 `acme.sh`、假的 `tcb`、以及一个本机 HTTP 版的「假阿里云端点」（会独立复算签名并比对），
覆盖：

- 所有 shell 脚本 `bash -n`、所有 `.cjs` 文件 `node --check`
- `deploy/domains.yml` 与 workflow 的 YAML 可解析性
- **阿里云签名实现与官方文档给出的向量逐字节一致**
- **凭据名映射**：workflow 里必须存在 `environment: PROD`、
  四个配置项必须分别走 `vars.*` / `secrets.*`，且旧凭据名（含 `ACME_EMAIL`）不允许残留
- 邮箱只从配置文件读：没填 / 保留占位值时必须报错
- 端到端：`run-all.sh` → `issue-cert.sh`（假 acme.sh）→ `sync-cert.sh` → 各目标 → 假云端
- 幂等：跑第二遍不重复上传证书、不重复重绑域名
- 失败定位：目标不可达时退出码与 `results.jsonl` 能指明是哪个域名、哪个平台
- 负例：缺凭据 / 配置非法 / 缺 CAS 证书 ID 时都明确报错
- 中文域名转 punycode
- `dry_run` 真的不发请求

依赖：`bash` + `node` + `openssl`（缺 `js-yaml` 时会尝试 `npm install` 自动补上）。
加 `KEEP_WORK=1` 可以保留临时目录查看日志。

---

## 11. 故障排查

| 现象 | 原因与处理 |
|---|---|
| 日志里 `version=undefined` | `tcb api` 调用缺 `--api-version`。本仓库脚本已显式传 `2019-12-05` |
| `RESOURCE_ALREADY_EXISTS` | 对已绑定域名用了 `domains add`。脚本用的是 `domains edit`；首次绑定才需要手工 `add` |
| `FailedOperation.CertificateMatchError` | 证书与私钥不配对。脚本会在上传前用 openssl 自检并直接失败 |
| 阿里云返回 `CertificateNameRepeat` | 证书名重复。脚本会自动重查并复用已有证书 ID；若持续出现，说明有人手工建过同名证书 |
| 阿里云返回 `Forbidden` / `NoPermission` | RAM 权限不足。对照 [4.3 节](#43-阿里云-ram-最小权限以及为什么可能需要第二对密钥) 的 Action 列表。**默认复用的是 DNS 那对密钥，它通常没有 CAS/CDN/DCDN 权限**；此时另建 RAM 用户并配置 `ALIYUN_SECRET_ID_CERT` / `ALIYUN_SECRET_KEY_CERT`。失败日志里会打印「需要 RAM 权限: xxx」 |
| 所有 `${{ vars.* }}` / `${{ secrets.* }}` 都是空字符串 | job 少了 `environment: PROD`（或 Environment 名字大小写不对）。此时凭据预检会一次性列出所有缺失项 |
| 腾讯云 SSL 上传报权限错误 | 子账号没挂 `QcloudSSLFullAccess`；确认不是用「环境级 API Key」登录的 |
| DNS 验证失败 | 加大 `dns_propagation_seconds`；确认 DNS 密钥所属账号能改这个域名的解析 |
| `acme.sh` 报 `crontab doesn't exist` | 与本 workflow 无关（我们不用 cron 驱动续期），可以忽略 |
| 每次运行都重新签发证书 | 说明 `~/.acme.sh` 缓存没恢复成功。检查 cache 步骤日志与 `restore-keys` |
| 域名顺序 / 重复 | 同一个域名只能有一个条目；一张证书的多个 SAN 写在同一条目的 `cert_names` 里（`wildcard: true` 会自动加泛域名） |
| 想看某个域名到底怎么了 | Step Summary 有「同步目标明细」表；日志按域名分成了 `::group::`，折叠起来看很快 |

---

## 12. 验证边界（哪些验证过、哪些没有）

诚实交代，避免过度信任：

**已验证**

- ✅ 所有 shell 脚本 `bash -n` 通过；所有 JS 文件 `node --check` 通过
- ✅ `shellcheck -S warning` 无告警；新增 workflow 通过 `actionlint`（含 run 块的 shellcheck）
- ✅ 阿里云 RPC 签名实现与官方文档给出的向量一致
  （文档向量：`AccessKeyId=testid` / `AccessKeySecret=testsecret` → `9NaGiOspFP5UPcwX8Iwt2YJXXuk=`）
- ✅ 端到端 stub 演练 53 项断言全部通过，覆盖幂等、失败定位、DRY-RUN、配置校验、
  中文域名、**凭据名映射（`environment: PROD` + 四个配置项）**
- ✅ 四个阿里云 endpoint 主机名实际可连通

**未验证（没有真实凭据，也没对真实接口发过请求）**

- ❌ 未向 Let's Encrypt 真实签发过、未真实写入过 DNS TXT 记录
  （真实签发路径依赖 acme.sh 官方 `dns_ali` / `dns_tencent` 插件，本项目没有改它们）
- ❌ 未调用过真实的腾讯云 SSL `UploadCertificate`、`tcb domains edit`、`tcb routes add`
- ❌ 未调用过真实的阿里云 `UploadUserCertificate` / `ListUserCertificateOrder` /
  `SetCdnDomainSSLCertificate` / `SetDcdnDomainSSLCertificate`
- ⚠️ CAS 的 `Sha2` 字段与「本地对叶子证书 DER 求 SHA-256」是否完全同源，
  依据的是文档描述 + 示例格式（64 位大写十六进制），**未与真实响应比对过**。
  为此加了双保险：同时比对证书 `Name`；上传重名失败时还会重查复用，
  所以即使 `Sha2` 的假设不成立，也不会重复上传或产生垃圾证书。
- ⚠️ 阿里云 RPC 请求使用 `POST + application/x-www-form-urlencoded`，
  这是官方文档明确列出的 formData 形式；若真实环境不认，
  可以用 `ALIYUN_API_TRANSPORT=query` 切成「参数放 URL」的写法（代价是 URL 会比较长）。

**第一次真实运行时请重点看**

1. `tcb domains ls --json` 的真实字段名（脚本用的是「递归找 `Domain` → `CertId`」，
   对响应结构不敏感，但值得肉眼确认一次）；
2. CAS 列表返回的 `Sha2` 是否与日志里打印的 12 位指纹前缀一致；
3. `tcb api ssl UploadCertificate` 不被 `api_blacklist` 拦截（该模块只拦 DB 账号密码类操作，不含 ssl）。

---

## 13. 新增文件清单

本方案**只新增文件，没有修改或删除任何现有文件**。

| 路径 | 作用 |
|---|---|
| `.github/workflows/cert-sync.yml` | 主 workflow：定时 + 手动触发，逐域名串行处理，输出 Step Summary |
| `deploy/domains.yml` | 声明式配置：域名、DNS 服务商、泛域名、同步目标（**不含任何密钥**） |
| `scripts/ci/lib/console_compat.sh` | 复用 `scripts/console_utils.sh`，找不到时提供同名兜底函数 |
| `scripts/ci/lib/config.cjs` | 配置解析 / 校验 / punycode 归一化 / 生成执行计划；同步目标注册表 |
| `scripts/ci/lib/aliyun-api.cjs` | 阿里云 OpenAPI 调用器（RPC V1 签名，node 内置 crypto，零第三方依赖；带 `--selftest`） |
| `scripts/ci/issue-cert.sh` | 单域名签发/续期 + `--install-cert` 到稳定路径 + 证书自检 |
| `scripts/ci/sync-cert.sh` | 单域名同步调度器：按目标分发、隔离失败、记录结果 |
| `scripts/ci/run-all.sh` | 逐域名主循环（签发 → 同步），聚合失败 |
| `scripts/ci/preflight.sh` | 凭据预检：按执行计划列出缺失的 Secret 名 |
| `scripts/ci/summary.cjs` | 把结果渲染成 GitHub Step Summary |
| `scripts/ci/targets/cloudbase.sh` | 腾讯云 CloudBase 目标 |
| `scripts/ci/targets/aliyun-cas.sh` | 阿里云 CAS 目标（指纹级幂等） |
| `scripts/ci/targets/aliyun-cdn.sh` | 阿里云 CDN / DCDN 目标（共用实现） |
| `scripts/ci/selftest/run.sh` | 零凭据端到端演练编排 |
| `scripts/ci/selftest/stubs/acme.sh` | 假 acme.sh（复现「退出码 2 = 跳过续期」等真实行为） |
| `scripts/ci/selftest/stubs/tcb.cjs` | 假 CloudBase CLI |
| `scripts/ci/selftest/stubs/aliyun-server.cjs` | 假阿里云端点（独立复算签名并校验） |
| `docs/07-github-actions-cert-sync.md` | 本文档 |

### 建议但**未擅自修改**的文件

按「只新增、不改动」的约定，以下改动需要你自己决定，本方案没有动手：

1. **`.gitignore`**：现有内容为 `.DS_Store` / `.vscode` / `.env`。
   本方案的运行产物都在 `$RUNNER_TEMP` 与 `$HOME` 下，**不会落到仓库里**，
   所以`.gitignore` 严格来说不需要改。但如果你想在本机跑演练，可以自行追加：

   ```gitignore
   # 本机演练 / 本地运行产生的文件
   certbot_output.log
   .x-certbot-state/
   node_modules/
   ```

2. **`README.md` 的文档索引**：可以加一行指向本文档（`docs/07-github-actions-cert-sync.md`）。
3. **`docs/04-usage-guide.md` 的 GitHub Actions 章节**：可以补一句
   「多域名集中管理 + 云平台同步见 docs/07」。
