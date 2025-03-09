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

  **必要配置**：
  - `ALIYUN_REGION`: 阿里云区域（如 cn-hangzhou）
  - `ALIYUN_ACCESS_KEY_ID`: 阿里云访问密钥 ID
  - `ALIYUN_ACCESS_KEY_SECRET`: 阿里云访问密钥 Secret
  - `DOMAINS`: 域名列表，逗号分隔（如 example.com,sub.example.com）
  - `EMAIL`: 证书所有者的电子邮件地址
  - `SERVERS`: 服务器列表，每行一个，格式为 `user@host`（例如：`root@example.com`）
  - `SSH_PRIVATE_KEY`: SSH 私钥（完整内容，包括开头和结尾行）

  **可选配置**：
  - `CERT_DIR`: 证书目标路径（默认为 `/etc/letsencrypt/certs`）
  - `CERT_UPDATED_HOOK_CMD`: 证书部署后运行的命令（如 `systemctl restart nginx`）
  - `WEBHOOK_URL`: 用于通知的 Webhook URL
  - `DNS_PROPAGATION_SECONDS`: DNS 记录传播等待时间（默认 60 秒）
  - `CHALLENGE_TYPE`: 验证类型（默认 `dns`，也可设置为 `http`）
  - `CLOUD_PROVIDER`: 云服务提供商（默认 `aliyun`，也可设置为 `tencentcloud`）

3. **确保目标服务器可访问**：
  - 确保 GitHub Actions 可以通过 SSH 连接到您的服务器
  - 确保服务器的 `~/.ssh/authorized_keys` 文件中包含相应的公钥
  - 确保 SSH 用户有权限写入 `CERT_DIR` 目录
  - 如果使用 `CERT_UPDATED_HOOK_CMD`，确保该用户有权限执行该命令

### 4.2 创建工作流文件

1. **创建工作流目录**：

    ```bash
    mkdir -p .github/workflows
    ```

2. **创建工作流文件**：

    创建 `.github/workflows/certbot-renewal.yml` 文件，内容参考 [certbot-renew-example.yml](./certbot-renew-example.yml)

### 4.3 多服务器部署设置

X Certbot 支持将证书部署到多台服务器，配置方法如下：

1. **配置 SERVERS 变量**：
   ```
   user1@server1.example.com
   user2@server2.example.com
   root@server3.example.com
   ```

2. **配置一次 SSH_PRIVATE_KEY**：
   一个 SSH 私钥可用于访问多台服务器，前提是这些服务器都添加了对应的公钥到其 `authorized_keys` 文件中。

3. **设置全局证书目录和更新钩子**：
   - `CERT_DIR`: 所有服务器上证书的存放路径
   - `CERT_UPDATED_HOOK_CMD`: 证书更新后在每台服务器上执行的命令

### 4.4 使用工作流

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

### 4.5 工作流执行流程

1. 工作流会在以下情况触发：
  - 按计划（每周一和周四凌晨）自动执行
  - 手动触发
  - 发布新版本（推送 v*.*.* 格式的标签）时触发

2. 执行步骤：
  - 检出代码
  - 设置 Docker 环境
  - 创建 .env 文件和证书目录
  - 运行 X Certbot 容器获取/更新证书
  - 解析服务器配置列表
  - 将证书部署到所有目标服务器
  - 在每台服务器上执行证书更新后的钩子命令（如果配置了）
  - 发送成功/失败通知（如果配置了 WEBHOOK_URL）

### 4.6 SSH 密钥管理最佳实践

1. **创建专用部署密钥**：
   ```bash
   ssh-keygen -t rsa -b 4096 -C "certbot@example.com" -f deploy_key
   ```
   不要为这个密钥设置密码。

2. **配置目标服务器**：
   在每台目标服务器上添加公钥：
   ```bash
   cat deploy_key.pub >> ~/.ssh/authorized_keys
   chmod 600 ~/.ssh/authorized_keys
   ```

3. **限制密钥权限**：
   推荐在 `authorized_keys` 中限制这个密钥的使用：
   ```
   command="rsync --server -logDtpre.iLsfx . /etc/letsencrypt/certs/",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty ssh-rsa AAAA...
   ```

4. **定期轮换密钥**：
   为了安全起见，建议每 3-6 个月轮换一次部署密钥。


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
- 检查 `SSH_PRIVATE_KEY` 是否正确配置（包含完整内容，包括开头的 `-----BEGIN OPENSSH PRIVATE KEY-----` 和结尾行）
- 确认目标服务器的 `~/.ssh/authorized_keys` 文件是否正确包含对应的公钥
- 验证 `SERVERS` 变量中的格式是否正确（`user@host`，每行一个服务器）
- 检查目标服务器的 SSH 设置是否允许密钥认证
- 如果某台服务器连接失败，工作流会继续尝试其他服务器，检查日志以确定哪台服务器有问题

#### 5.4.1 多服务器部署问题

**问题**：只有部分服务器成功部署证书。

