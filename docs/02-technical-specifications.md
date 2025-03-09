# X Certbot - 技术规格

## 环境需求

### 硬件要求
- 最小化配置：
  - CPU: 1核心
  - 内存: 512MB
  - 磁盘空间: 100MB

### 软件需求
- Docker 运行环境
- 互联网连接（用于与 Let's Encrypt 和阿里云 API 通信）
- 宿主机用于执行自定义脚本（可选）

## 容器镜像规范

### 基础镜像
- Alpine Linux 最新版本（轻量级基础）

### 软件包依赖
1. **核心包**:
   - certbot: Let's Encrypt 证书客户端
   - bash: 脚本运行环境
   - python3: 脚本和 certbot 运行环境
   - py3-pip: Python 包管理器
   - jq: JSON 解析工具

2. **构建依赖**:
   - gcc
   - musl-dev
   - python3-dev
   - libffi-dev
   - openssl-dev
   - make

3. **Python 依赖**:
   - aliyun-python-sdk-core
   - aliyun-python-sdk-alidns

4. **外部工具**:
   - aliyun-cli: 阿里云命令行工具

## 配置规范

### 环境变量
| 变量名 | 必选 | 默认值 | 描述 |
|-------|------|-------|------|
| ALIYUN_REGION | 是 | - | 阿里云区域 |
| ALIYUN_ACCESS_KEY_ID | 是 | - | 阿里云访问密钥 ID |
| ALIYUN_ACCESS_KEY_SECRET | 是 | - | 阿里云访问密钥 Secret |
| DOMAIN_ARG | 是 | - | 完整域名参数，如 -d x.com -d *.x.com |
| EMAIL | 是 | - | 证书所有者的电子邮件地址 |
| CRON_SCHEDULE | 否 | 0 0 * * 1,4 | 证书续期的 cron 表达式 |
| DNS_PROPAGATION_SECONDS | 否 | 60 | DNS 记录传播等待时间（秒） |

### 配置文件
支持通过 `.env` 文件提供环境变量，文件格式如下：
```
ALIYUN_REGION=cn-hangzhou
ALIYUN_ACCESS_KEY_ID=your-access-key-id
ALIYUN_ACCESS_KEY_SECRET=your-access-key-secret
DOMAIN_ARG=-d example.com -d *.example.com
EMAIL=your-email@example.com
CRON_SCHEDULE=0 0 * * 1,4
DNS_PROPAGATION_SECONDS=60
```

## 目录结构

```
/
├── usr/local/bin/
│   ├── entrypoint.sh         # 主入口脚本
│   ├── plugins/
│   │   ├── dns/              # DNS 验证插件目录
│   │   │   ├── aliyun.sh     # 阿里云 DNS 验证脚本
│   │   │   └── tencentcloud.sh # 腾讯云 DNS 验证脚本
│   │   └── http/             # HTTP 验证插件目录
│   │       ├── aliyun.sh     # 阿里云 HTTP 验证脚本
│   │       ├── tencentcloud.sh # 腾讯云 HTTP 验证脚本
│   │       └── common.sh     # 通用 HTTP 验证脚本
│   └── scripts/
│       ├── deploy-hook.sh    # 证书部署脚本
│       └── (其他脚本)
├── etc/letsencrypt/
│   └── certs/                # 证书输出目录
├── opt/venv/                 # Python 虚拟环境
├── host-scripts/             # 宿主机脚本挂载点
└── .env                      # 环境变量配置文件（可选）
```

## 接口规范

### DNS API 接口
系统通过阿里云 CLI 和 SDK 与阿里云 DNS API 交互，主要使用以下接口：

1. **DNS 记录添加**: 
   - 接口: `aliyun alidns AddDomainRecord`
   - 参数:
     - DomainName: 域名
     - RR: 主机记录（子域名前缀）
     - Type: 记录类型（TXT）
     - Value: 记录值
     - TTL: 生存时间（秒）

2. **DNS 记录查询**:
   - 接口: `aliyun alidns DescribeDomainRecords`
   - 参数:
     - DomainName: 域名
     - RRKeyWord: 主机记录关键字
     - Type: 记录类型
     - ValueKeyWord: 记录值关键字

3. **DNS 记录删除**:
   - 接口: `aliyun alidns DeleteDomainRecord`
   - 参数:
     - RecordId: 记录ID

### Certbot 钩子接口

1. **验证钩子 (auth-hook)**:
   - 脚本: `/usr/local/bin/plugins/dns/aliyun.sh`
   - 环境变量:
     - CERTBOT_DOMAIN: Certbot 提供的域名
     - CERTBOT_VALIDATION: Certbot 提供的验证值

2. **清理钩子 (cleanup-hook)**:
   - 脚本: `/usr/local/bin/plugins/dns/aliyun.sh clean`
   - 环境变量:
     - CERTBOT_DOMAIN: 域名
     - CERTBOT_VALIDATION: 验证值

3. **部署钩子 (deploy-hook)**:
   - 脚本: `/usr/local/bin/scripts/deploy-hook.sh`
   - 环境变量:
     - RENEWED_LINEAGE: 证书目录路径

## 域名参数规范

X Certbot 不再自动处理域名格式，而是将完整控制权交给用户。用户需要直接提供符合 certbot 命令行格式的域名参数：

1. **参数格式**:
   - 使用 `-d domain` 格式指定每个域名
   - 多个域名使用多个 `-d` 参数，如 `-d example.com -d *.example.com`

2. **通配符证书**:
   - 如需通配符证书，直接使用 `*.domain.com` 格式
   - 通配符证书必须使用 DNS 验证方式

3. **示例**:
   ```
   # 单域名
   DOMAIN_ARG="-d example.com"
   
   # 带通配符
   DOMAIN_ARG="-d example.com -d *.example.com"
   
   # 多域名
   DOMAIN_ARG="-d example.com -d *.example.com -d sub.example.com"
   ```

## 证书管理规范

1. **证书申请参数**:
   ```
   certbot certonly --manual --preferred-challenges dns \
     --manual-auth-hook "/usr/local/bin/plugins/dns/aliyun.sh" \
     --manual-cleanup-hook "/usr/local/bin/plugins/dns/aliyun.sh clean" \
     --agree-tos --email $EMAIL \
     --deploy-hook "/usr/local/bin/scripts/deploy-hook.sh" \
     -d domain1.com -d *.domain1.com -d domain2.com
   ```

2. **证书续期参数**:
   ```
   certbot renew --manual --preferred-challenges dns \
     --manual-auth-hook "/usr/local/bin/plugins/dns/aliyun.sh" \
     --manual-cleanup-hook "/usr/local/bin/plugins/dns/aliyun.sh clean" \
     --agree-tos --email $EMAIL \
     --deploy-hook "/usr/local/bin/scripts/deploy-hook.sh"
   ```

3. **证书文件输出**:
   - fullchain.pem: 服务器证书和中间证书
   - privkey.pem: 证书私钥
   - cert.pem: 服务器证书
   - chain.pem: 中间证书

## 安全规范

1. **凭证管理**:
   - 阿里云访问密钥使用环境变量或配置文件传递，不硬编码
   - 建议使用最小权限的 RAM 用户，只需要 DNS 修改权限

2. **证书安全**:
   - 私钥权限设置为 644 (rw-r--r--)
   - 使用卷映射将证书持久化到宿主机

3. **脚本执行安全**:
   - 宿主机脚本需要确保具有执行权限
   - 验证脚本执行结果和退出码 