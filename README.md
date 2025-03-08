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
- **高度可定制**：
  - 支持自定义验证钩子
  - 支持自定义清理钩子
  - 支持自定义部署钩子
  - [详细的钩子执行流程](docs/05-development-guide.md#8-钩子脚本与自动化流程)
- **灵活的证书管理**：
  - 支持多域名证书申请和管理
  - 可选自动为顶级域名添加通配符证书
  - 可配置证书输出目录结构
  - 可选生成证书元数据文件
- **CI/CD 友好**：
  - 详细的输出日志
  - 多种运行模式
  - 可配置完成后自动关闭或保持运行
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

## 快速开始

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

## 文档

- [系统架构](docs/01-system-architecture.md)
- [技术规范](docs/02-technical-specifications.md)
- [组件实现](docs/03-component-implementation.md)
- [使用指南](docs/04-usage-guide.md)
- [开发指南](docs/05-development-guide.md)

## 许可证

[MIT License](LICENSE)