**解决方案**：
- 检查工作流日志，找出失败的服务器和具体错误
- 确认所有服务器都正确配置了相同的公钥
- 验证每台服务器的用户是否有权限创建/写入 `CERT_DIR` 目录
- 对于执行 `CERT_UPDATED_HOOK_CMD` 失败的服务器，确认用户是否有足够权限执行该命令

#### 5.4.2 GitHub Actions 中的日志输出处理

**说明**：虽然 X Certbot 不再将日志输出重定向到 stderr，但在 GitHub Actions 中仍建议使用特殊的日志处理方式，以便更好地管理和查看输出。

**推荐方法**：
- 在 GitHub Actions 工作流中使用 `2>&1 | tee certbot_output.log` 来捕获所有输出：
  ```yaml
  - name: Run Certbot container
    run: |
      docker run --rm \
        -v $(pwd)/.env:/.env \
        -v $(pwd)/certs:/etc/letsencrypt/certs \
        aiblaze/x.certbot:latest 2>&1 | tee certbot_output.log
  ```

- 更完善的方法是结合使用 `tee` 命令和 GitHub Actions 的特殊日志命令：
  ```yaml
  - name: Run Certbot container
    run: |
      # 使用 tee 命令将输出同时发送到终端和文件
      docker run --rm \
        -v $(pwd)/.env:/.env \
        -v $(pwd)/certs:/etc/letsencrypt/certs \
        aiblaze/x.certbot:latest 2>&1 | tee certbot_output.log
      
      # 检查 Docker 命令的退出状态
      EXIT_CODE=${PIPESTATUS[0]}
      if [ $EXIT_CODE -ne 0 ]; then
        echo "::error::Certbot 容器执行失败，退出代码: $EXIT_CODE"
        cat certbot_output.log
        exit $EXIT_CODE
      else
        echo "::notice::Certbot 容器执行成功"
      fi
  ```

这种方法可以确保：
1. 所有输出（包括可能的 stderr）都会被记录到日志文件中
2. 只有在容器实际执行失败时才会显示错误
3. 使用 GitHub Actions 的特殊日志命令来控制日志的显示级别

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

X Certbot 现在将域名处理权完全交给用户，不再自动处理域名格式。用户需要直接提供完整的域名参数：

- **域名参数格式**：
  - 使用 certbot 命令行参数格式，例如：`-d example.com -d *.example.com`
  - 每个域名前都需要添加 `-d` 参数
  - 如果需要通配符证书，请直接添加 `*.domain.com` 格式的域名

- **示例**：
  - 单个域名：`-d example.com`
  - 带通配符：`-d example.com -d *.example.com`
  - 多个域名：`-d example.com -d *.example.com -d sub.example.com -d another.com`

> **注意**：不再支持逗号分隔的域名列表，也不再自动添加通配符。用户需要明确指定每个要获取证书的域名。

### 7.1 环境变量设置示例

在 `.env` 文件或 Docker 运行命令中设置 DOMAIN_ARG 变量：

```bash
# 单个域名
DOMAIN_ARG="-d example.com"

# 带通配符
DOMAIN_ARG="-d example.com -d *.example.com"

# 多个域名
DOMAIN_ARG="-d example.com -d *.example.com -d sub.example.com -d another.com"
```

## 8. 配置选项完整参考

### 8.1 核心配置

| 环境变量 | 必选 | 默认值 | 描述 |
|----------|------|-------|------|
| DOMAIN_ARG | 是 | - | 域名参数，格式为 `-d domain1 -d domain2` |
| EMAIL | 是 | - | 证书所有者的电子邮件地址 |

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
| TENCENTCLOUD_REGION | 否 | ap-guangzhou | 腾讯云区域，如 ap-guangzhou, ap-hongkong 等 |

> **注意**：X Certbot 会自动配置腾讯云命令行工具 (tccli)，无需手动配置。系统会使用上述环境变量设置 tccli 的 secretId、secretKey、region 和 output 格式。

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
| CREATE_DOMAIN_DIRS | 否 | true | 是否为每个域名创建单独的子目录 |
| CREATE_METADATA | 否 | true | 是否创建证书元数据文件 |
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

注：X Certbot 内置，会根据 CHALLENGE_TYPE 和 CLOUD_PROVIDER 选择对应的钩子（见 plugins/dns 和 plugins/http 目录）,除非想完全自定义，否则不要设置

#### 清理钩子 (Cleanup Hook)

清理钩子脚本用于清理验证完成后的资源。自定义脚本应接受 `clean` 参数：

```bash
your-cleanup-script.sh clean
```

注：X Certbot 内置，会根据 CHALLENGE_TYPE 和 CLOUD_PROVIDER 选择对应的钩子（见 plugins/dns 和 plugins/http 目录）,除非想完全自定义，否则不要设置

#### 部署钩子 (Deploy Hook)

部署钩子脚本在证书续期成功后执行，用于部署新证书。自定义脚本可使用以下环境变量：
- `RENEWED_LINEAGE`: 更新的证书目录路径
- `RENEWED_DOMAIN`: 域名
- `RENEWED_FULLCHAIN`: 完整证书链文件路径
- `RENEWED_PRIVKEY`: 私钥文件路径
- `RENEWED_CERT`: 证书文件路径
- `RENEWED_CHAIN`: 证书链文件路径 

