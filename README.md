# X Certbot

一个基于 Docker 的自动化解决方案，通过 Let's Encrypt 获取和管理 SSL/TLS 证书，支持多种云服务提供商和验证方式。

## 功能特点

- 使用 Let's Encrypt 自动获取免费 SSL/TLS 证书
- **多云平台支持**：
  - 阿里云 DNS API
  - 腾讯云 DNS API
  - 可轻松扩展支持其他云平台
- **多种验证方式**：
  - DNS-01 验证（支持通配符证书）
  - HTTP-01 验证（不支持通配符证书）
- **中文域名支持**：
  - 自动 punycode 解码
  - 支持中文域名和国际化域名 (IDN)
  - 兼容现有英文域名
- **高度可定制**：
  - 支持自定义验证钩子
  - 支持自定义清理钩子
  - 支持自定义部署钩子
  - [详细的钩子执行流程](docs/05-development-guide.md#8-钩子脚本与自动化流程)
- **灵活的证书管理**：
  - 支持多域名证书申请和管理
  - 完全自定义域名参数格式
  - 可配置证书输出目录结构
  - 可选生成证书元数据文件
- **CI/CD 友好**：
  - 详细的输出日志
  - 多种运行模式
  - 可配置完成后自动关闭或保持运行
- **免 Docker 的 GitHub Actions 路线**：直接用 `acme.sh` + GitHub Actions 调度，
  证书续期后自动同步到腾讯云 CloudBase 与阿里云 CAS / CDN / DCDN，无需维护任何机器
  （与下面「在容器里跑」的 GitHub 用法是两条独立路线，见 [GitHub Actions 自动化（免 Docker）](#方案三--github-actions--acmesh免-docker)）
- **自动化功能**：
  - 使用 cron 任务自动定期续期证书
  - 支持通过 Webhook 通知证书更新状态
  - 支持证书更新后执行自定义脚本
- **简化配置**：
  - 支持通过 .env 文件或环境变量配置
  - 详细的配置说明和错误提示
- **美化控制台输出**：
  - 彩色输出，区分不同类型的信息
  - 使用 emoji 图标增强可读性
  - 格式化输出，使信息更加清晰
  - 可通过环境变量控制颜色和 emoji 的显示

## 方案一览：选一种即可

本项目的证书自动化有三条路，**按你的运维条件选一条**，不需要都看：

| | 方案 | 运行在哪 | 适合 | 证书落地方式 |
| --- | --- | --- | --- | --- |
| **方案一** | Docker 容器 | 你自己的机器 / 服务器 | 有常驻机器，想让容器自己按 cron 续期 | 挂载目录，再用自定义钩子分发 |
| **方案二** | Docker 容器 + GitHub Actions | GitHub 托管的 runner | 不想维护机器，但仍想用容器里现成的 certbot 与钩子 | 工作流里再部署到服务器 |
| **方案三** | **GitHub Actions + acme.sh**（免 Docker） | GitHub 托管的 runner | 证书只给云服务用（CloudBase / 阿里云 CDN、DCDN、证书库） | 工作流直接同步到云平台 |

- **方案一**见下面的[快速开始](#方案一--docker-容器自备机器)
- **方案二**见 [使用指南 · 场景三](docs/04-usage-guide.md#4-场景三github-actions-自动化)
- **方案三**见 [方案三](#方案三--github-actions--acmesh免-docker)，完整配置与排错见 [docs/07](docs/07-github-actions-cert-sync.md)

> 三者互不依赖：方案三不读方案一的 `.env`，也不碰容器。

## 方案一 · Docker 容器（自备机器）

> **详细使用指南**：请参阅 [使用指南](docs/04-usage-guide.md) 获取完整的使用说明、配置选项和故障排除信息。

### 使用方式

X Certbot 支持三种主要使用场景：

1. **无 Docker 环境直接运行**：适用于没有安装 Docker 的服务器
2. **Docker 容器运行（推荐）**：适用于已安装 Docker 的服务器
3. **GitHub Actions 自动化**：适用于希望完全自动化证书管理的用户

### 快速示例

#### Docker 方式（推荐）

使用 .env 文件（最简单的方式）：

```bash
# 1. 创建配置文件
curl -o .env https://raw.githubusercontent.com/aispin/x.certbot/main/docs/.env.example
# 编辑 .env 文件，填入您的配置

# 2. 运行容器
docker run -d \
  -v $(pwd)/.env:/.env \
  -v $(pwd)/certs:/etc/letsencrypt/certs \
  --name x.certbot \
  aiblaze/x.certbot:latest
```

使用环境变量：

```bash
docker run -d \
  -e ALIYUN_REGION="cn-hangzhou" \
  -e ALIYUN_ACCESS_KEY_ID="your-access-key-id" \
  -e ALIYUN_ACCESS_KEY_SECRET="your-access-key-secret" \
  -e DOMAIN_ARG="-d example.com -d *.example.com" \
  -e EMAIL="your-email@example.com" \
  -e CHALLENGE_TYPE="dns" \
  -e CLOUD_PROVIDER="aliyun" \
  -v /path/to/certificates:/etc/letsencrypt/certs \
  --name x.certbot \
  aiblaze/x.certbot:latest
```

#### 无 Docker 环境

```bash
# 一键安装
curl -fsSL https://raw.githubusercontent.com/aispin/x.certbot/main/install.sh | sudo bash

# 编辑配置
sudo nano /etc/xcertbot/.env

# 获取证书
sudo xcertbot
```

#### GitHub Actions

请参阅 [使用指南 - GitHub Actions 自动化](docs/04-usage-guide.md#4-场景三github-actions-自动化) 获取详细设置步骤。

> **注意**：在 GitHub Actions 中使用 X Certbot 时，建议使用 `2>&1 | tee certbot_output.log` 来捕获所有输出并进行日志处理。请参阅 [GitHub Actions 中的日志输出处理](docs/04-usage-guide.md#542-github-actions-中的日志输出处理) 了解详细信息。

### 控制台输出配置

X Certbot 提供了美化的控制台输出，可以通过以下环境变量进行配置：

```bash
# 禁用彩色输出（默认启用）
NO_COLOR=true

# 禁用 emoji 图标（默认启用）
NO_EMOJI=true

# 启用调试输出（默认禁用）
DEBUG=true
```

这些配置可以添加到 `.env` 文件中，或者作为 Docker 运行时的环境变量传入。

## 方案三 · GitHub Actions + acme.sh（免 Docker）

上面「快速开始」是在本机或 CI 里跑 Docker 容器；这一条是**另一条独立路线**：直接用 GitHub
Actions 调度 `acme.sh`，不需要 Docker、不需要常驻机器，证书到期前自动续期并同步到你用的云平台。

| | Docker 方案 | 本方案 |
| --- | --- | --- |
| 运行位置 | 本机 / 服务器 / CI 里的容器 | GitHub Actions（托管 runner） |
| ACME 客户端 | certbot | acme.sh（阿里云 DNS 插件为官方内置） |
| 续期触发 | 容器内 cron | GitHub Actions `schedule` |
| 证书落地 | 挂载目录 + 自定义钩子 | 直接同步到腾讯云 CloudBase / 阿里云 CAS、CDN、DCDN |
| 适合 | 跑在自有服务器上 | 完全不维护机器，证书只给云服务用 |

### 快速开始

1. **建 Environment 与凭据**

   仓库 → `Settings` → `Environments` → 新建名为 **`PROD`** 的环境（名称必须一致），
   然后在里面按下面的表格添加 **Variables** 和 **Secrets**。

   > ⚠️ 工作流的 job 声明了 `environment: PROD`。若环境名不同，凭据会**静默取成空字符串**，
   > 不会报「未配置」，而是直接调云 API 失败。

2. **改 `deploy/domains.yml`**

   至少填两处：`defaults.email`（ACME 账户邮箱）和 `domains:` 下你要管理的域名。
   **邮箱是硬校验**：留着占位值工作流会在「解析配置」步骤直接失败（这是刻意的，
   避免用空邮箱静默注册 ACME 账户）。

3. **推送后手动跑一次**

   `Actions` → `Cert Sync` → `Run workflow`。首次建议把 `dry_run` 打开，确认计划无误再关掉。

### 需要的 Variables 与 Secrets

在 **Environment `PROD`** 下创建。ID 放 Variables、Key 放 Secrets：

| 名称 | 类型 | 用途 | 在哪创建 |
| --- | --- | --- | --- |
| `ALIYUN_SECRET_ID_DNS` | **Variable** | 阿里云 AccessKeyId，做 DNS-01 验证（增删 `_acme-challenge` TXT） | [RAM 控制台](https://ram.console.aliyun.com/users) 新建用户，勾选「OpenAPI 调用访问」 |
| `ALIYUN_SECRET_KEY_DNS` | **Secret** | 与上面配对 | 同上，AccessKey 只显示一次 |
| `ALIYUN_SECRET_ID_CERT` | **Variable** | 阿里云 AccessKeyId，用于证书同步（CAS / CDN / DCDN） | 同上（可与 DNS 用同一个用户，见下方权限表） |
| `ALIYUN_SECRET_KEY_CERT` | **Secret** | 与上面配对 | 同上 |
| `CLOUDBASE_ENV_ID` | **Variable** | 腾讯云 CloudBase 环境 ID | [CloudBase 控制台](https://console.cloud.tencent.com/tcb) 环境概览 |
| `CLOUDBASE_SECRET_ID` | **Variable** | 腾讯云 SecretId | [CAM 控制台](https://console.cloud.tencent.com/cam) 新建**子账号** |
| `CLOUDBASE_SECRET_KEY` | **Secret** | 腾讯云 SecretKey | 同上 |

**腾讯云 DNS 验证**（域名 DNS 在 DNSPod 时）另需 `TENCENT_SECRET_ID` / `TENCENT_SECRET_KEY`
（前者 Variable、后者 Secret）。

> `ALIYUN_SECRET_ID_CERT` / `ALIYUN_SECRET_KEY_CERT` 可以不配：不配时脚本回退用 `*_DNS` 那一对。
> 但只给 DNS 权限的密钥调证书接口会被拒（`Forbidden` / `NoPermission`），所以**建议单独配**。

### 需要的权限策略

**阿里云**——DNS 验证那个用户：

| 策略 / Action | 用途 |
| --- | --- |
| `AliyunDNSFullAccess`（或自定义 `alidns:DescribeDomainRecords` / `AddDomainRecord` / `DeleteDomainRecord`） | 增删 `_acme-challenge` TXT 记录 |

证书同步那个用户：

| 策略 | 用途 |
| --- | --- |
| `AliyunYundunCertReadOnlyAccess` | 读取证书列表（幂等判断用） |
| `AliyunYundunCertFullAccess` | 上传证书到证书库（CAS） |
| `AliyunCDNFullAccess` | 部署证书到 CDN |
| `AliyunDCDNFullAccess` | 部署证书到全站加速 DCDN |

> 只用 CAS（不上 CDN/DCDN）也建议保留前两个；后两个按你是否在用对应产品决定。

**腾讯云**——子账号需要：

| 策略 | 用途 |
| --- | --- |
| `QcloudSSLFullAccess` | 上传证书到腾讯云 SSL、查询证书列表 |
| `QcloudAccessForTCBRole` | CloudBase 相关操作（官方为该产品提供的预设策略） |

> ⚠️ **不要用主账号密钥**：腾讯云 API 密钥默认可操作账号下全部资源。
> 另外**不要用 CloudBase 的「环境级 API Key」**——它没有追加 CAM 策略的通道，
> 传证书会失败，必须用子账号的 SecretId/SecretKey。

### 配置：`deploy/domains.yml`

所有行为都由这一个文件驱动，**不含任何密钥**。常用字段：

| 字段 | 说明 |
| --- | --- |
| `defaults.email` | ACME 账户邮箱，必填 |
| `defaults.key_length` | 密钥长度，默认 2048（RSA） |
| `domains[].name` / `dns_provider` / `wildcard` | 域名、DNS 服务商（`aliyun` / `tencentcloud`）、是否泛域名 |
| `domains[].sync.cloudbase.enabled` / `env_id` / `domains` | 同步到 CloudBase：上传 SSL 并把证书重绑到这些域名 |
| `domains[].sync.cloudbase.routes_apply` | 是否同时管理触发路径。**默认 false**，首次绑定请在控制台或 CLI 做，避免误改线上路由 |
| `domains[].sync.aliyun.cas` | 上传到阿里云证书库 |
| `domains[].sync.aliyun.cdn` / `.dcdn` | 部署到 CDN / DCDN（默认关闭） |
| `domains[].sync.*.delete_old_cert` | 换新后是否删除旧证书，**默认保留**（避免误删仍被其他资源引用的证书） |

### 验证与排错

- **第一次运行请把 `dry_run` 打开**，它会打印将要执行的动作而不调用任何写接口
- 运行结束后看 **Step Summary**：里面按域名列出每个同步目标的结果
- 常见情况见 [docs/07-github-actions-cert-sync.md](docs/07-github-actions-cert-sync.md) 的排错章节，
  包括：阿里云返回 `Forbidden`（权限不足，对照上面的策略表）、
  CloudBase 报证书不存在、DNS 传播慢导致验证失败（调大 `dns_propagation_seconds`）
- **证书换新后 CloudBase 不会自动生效**：它存的是证书 ID 指针，所以工作流每次都会显式重绑——
  这也是本方案每次运行都做全量同步（而不只在续期时同步）的原因

> ⚠️ 本工作流的设计与脚本**尚未对真实云 API 发起过请求**，验证方式是零凭据的 stub 端到端演练
> （覆盖首次签发、幂等重跑、失败定位、dry-run）。第一次真实运行请当作首次验证。

## 文档

- [系统架构](docs/01-system-architecture.md)
- [技术规范](docs/02-technical-specifications.md)
- [组件实现](docs/03-component-implementation.md)
- [使用指南](docs/04-usage-guide.md)
- [开发指南](docs/05-development-guide.md)
- [中文域名支持](docs/06-chinese-domain-support.md)
- [GitHub Actions 自动化（免 Docker）](docs/07-github-actions-cert-sync.md)：配置、权限与排错

## 许可证

[MIT License](LICENSE)
