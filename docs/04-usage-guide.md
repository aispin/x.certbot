# X Certbot - 使用指南

> 本文档提供 X Certbot 系统的详细使用说明。如果您需要快速入门，请参阅项目根目录的 [README.md](../README.md)。

X Certbot 支持三种主要使用场景，请根据您的需求选择合适的章节阅读。

## 目录

- [1. 使用场景概述](#1-使用场景概述)
- [2. 场景一：无 Docker 环境直接运行](#2-场景一无-docker-环境直接运行)
- [3. 场景二：Docker 容器运行（推荐）](#3-场景二docker-容器运行推荐)
- [4. 场景三：GitHub Actions 自动化](#4-场景三github-actions-自动化)
- [5. 常见问题与故障排除](#5-常见问题与故障排除)
- [6. 安全最佳实践](#6-安全最佳实践)
- [7. 附录：域名处理逻辑](#7-附录域名处理逻辑)
- [8. 配置选项完整参考](#8-配置选项完整参考)

## 1. 使用场景概述

X Certbot 支持以下三种使用场景：

| 场景 | 适用人群 | 优点 | 缺点 |
|------|----------|------|------|
| 1. 无 Docker 环境直接运行 | 没有安装 Docker 的服务器用户，希望直接在服务器上运行脚本获取证书。 | • 无需安装 Docker<br>• 资源占用较少<br>• 直接集成到系统环境 | • 可能影响系统环境<br>• 依赖管理较复杂 |
| 2. Docker 容器运行（推荐）| 已安装 Docker 的服务器用户，希望通过容器隔离运行环境。 | • 环境隔离，不影响宿主机<br>• 依赖管理简单<br>• 跨平台兼容性好<br>• 升级方便 | • 需要安装 Docker<br>• 资源占用略高 |
| 3. GitHub Actions 自动化 | 希望完全自动化证书管理，无需登录服务器操作的用户。 | • 完全自动化<br>• 无需登录服务器<br>• 集中管理多个服务器的证书<br>• 版本控制和审计跟踪 | • 设置相对复杂<br>• 需要配置敏感信息到 GitHub Secrets |

## 2. 场景一：无 Docker 环境直接运行

如果您的服务器没有安装 Docker，可以按照以下步骤直接在服务器上运行 X Certbot。

### 2.1 安装步骤

#### 方法 1：一键安装（推荐）

使用以下命令直接从 GitHub 下载并执行安装脚本：

```bash
curl -fsSL https://raw.githubusercontent.com/aispin/x.certbot/main/install.sh | sudo bash
```

如果需要安装特定版本或使用自定义选项：

```bash
# 安装特定版本
curl -fsSL https://raw.githubusercontent.com/aispin/x.certbot/main/install.sh | sudo bash -s -- --version v1.0.0

# 使用自定义仓库
curl -fsSL https://raw.githubusercontent.com/aispin/x.certbot/main/install.sh | sudo bash -s -- --repo https://github.com/yourusername/x.certbot.git

# 查看所有选项
curl -fsSL https://raw.githubusercontent.com/aispin/x.certbot/main/install.sh | bash -s -- --help
```

#### 方法 2：手动安装

如果您更喜欢手动安装或需要更多控制，可以按照以下步骤操作：

1. **克隆项目仓库**：
    ```bash
    git clone https://github.com/aispin/x.certbot.git
    cd x.certbot
    ```

2. **运行安装脚本**：
    ```bash
    chmod +x install.sh
    sudo ./install.sh
    ```
   安装脚本会自动检测您的操作系统，安装必要的依赖，并设置好目录结构和配置文件。

3. **编辑配置文件**：
    ```bash
    sudo nano /etc/xcertbot/.env
    ```
   内容参考 [.env.example](../.env.example)

### 2.2 获取和管理证书

1. **获取证书**：
    ```bash
    sudo xcertbot
    ```

2. **手动续期证书**（如需要）：
    ```bash
    sudo xcertbot renew
    ```

3. **查看日志**：
    ```bash
    cat /var/log/xcertbot/xcertbot.log
    ```

### 2.3 证书文件位置

证书文件将保存在 `/etc/letsencrypt/certs/` 目录中：
- `fullchain.pem` - 包含服务器证书和中间证书
- `privkey.pem` - 证书私钥
- `cert.pem` - 服务器证书
- `chain.pem` - 中间证书

### 2.4 自动续期

安装脚本已经设置了 cron 任务，会根据配置文件中的 `CRON_SCHEDULE` 设置自动续期证书。

### 2.5 与其他服务集成

1. **在 Nginx 中使用证书**：
    ```nginx
    server {
        listen 443 ssl;
        server_name example.com *.example.com;

        ssl_certificate /etc/letsencrypt/certs/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/certs/privkey.pem;

        # 其他配置...
    }
    ```

2. **在 Apache 中使用证书**：
    ```apache
    <VirtualHost *:443>
        ServerName example.com
        ServerAlias *.example.com

        SSLEngine on
        SSLCertificateFile /etc/letsencrypt/certs/cert.pem
        SSLCertificateKeyFile /etc/letsencrypt/certs/privkey.pem
        SSLCertificateChainFile /etc/letsencrypt/certs/chain.pem

        # 其他配置...
    </VirtualHost>
    ```

3. **证书更新后重启服务**：

   您可以创建一个自定义的部署脚本，放置在 `/host-scripts/post-renewal.sh`，该脚本会在证书更新后自动执行：
   
    ```bash
    #!/bin/bash
    echo "证书已更新，正在重启服务..."
    systemctl restart nginx  # 或其他服务
    echo "服务已重启"
    ```

      确保脚本具有执行权限：
    ```bash
    chmod +x /host-scripts/post-renewal.sh
    ```

## 3. 场景二：Docker 容器运行（推荐）

如果您的服务器已安装 Docker，可以通过容器运行 X Certbot，这是推荐的使用方式。

### 3.1 准备工作

1. **获取镜像**：
    ```bash
    # 使用预构建镜像（推荐）
    docker pull aiblaze/x.certbot:latest

    # 或者自行构建镜像
    git clone https://github.com/aispin/x.certbot.git
    cd x.certbot
    docker build -t x.certbot .
    ```

2. **准备配置文件**：

   创建 `.env` 文件，内容参考 [.env.example](../.env.example)

3. **创建证书存储目录**：
    ```bash
    mkdir -p /path/to/certificates
    ```

### 3.2 运行容器

选择以下任一方式运行容器：

1. **使用 .env 文件（推荐）**：
    ```bash
    docker run -d \
      -v /path/to/.env:/.env \
      -v /path/to/certificates:/etc/letsencrypt/certs \
      --name x.certbot \
      aiblaze/x.certbot:latest
    ```

2. **使用环境变量**：
    ```bash
    docker run -d \
      -e ALIYUN_REGION="cn-hangzhou" \
      -e ALIYUN_ACCESS_KEY_ID="your-access-key-id" \
      -e ALIYUN_ACCESS_KEY_SECRET="your-access-key-secret" \
      -e DOMAINS="example.com,sub.example.com" \
      -e EMAIL="your-email@example.com" \
      -e CHALLENGE_TYPE="dns" \
      -e CLOUD_PROVIDER="aliyun" \
      -v /path/to/certificates:/etc/letsencrypt/certs \
      --name x.certbot \
      aiblaze/x.certbot:latest
    ```

### 3.3 与宿主机脚本集成

如果需要在证书更新后执行特定操作（如重启 Web 服务器），可以配置宿主机脚本：

1. **创建脚本文件**：
    ```bash
    # 创建脚本文件
    cat > /path/to/post-renewal.sh << 'EOF'
    #!/bin/bash
    echo "证书已更新，正在重启服务..."
    systemctl restart nginx  # 或其他服务
    echo "服务已重启"
    EOF

    # 设置执行权限
    chmod +x /path/to/post-renewal.sh
    ```

2. **挂载脚本到容器**：
    ```bash
    docker run -d \
      -v /path/to/.env:/.env \
      -v /path/to/certificates:/etc/letsencrypt/certs \
      -v /path/to/post-renewal.sh:/host-scripts/post-renewal.sh \
      --name x.certbot \
      aiblaze/x.certbot:latest
    ```

### 3.4 管理证书

1. **查看容器日志**：
    ```bash
    docker logs x.certbot
    # 或实时查看
    docker logs -f x.certbot
    ```

2. **手动触发证书续期**：
    ```bash
    docker exec x.certbot /usr/local/bin/entrypoint.sh renew
    ```

3. **进入容器调试**：
    ```bash
    docker exec -it x.certbot /bin/bash
    ```

### 3.5 使用 Docker Compose

如果您使用 Docker Compose，可以创建以下 `docker-compose.yml` 文件：

```yaml
version: '3'

services:
  x.certbot:
    image: aiblaze/x.certbot:latest
    container_name: x.certbot
    volumes:
      - ./config/.env:/.env
      - ./certs:/etc/letsencrypt/certs
      - ./scripts/post-renewal.sh:/host-scripts/post-renewal.sh
    restart: unless-stopped
```

然后运行：
```bash
docker-compose up -d
```

## 4. 场景三：GitHub Actions 自动化

如果您希望完全自动化证书管理，无需登录服务器操作，可以使用 GitHub Actions。

### 4.1 准备工作

1. **创建 GitHub 仓库**：
  - Fork 或克隆 X Certbot 项目到您的 GitHub 账号
  - 或创建一个新的私有仓库

2. **配置 GitHub Secrets**：
  在仓库的 Settings > Secrets and variables > Actions 中添加以下 Secrets：
  - `ALIYUN_REGION`: 阿里云区域（如 cn-hangzhou）
  - `ALIYUN_ACCESS_KEY_ID`: 阿里云访问密钥 ID
  - `ALIYUN_ACCESS_KEY_SECRET`: 阿里云访问密钥 Secret
  - `DOMAINS`: 域名列表，逗号分隔（如 example.com,sub.example.com）
  - `EMAIL`: 证书所有者的电子邮件地址
  - `SERVER_HOST`: 目标服务器 IP 或域名
  - `SERVER_USERNAME`: SSH 用户名
  - `SERVER_SSH_KEY`: SSH 私钥（完整内容，包括开头和结尾行）
  - `CERT_DESTINATION_PATH`: 证书目标路径（如 /etc/nginx/certs）
  - `RESTART_COMMAND`（可选）: 证书部署后运行的命令（默认为 systemctl restart nginx）
  - `WEBHOOK_URL`（可选）: 用于通知的 Webhook URL

3. **确保目标服务器可访问**：
  - 确保 GitHub Actions 可以通过 SSH 连接到您的服务器
  - 确保 `SERVER_USERNAME` 用户有权限写入 `CERT_DESTINATION_PATH` 目录
  - 如果使用 `RESTART_COMMAND`，确保该用户有权限执行该命令

### 4.2 创建工作流文件

1. **创建工作流目录**：

    ```bash
    mkdir -p .github/workflows
    ```

2. **创建工作流文件**：

    创建 `.github/workflows/certbot-renewal.yml` 文件，内容参考 [certbot-renew-example.yml](./certbot-renew-example.yml)


### 4.3 使用工作流

1. **提交并推送工作流文件**：

    ```bash
    git add .github/workflows/certbot-renewal.yml
    git commit -m "Add certificate renewal workflow"
    git push
    ```

2. **手动触发工作流**（可选）：
  - 在 GitHub 仓库页面，点击 "Actions" 标签
  - 选择 "Certbot Certificate Renewal" 工作流
  - 点击 "Run workflow" 按钮

3. **查看工作流执行结果**：
  - 在 GitHub 仓库的 Actions 标签页查看执行日志
  - 检查目标服务器上的证书文件是否已更新

### 4.4 工作流执行流程

1. 工作流会在以下情况触发：
  - 按计划（每周一和周四凌晨）自动执行
  - 手动触发
  - 发布新版本（推送 v*.*.* 格式的标签）时触发

2. 执行步骤：
  - 检出代码
  - 设置 Docker 环境
  - 创建 .env 文件和证书目录
  - 运行 X Certbot 容器获取/更新证书
  - 将证书部署到目标服务器
  - 重启目标服务器上的服务
  - 发送成功/失败通知（如果配置了 WEBHOOK_URL）

## 5. 常见问题与故障排除

### 5.1 DNS 验证失败

**问题**：DNS 验证失败，无法获取证书。

**解决方案**：

- 增加 DNS_PROPAGATION_SECONDS 值（如 120 或 180）
- 检查阿里云 DNS 记录是否正确添加
- 确认阿里云 API 权限是否足够

### 5.2 证书无法自动续期

**问题**：证书到期但没有自动续期。

**解决方案**：
- Docker 环境：检查容器是否正在运行
- 无 Docker 环境：检查 cron 任务是否正确设置
- 查看日志文件排查具体错误

### 5.3 权限问题

**问题**：无法写入证书文件或执行脚本。

**解决方案**：
- 检查目录权限
- 确保运行用户有足够权限
- 使用 sudo 运行命令（无 Docker 环境）

### 5.4 GitHub Actions 连接失败

**问题**：GitHub Actions 无法连接到目标服务器。

**解决方案**：
- 检查 SSH 密钥是否正确配置
- 确认服务器防火墙设置
- 验证 SERVER_HOST 和 SERVER_USERNAME 是否正确

### 5.5 如何在 CI/CD 管道中使用？

在 CI/CD 管道中，通常希望容器执行任务后自动退出。确保设置：
- `CRON_ENABLED=false`
- `KEEP_RUNNING=false`

这样容器会在证书操作完成后自动退出，不会阻塞 CI/CD 流程。

### 5.6 如何使用外部验证脚本？

设置环境变量 `AUTH_HOOK` 和 `CLEANUP_HOOK` 指向你的自定义脚本：

```bash
-e AUTH_HOOK=/path/to/custom/auth-hook.sh
-e CLEANUP_HOOK=/path/to/custom/cleanup-hook.sh
```

记得将脚本目录挂载到容器内：

```bash
-v /host/scripts/path:/path/to/custom
```

### 5.7 如何同时支持 HTTP 和 DNS 验证？

目前每个容器实例只能使用一种验证方式。如果需要同时支持两种方式，可以运行两个不同配置的容器实例。

### 5.8 如何在证书更新后重启 Web 服务器？

有两种方法：

1. 使用自定义部署钩子脚本：
   ```bash
   -e DEPLOY_HOOK=/path/to/custom/deploy-hook.sh
   ```

2. 使用宿主机 post-renewal 脚本：
   ```bash
   -v /path/to/restart-nginx.sh:/host-scripts/post-renewal.sh
   ```

## 6. 安全最佳实践

### 6.1 阿里云访问密钥安全

1. **使用 RAM 用户**：
  - 不要使用主账号的访问密钥
  - 创建专用的 RAM 用户，只授予 DNS 修改权限

2. **最小权限原则**：
  - 仅授予必要的 DNS 权限，如 AliyunDNSFullAccess 或自定义更精细的权限

3. **定期轮换密钥**：
  - 定期更新访问密钥
  - 更新后记得更新相应的配置

### 6.2 证书安全

1. **文件权限**：
  - 确保证书文件只有必要的用户可以访问
  - 私钥文件应特别注意权限控制（建议 600 或 640）

2. **证书使用**：
  - 不要将证书复制到不必要的位置
  - 确保只有需要使用证书的服务能访问证书文件

## 7. 附录：域名处理逻辑

X Certbot 对不同类型的域名有不同的处理逻辑：

- **顶级域名**（如 example.com）：
  - 自动添加通配符证书（*.example.com）
  - 同时获取 example.com 和 *.example.com 的证书

- **子域名**（如 sub.example.com）：
  - 只获取该特定子域名的证书
  - 不自动添加通配符

- **多个域名**：
  - 使用逗号分隔，例如：`example.com,sub.example.com,another.com`
  - 每个域名会根据上述规则分别处理

## 8. 配置选项完整参考

### 8.1 核心配置

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| DOMAINS | 是 | - | 域名列表，逗号分隔 |
| EMAIL | 是 | - | 证书所有者的电子邮件地址 |
| ENABLE_WILDCARDS | 否 | true | 是否为顶级域名添加通配符证书 |

### 8.2 验证方式与云服务商

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| CHALLENGE_TYPE | 否 | dns | 验证方式: dns 或 http |
| CLOUD_PROVIDER | 否 | aliyun | 云服务提供商: aliyun 或 tencentcloud |

### 8.3 阿里云配置 (当 CLOUD_PROVIDER=aliyun 时)

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| ALIYUN_REGION | 是 | - | 阿里云区域 |
| ALIYUN_ACCESS_KEY_ID | 是 | - | 阿里云访问密钥 ID |
| ALIYUN_ACCESS_KEY_SECRET | 是 | - | 阿里云访问密钥 Secret |

### 8.4 腾讯云配置 (当 CLOUD_PROVIDER=tencentcloud 时)

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| TENCENTCLOUD_SECRET_ID | 是 | - | 腾讯云 Secret ID |
| TENCENTCLOUD_SECRET_KEY | 是 | - | 腾讯云 Secret Key |

### 8.5 HTTP 验证配置 (当 CHALLENGE_TYPE=http 时)

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| WEBROOT_PATH | 否 | /var/www/html | Web 根目录路径 |

### 8.6 DNS 验证配置 (当 CHALLENGE_TYPE=dns 时)

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| DNS_PROPAGATION_SECONDS | 否 | 60 | DNS 记录传播等待时间（秒） |

### 8.7 钩子脚本配置

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| AUTH_HOOK | 否 | 自动选择 | 自定义验证钩子脚本路径 |
| CLEANUP_HOOK | 否 | 自动选择 | 自定义清理钩子脚本路径 |
| DEPLOY_HOOK | 否 | 内置脚本 | 自定义部署钩子脚本路径 |
| POST_RENEWAL_SCRIPT | 否 | - | 证书续期后执行的脚本路径 |

### 8.8 证书输出配置

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| CERT_OUTPUT_DIR | 否 | /etc/letsencrypt/certs | 证书输出目录 |
| CREATE_DOMAIN_DIRS | 否 | false | 是否为每个域名创建单独的子目录 |
| CREATE_METADATA | 否 | false | 是否创建证书元数据文件 |
| CERT_FILE_PERMISSIONS | 否 | 644 | 证书文件权限 |

### 8.9 通知配置

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| WEBHOOK_URL | 否 | - | Webhook URL，证书续期成功后通知 |

### 8.10 自动续期与容器运行配置

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| CRON_ENABLED | 否 | false | 是否启用 cron 自动续期 |
| CRON_SCHEDULE | 否 | 0 0 * * 1,4 | 证书自动续期的 cron 表达式 |
| KEEP_RUNNING | 否 | false | 是否保持容器运行（即使不启用 cron） |

### 8.11 自定义钩子脚本参考

#### 验证钩子 (Auth Hook)

验证钩子脚本用于处理域名所有权验证。自定义脚本需接受以下环境变量：
- `CERTBOT_DOMAIN`: 当前正在验证的域名
- `CERTBOT_VALIDATION`: Let's Encrypt 提供的验证值

#### 清理钩子 (Cleanup Hook)

清理钩子脚本用于清理验证完成后的资源。自定义脚本应接受 `clean` 参数：

```bash
your-cleanup-script.sh clean
```

#### 部署钩子 (Deploy Hook)

部署钩子脚本在证书续期成功后执行，用于部署新证书。自定义脚本可使用以下环境变量：
- `RENEWED_LINEAGE`: 更新的证书目录路径
- `RENEWED_DOMAIN`: 域名
- `RENEWED_FULLCHAIN`: 完整证书链文件路径
- `RENEWED_PRIVKEY`: 私钥文件路径
- `RENEWED_CERT`: 证书文件路径
- `RENEWED_CHAIN`: 证书链文件路径 