注：X Certbot 内置，证书实际更新后调用，见 [scripts/deploy-hook.sh](../scripts/deploy-hook.sh)，除非想完全自定义，否则不要设置

### 8.12 钩子脚本执行流程

X Certbot 使用多个钩子脚本来实现自动化的证书申请、验证和部署流程。以下是这些钩子的执行顺序和主要作用：

```
1. manual-auth-hook → 创建验证记录（DNS TXT 或 HTTP 文件）
2. Let's Encrypt 验证域名所有权
3. manual-cleanup-hook → 清理验证记录
4. Let's Encrypt 颁发/续期证书
5. deploy-hook → 部署新证书，执行后续操作
```

#### 8.12.1 deploy-hook 内部流程

当证书成功更新后，deploy-hook 会执行以下操作：

1. 复制证书文件到指定的输出目录
2. 设置适当的文件权限
3. 可选地创建元数据文件（如果 `CREATE_METADATA=true`）
4. 执行自定义后续脚本（如果配置了 `POST_RENEWAL_SCRIPT`）
5. 或执行宿主机脚本（如果存在 `/host-scripts/post-renewal.sh`）
6. 发送 webhook 通知（如果配置了 `WEBHOOK_URL`）

#### 8.12.2 自定义后续脚本

您可以通过以下两种方式配置证书更新后的自定义操作：

1. **设置 POST_RENEWAL_SCRIPT 环境变量**：
   ```
   -e POST_RENEWAL_SCRIPT=/path/to/your-script.sh
   ```

2. **挂载宿主机脚本**（推荐，不用设置 `POST_RENEWAL_SCRIPT` 变量）：
   ```
   -v /path/on/host/restart-services.sh:/host-scripts/post-renewal.sh
   ```

这些脚本通常用于重启 Web 服务器、分发证书或执行其他依赖于新证书的操作。

##### 自定义脚本详解

`POST_RENEWAL_SCRIPT` 环境变量允许您指定一个在证书更新成功后自动执行的脚本。这个脚本**不需要在容器内部**，而是通常位于宿主机上，通过卷挂载到容器内。

**脚本位置选项**：

1. **容器外部脚本（推荐）**：
   - 脚本位于宿主机上，通过卷挂载到容器内
   - 这种方式更灵活，可以直接操作宿主机环境或其他服务器

2. **容器内部脚本**：
   - 脚本位于容器内部（如通过自定义镜像添加）
   - 这种方式限制较多，无法直接操作宿主机环境

**脚本接收的环境变量**：

执行时，脚本会自动接收以下环境变量：
```
RENEWED_DOMAIN - 已更新证书的主域名
RENEWED_FULLCHAIN - 完整证书链文件的路径
RENEWED_PRIVKEY - 私钥文件的路径
RENEWED_CERT - 证书文件的路径
RENEWED_CHAIN - 证书链文件的路径
```

**配置示例**：

1. 创建宿主机脚本（例如 `/opt/scripts/restart-nginx.sh`）：
   ```bash
   #!/bin/bash
   
   echo "证书已更新: $RENEWED_DOMAIN"
   echo "证书路径: $RENEWED_FULLCHAIN"
   
   # 示例：SSH 到 Web 服务器重启 Nginx
   ssh webserver "systemctl restart nginx"
   
   # 或执行其他操作...
   exit 0
   ```

2. 确保脚本有执行权限：
   ```bash
   chmod +x /opt/scripts/restart-nginx.sh
   ```

3. 配置 Docker 运行命令：
   ```bash
   docker run -d \
     -v /opt/scripts/restart-nginx.sh:/scripts/restart-nginx.sh \
     -e POST_RENEWAL_SCRIPT=/scripts/restart-nginx.sh \
     -v /etc/letsencrypt:/etc/letsencrypt \
     -v /var/lib/letsencrypt:/var/lib/letsencrypt \
     ... 其他配置 ...
     certbot-dns-aliyun
   ```

**最佳实践**：

- 脚本应该是**幂等的**：可以多次执行而不产生副作用
- 添加**错误处理**：脚本应该处理可能的错误情况
- 记录**日志**：添加适当的日志输出，便于排查问题
- **权限控制**：确保脚本只有必要的权限，特别是涉及敏感操作时
- **测试**：在生产环境使用前充分测试脚本功能

**常见应用场景**：

- 重启 Web 服务器（如 Nginx、Apache）以加载新证书
- 将更新后的证书复制或同步到其他服务器
- 更新负载均衡器、CDN 或其他依赖证书的服务配置
- 发送自定义通知（除了内置的 Webhook 功能外）
- 执行证书备份或权限调整

#### 8.12.3 Webhook 通知

通过设置 `WEBHOOK_URL` 环境变量，您可以在证书更新后接收通知：

```
-e WEBHOOK_URL=https://your-webhook-endpoint.com/notify
```

X Certbot 会发送包含域名、状态和时间戳的 JSON 数据到指定 URL。

更多详细信息，请参阅 [开发指南中的钩子脚本章节](./05-development-guide.md#8-钩子脚本与自动化流程)。 