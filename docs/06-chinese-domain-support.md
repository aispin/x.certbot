# 中文域名支持

X Certbot 现在支持中文域名和国际化域名 (IDN)，通过自动 punycode 解码功能，可以无缝处理中文域名。

## 功能特点

- **统一编码策略**：申请证书时自动将所有域名编码为 punycode 格式
- **统一解码策略**：DNS 验证时自动将所有域名解码为可读格式
- **完全兼容**：支持中文域名和英文域名，无需用户手动转换
- **调试友好**：在调试模式下显示原始域名和处理后的域名
- **错误处理**：编码/解码失败时优雅降级，使用原始域名继续处理

## 支持的域名类型

### 中文域名示例
- `测试.com` → `xn--0zwm56d.com`
- `中文.cn` → `xn--fiq228c.cn`
- `测试.中国` → `xn--0zwm56d.xn--fiqs8s`
- `网站.公司` → `xn--5tzm5g.xn--55qx5d`

### 混合域名示例
- `sub.测试.com` → `sub.xn--0zwm56d.com`
- `api.中文.cn` → `api.xn--fiq228c.cn`

## 使用方法

### 1. 基本使用

**现在支持直接使用中文域名！** 无需手动转换为 punycode，系统会自动处理：

```bash
# 使用中文域名
docker run -d \
  -e ALIYUN_REGION="cn-hangzhou" \
  -e ALIYUN_ACCESS_KEY_ID="your-access-key-id" \
  -e ALIYUN_ACCESS_KEY_SECRET="your-access-key-secret" \
  -e DOMAIN_ARG="-d 测试.com -d *.测试.com" \
  -e EMAIL="your-email@example.com" \
  -e CHALLENGE_TYPE="dns" \
  -e CLOUD_PROVIDER="aliyun" \
  -v /path/to/certificates:/etc/letsencrypt/certs \
  --name x.certbot \
  aiblaze/x.certbot:latest
```

### 2. 使用 .env 文件

```bash
# .env 文件内容
DOMAIN_ARG="-d 测试.com -d *.测试.com -d 中文.cn"
EMAIL="your-email@example.com"
CHALLENGE_TYPE="dns"
CLOUD_PROVIDER="aliyun"
ALIYUN_REGION="cn-hangzhou"
ALIYUN_ACCESS_KEY_ID="your-access-key-id"
ALIYUN_ACCESS_KEY_SECRET="your-access-key-secret"
```

### 3. 调试模式

启用调试模式可以查看域名处理过程：

```bash
docker run -d \
  -e DEBUG="true" \
  -e DOMAIN_ARG="-d 测试.com" \
  # ... 其他配置
  aiblaze/x.certbot:latest
```

调试输出示例：
```
=== 处理域名 ===
原始域名参数: -d 测试.com
处理后域名参数: -d xn--0zwm56d.com

=== DNS 验证信息 ===
原始域名: xn--0zwm56d.com
解码后域名: 测试.com
主域名: 测试.com
子域名前缀: @
记录名: _acme-challenge
记录值: abc123...
操作: add
```

## 技术实现

### 1. 依赖工具

- **idn2**：用于 punycode 编码和解码，已集成到 Docker 镜像中
- **统一处理**：采用统一编码和解码策略，简化逻辑

### 2. 处理流程

1. **申请证书阶段**：
   - 接收用户输入的域名参数（可能包含中文域名）
   - 对所有域名进行 punycode 编码
   - 将编码后的域名传递给 certbot

2. **DNS 验证阶段**：
   - Certbot 调用 DNS 钩子脚本
   - 对所有域名进行 punycode 解码
   - 使用解码后的域名进行 DNS 操作

3. **错误处理**：编码/解码失败时使用原始域名继续处理

### 3. 函数说明

所有域名处理函数都统一在 `scripts/domain_utils.sh` 中管理：

**重要**：`domain_utils.sh` 是 DNS 验证脚本的必需依赖，如果找不到该文件，脚本会报错并退出。

#### `encode_punycode_domain(domain)`
- **功能**：将域名编码为 punycode 格式（统一编码策略）
- **参数**：`domain` - 域名（可能是中文域名或英文域名）
- **返回**：punycode 编码后的域名，失败时返回原域名

#### `decode_punycode_domain(domain)`
- **功能**：将域名解码为可读格式（统一解码策略）
- **参数**：`domain` - 域名（可能是 punycode 编码或普通域名）
- **返回**：解码后的域名，失败时返回原域名

#### `get_main_domain(domain)`
- **功能**：提取主域名（已集成 punycode 解码）
- **参数**：`domain` - 完整域名
- **返回**：主域名

#### `get_subdomain_prefix(domain, main_domain)`
- **功能**：获取子域名前缀（已集成 punycode 解码）
- **参数**：
  - `domain` - 完整域名
  - `main_domain` - 主域名
- **返回**：子域名前缀或 "@"

#### `process_domain_args(domain_args)`
- **功能**：处理 DOMAIN_ARG 参数，将中文域名编码为 punycode
- **参数**：`domain_args` - 原始的域名参数字符串
- **返回**：处理后的域名参数字符串

## 注意事项

### 1. DNS 提供商支持

确保您的 DNS 提供商支持中文域名：
- **阿里云 DNS**：完全支持中文域名
- **腾讯云 DNSPod**：完全支持中文域名
- **其他提供商**：请确认支持情况

### 2. 浏览器兼容性

- 现代浏览器都支持中文域名显示
- 某些旧版本浏览器可能显示 punycode 编码
- 建议在 DNS 记录中使用解码后的中文域名

### 3. 证书验证

- Let's Encrypt 完全支持中文域名
- 证书中的域名将显示为解码后的中文域名
- 验证过程使用解码后的域名进行

## 故障排除

### 1. 解码失败

如果遇到解码失败的情况：

```bash
# 检查 idn2 工具是否可用
docker run --rm aiblaze/x.certbot:latest idn2 --version

# 手动测试解码
docker run --rm aiblaze/x.certbot:latest idn2 -d "xn--0zwm56d.com"
```

### 2. DNS 记录问题

如果 DNS 记录创建失败：

1. 确认域名已在 DNS 提供商处正确配置
2. 检查 API 权限是否包含 DNS 修改权限
3. 查看调试输出确认使用的域名格式

### 3. 证书验证失败

如果证书验证失败：

1. 确认 DNS 记录已正确创建
2. 等待 DNS 传播完成
3. 使用 `dig` 或 `nslookup` 验证记录是否生效

## 示例配置

### 完整的中文域名配置示例

```bash
# .env 文件
DOMAIN_ARG="-d 测试.com -d *.测试.com -d 中文.cn -d api.中文.cn"
EMAIL="admin@测试.com"
CHALLENGE_TYPE="dns"
CLOUD_PROVIDER="aliyun"
ALIYUN_REGION="cn-hangzhou"
ALIYUN_ACCESS_KEY_ID="your-access-key-id"
ALIYUN_ACCESS_KEY_SECRET="your-access-key-secret"
DNS_PROPAGATION_SECONDS="120"
DEBUG="true"
```

### 混合域名配置示例

```bash
# 同时支持中文和英文域名
DOMAIN_ARG="-d example.com -d 测试.com -d *.example.com -d *.测试.com"
```

## 更新日志

- **v1.0.0**：初始版本，支持基本的中文域名功能
- **v1.1.0**：添加自动 punycode 解码功能
- **v1.2.0**：改进错误处理和调试输出
- **v1.3.0**：重构代码结构，统一域名处理函数，删除重复代码
- **v1.4.0**：改进错误处理，将 domain_utils.sh 设为必需依赖
