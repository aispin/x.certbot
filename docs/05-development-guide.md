# X Certbot - 开发指南

本文档提供 X Certbot 系统的开发指南，包括项目结构、代码规范、扩展方法和贡献指南。

## 1. 项目结构

```
x.certbot/
├── .github/                   # GitHub 工作流配置
│   └── workflows/             # GitHub Actions 工作流定义
│       └── docker-publish.yml # Docker 镜像发布工作流
├── scripts/                   # 脚本文件
│   └── deploy-hook.sh         # 证书部署脚本
├── plugins/                   # 插件目录
│   ├── dns/                   # DNS 验证插件
│   │   ├── aliyun.sh          # 阿里云 DNS 验证脚本
│   │   └── tencentcloud.sh    # 腾讯云 DNS 验证脚本
│   └── http/                  # HTTP 验证插件
│       ├── aliyun.sh          # 阿里云 HTTP 验证脚本
│       ├── tencentcloud.sh    # 腾讯云 HTTP 验证脚本
│       └── common.sh          # 通用 HTTP 验证脚本
├── docs/                      # 文档文件
│   ├── 01-system-architecture.md    # 系统架构
│   ├── 02-technical-specifications.md  # 技术规范
│   ├── 03-component-implementation.md  # 组件实现
│   ├── 04-usage-guide.md      # 使用指南
│   ├── 05-development-guide.md  # 开发指南（本文档）
│   ├── .env.example           # 环境变量示例文件
│   ├── certbot-renew-example.yml # GitHub Actions 工作流示例
│   └── README.md              # 文档目录说明
├── .gitignore                 # Git 忽略文件
├── Dockerfile                 # Docker 构建文件
├── entrypoint.sh              # 容器入口脚本
├── install.sh                 # 无 Docker 环境安装脚本
├── LICENSE                    # 许可证文件
└── README.md                  # 项目说明文件
```

## 2. 开发环境设置

### 2.1 开发环境要求

- Git
- Docker & Docker Compose
- Bash 或兼容的 Shell
- 用于测试的阿里云账号
- 文本编辑器或 IDE

### 2.2 开发环境设置步骤

#### Docker 环境开发

1. 克隆仓库：
```bash
git clone https://github.com/aispin/x.certbot.git
cd x.certbot
```

2. 创建 .env 文件：
```bash
cp docs/.env.example .env
# 编辑 .env 文件，填入您的测试凭据
```

3. 构建开发用 Docker 镜像：
```bash
docker build -t x.certbot:dev .
```

4. 运行开发容器：
```bash
docker run -it --rm \
  -v $(pwd):/app \
  -v $(pwd)/.env:/.env \
  --name x.certbot-dev \
  x.certbot:dev /bin/bash
```

#### 非 Docker 环境开发

如果您需要在非 Docker 环境中开发和测试 `install.sh` 脚本：

1. 克隆仓库：
```bash
git clone https://github.com/aispin/x.certbot.git
cd x.certbot
```

2. 为 `install.sh` 添加执行权限：
```bash
chmod +x install.sh
```

3. 在测试环境中运行安装脚本（请谨慎操作，最好在虚拟机或测试服务器上进行）：
```bash
# 查看帮助信息
./install.sh --help

# 使用测试参数运行
sudo ./install.sh --dir /tmp/xcertbot-test
```

4. 测试完成后清理测试环境：
```bash
sudo rm -rf /tmp/xcertbot-test
```

### 2.3 开发 install.sh 脚本

`install.sh` 脚本用于在无 Docker 环境的服务器上直接安装 X Certbot。开发此脚本时，请注意以下几点：

1. **参数处理**：
   - 确保正确处理命令行参数
   - 提供清晰的帮助信息
   - 支持自定义安装选项

2. **错误处理**：
   - 检查必要的权限和依赖
   - 提供有意义的错误消息
   - 在失败时进行适当的清理

3. **兼容性**：
   - 确保脚本在不同的 Linux 发行版上工作
   - 测试在 Debian/Ubuntu、CentOS/RHEL 和 Alpine 上的兼容性

4. **测试方法**：
   - 使用 `--dir` 参数指定测试目录
   - 在虚拟机或容器中进行测试
   - 验证安装后的功能

## 3. 代码规范

### 3.1 Bash 脚本规范

1. **文件头**：
   - 所有脚本以 `#!/bin/bash` 开头
   - 添加简短描述说明脚本功能

2. **注释规范**：
   - 使用 `#` 添加注释
   - 重要函数前添加详细注释
   - 复杂逻辑添加内联注释

3. **命名规范**：
   - 变量使用大写（环境变量或全局变量）
   - 函数使用小写加下划线
   - 临时变量使用小写

4. **函数规范**：
   - 函数定义前加注释
   - 函数应有明确的输入和输出
   - 使用 `local` 关键字定义局部变量

5. **错误处理**：
   - 关键命令检查返回状态
   - 使用有意义的错误消息
   - 关键错误应有适当的退出码

### 3.2 Dockerfile 规范

1. **基础镜像**：
   - 使用特定版本标签，避免 `latest`
   - 优先使用轻量级镜像如 Alpine

2. **指令顺序**：
   - 按变更频率排序指令，最少变更的放前面
   - 合并 RUN 指令减少层数

3. **环境变量**：
   - 使用 ENV 定义默认环境变量
   - 在文档中说明所有环境变量

## 4. 扩展指南

### 4.1 添加新功能

要向项目添加新功能，请按照以下步骤操作：

1. **创建功能分支**：
```bash
git checkout -b feature/your-feature-name
```

2. **实现功能**：
   - 修改或添加必要的脚本
   - 更新 Dockerfile（如需要）
   - 添加或更新测试用例

3. **记录变更**：
   - 更新相关文档
   - 在 README.md 中添加新功能说明

4. **提交变更**：
```bash
git commit -m "feat: add your feature description"
```

### 4.2 DNS 脚本扩展

如果需要扩展或修改 DNS 验证脚本逻辑：

1. **理解现有脚本**：
   - 熟悉 `plugins/dns/aliyun.sh` 的工作原理
   - 了解 Certbot 的钩子机制和 DNS-01 验证流程

2. **修改脚本**：
   - 保持命令行接口兼容性（支持 `clean` 参数）
   - 确保脚本能够正确处理 `CERTBOT_DOMAIN` 和 `CERTBOT_VALIDATION` 环境变量
   - 添加适当的错误处理和日志记录

3. **测试变更**：
   - 使用实际域名测试 DNS 记录添加
   - 验证记录可以正确删除
   - 测试边缘情况和错误条件

### 4.3 支持其他 DNS 提供商

要支持其他 DNS 提供商，请按照以下步骤操作：

1. **创建新的 DNS 脚本**：
   - 在 `plugins/dns/` 目录下创建新的脚本文件，例如 `cloudflare.sh`
   - 遵循现有脚本的接口约定
   - 实现特定提供商的 API 调用逻辑

2. **脚本要求**：
   - 脚本必须支持两种操作模式：添加记录和删除记录
   - 添加记录：`./cloudflare.sh`（不带参数）
   - 删除记录：`./cloudflare.sh clean`
   - 脚本必须处理 `CERTBOT_DOMAIN` 和 `CERTBOT_VALIDATION` 环境变量

3. **实现示例**：
```bash
#!/bin/bash

# Cloudflare DNS 验证脚本
# 用于 Let's Encrypt DNS-01 验证

# 设置默认值
API_TOKEN=""
DOMAIN=""
RECORD="_acme-challenge"
VALUE=""
ACTION="add"

# 解析命令行参数
if [ "$1" == "clean" ]; then
    ACTION="delete"
    shift
fi

# 从环境变量获取域名和验证值
if [ -n "$CERTBOT_DOMAIN" ]; then
    DOMAIN="$CERTBOT_DOMAIN"
fi

if [ -n "$CERTBOT_VALIDATION" ]; then
    VALUE="$CERTBOT_VALIDATION"
fi

# 从环境变量或配置文件获取 API 令牌
if [ -n "$CLOUDFLARE_API_TOKEN" ]; then
    API_TOKEN="$CLOUDFLARE_API_TOKEN"
elif [ -f "$HOME/.cloudflare/credentials" ]; then
    API_TOKEN=$(grep "api_token" "$HOME/.cloudflare/credentials" | cut -d= -f2 | xargs)
fi

# 检查必要参数
if [ -z "$DOMAIN" ] || [ -z "$VALUE" ] || [ -z "$API_TOKEN" ]; then
    echo "错误: 缺少必要参数"
    echo "请确保设置了 CERTBOT_DOMAIN, CERTBOT_VALIDATION 和 CLOUDFLARE_API_TOKEN"
    exit 1
fi

# 提取域名信息
# 实现域名处理逻辑...

# 执行 DNS 操作
if [ "$ACTION" == "add" ]; then
    # 添加 DNS 记录
    # 实现 API 调用...
    echo "已添加 DNS 记录"
elif [ "$ACTION" == "delete" ]; then
    # 删除 DNS 记录
    # 实现 API 调用...
    echo "已删除 DNS 记录"
fi
```

4. **更新配置**：
   - 确保 `entrypoint.sh` 能够识别新的提供商
   - 添加必要的环境变量支持

5. **更新文档**：
   - 在 `docs/04-usage-guide.md` 中添加新提供商的使用说明
   - 更新 `docs/.env.example` 添加新的配置选项

### 4.4 HTTP 验证插件开发

除了 DNS 验证外，X Certbot 还支持 HTTP 验证。要开发 HTTP 验证插件：

1. **创建新的 HTTP 脚本**：
   - 在 `plugins/http/` 目录下创建新的脚本文件
   - 遵循与 DNS 插件类似的接口约定

2. **脚本要求**：
   - 脚本必须支持添加和删除验证文件
   - 脚本必须处理 `CERTBOT_DOMAIN`、`CERTBOT_VALIDATION` 和 `CERTBOT_TOKEN` 环境变量

3. **实现关键功能**：
   - 将验证文件上传到 Web 服务器
   - 确保验证文件可通过 `http://<domain>/.well-known/acme-challenge/<token>` 访问
   - 验证完成后删除验证文件

4. **更新配置**：
   - 在 `entrypoint.sh` 中添加对新 HTTP 插件的支持
   - 设置 `CHALLENGE_TYPE=http` 以启用 HTTP 验证

## 5. 测试指南

### 5.1 手动测试

1. **环境变量测试**：
   - 测试所有必需环境变量
   - 测试错误的环境变量组合

2. **DNS 操作测试**：
   - 测试 DNS 记录添加
   - 测试 DNS 记录删除
   - 测试无效域名场景

3. **证书流程测试**：
   - 测试完整的证书申请流程
   - 测试证书续期流程
   - 测试部署钩子执行

### 5.2 自动化测试

对于自动化测试，可以构建测试脚本验证各个组件：

```bash
#!/bin/bash
# 示例测试脚本

# 测试环境变量加载
test_env_loading() {
    # 创建测试 .env 文件
    echo "TEST_VAR=test_value" > test.env
    
    # 运行入口脚本的环境变量加载部分
    source ./test_env_loader.sh
    
    # 验证结果
    if [ "$TEST_VAR" != "test_value" ]; then
        echo "环境变量加载测试失败"
        return 1
    fi
    
    echo "环境变量加载测试通过"
    return 0
}

# 测试域名处理函数
test_domain_processing() {
    # 设置测试域名
    export DOMAINS="example.com,sub.example.com"
    
    # 运行域名处理函数
    source ./test_domain_processor.sh
    result=$(process_domains)
    
    # 验证结果
    expected="-d example.com -d *.example.com -d sub.example.com"
    if [ "$result" != "$expected" ]; then
        echo "域名处理测试失败"
        echo "期望: $expected"
        echo "实际: $result"
        return 1
    fi
    
    echo "域名处理测试通过"
    return 0
}

# 运行测试
test_env_loading
test_domain_processing
```

## 6. 持续集成/持续部署

项目使用 GitHub Actions 实现 CI/CD 流程。

### 6.1 GitHub Actions 工作流

项目包含以下主要工作流：

1. **Docker 镜像构建与发布** (`.github/workflows/docker-publish.yml`):
   - 在代码推送到主分支或发布标签时触发
   - 构建 Docker 镜像
   - 自动提取版本信息
   - 推送到 Docker Hub 和阿里云容器镜像服务
   - 支持多平台构建 (linux/amd64, linux/arm64)

2. **证书自动续期示例** (`docs/certbot-renew-example.yml`):
   - 提供给用户的 GitHub Actions 工作流示例
   - 用于自动获取和部署证书
   - 支持定时执行、手动触发和版本发布触发
   - 包含证书部署和服务重启功能

### 6.2 Docker 镜像发布工作流

`docker-publish.yml` 工作流的主要功能：

```yaml
name: Docker Image CI

on:
  push:
    branches: [ "main" ]
    tags: [ 'v*.*.*' ]
  pull_request:
    branches: [ "main" ]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        with:
          fetch-depth: 0
          
      - name: Extract version
        id: version
        run: |
          # 提取版本信息逻辑...
          
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
        
      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ vars.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}
          
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: .
          platforms: linux/amd64,linux/arm64
          push: true
          tags: ${{ steps.version.outputs.tags }}
          build-args: |
            VERSION=${{ steps.version.outputs.version }}
```

### 6.3 证书自动续期工作流

`certbot-renew-example.yml` 工作流的主要功能：

```yaml
name: Certbot Certificate Renewal

on:
  schedule:
    - cron: '0 0 * * 1,4'  # 每周一和周四凌晨执行
  workflow_dispatch:  # 允许手动触发
  push:
    tags:
      - 'v*.*.*'  # 发布新版本时触发

jobs:
  renew-certificates:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout code
        uses: actions/checkout@v4
        
      - name: Set up Docker
        uses: docker/setup-buildx-action@v3
        
      - name: Run Certbot container
        run: |
          # 运行 X Certbot 容器获取证书...
          
      - name: Deploy certificates to server
        uses: appleboy/scp-action@v0.1.7
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USERNAME }}
          key: ${{ secrets.SERVER_SSH_KEY }}
          source: "./certs/*"
          target: ${{ secrets.CERT_DESTINATION_PATH }}
          
      - name: Restart services
        uses: appleboy/ssh-action@v1.2.1
        with:
          host: ${{ secrets.SERVER_HOST }}
          username: ${{ secrets.SERVER_USERNAME }}
          key: ${{ secrets.SERVER_SSH_KEY }}
          script: |
            # 重启服务...
```

### 6.4 配置 CI/CD

要配置 CI/CD 环境，需要设置以下 GitHub Secrets 和 Variables：

#### Docker 镜像发布所需配置

| 名称 | 类型 | 说明 |
|------|------|------|
| DOCKERHUB_USERNAME | Variable | Docker Hub 用户名 |
| DOCKERHUB_TOKEN | Secret | Docker Hub 访问令牌 |
| ALIYUN_CR_USERNAME | Secret | 阿里云容器镜像服务用户名 |
| ALIYUN_CR_PASSWORD | Secret | 阿里云容器镜像服务密码 |
| ALIYUN_CR_URL | Secret | 阿里云容器镜像服务注册地址 |
| ALIYUN_CR_NAMESPACE | Variable | 阿里云容器镜像服务命名空间 |

#### 证书自动续期所需配置

| 名称 | 类型 | 说明 |
|------|------|------|
| ALIYUN_REGION | Secret | 阿里云区域 |
| ALIYUN_ACCESS_KEY_ID | Secret | 阿里云访问密钥 ID |
| ALIYUN_ACCESS_KEY_SECRET | Secret | 阿里云访问密钥 Secret |
| DOMAINS | Secret | 域名列表，逗号分隔 |
| EMAIL | Secret | 证书所有者的电子邮件地址 |
| SERVER_HOST | Secret | 目标服务器 IP 或域名 |
| SERVER_USERNAME | Secret | SSH 用户名 |
| SERVER_SSH_KEY | Secret | SSH 私钥 |
| CERT_DESTINATION_PATH | Secret | 证书目标路径 |
| RESTART_COMMAND | Secret | 证书部署后运行的命令（可选） |
| WEBHOOK_URL | Secret | 用于通知的 Webhook URL（可选） |

## 7. 发布流程

### 7.1 版本规范

项目使用语义化版本控制 (SemVer)：

- **主版本号**：不兼容的 API 变更
- **次版本号**：向后兼容的功能性新增
- **修订号**：向后兼容的问题修正

### 7.2 发布步骤

1. **更新版本号**:
   - 在相关文件中更新版本号
   - 提交更新： `git commit -m "build: bump version to x.y.z"`

2. **创建发布标签**:
```bash
git tag -a vx.y.z -m "Release version x.y.z"
git push origin vx.y.z
```

3. **创建 GitHub Release**:
   - 访问 GitHub 仓库的 Releases 页面
   - 创建新的 Release，选择刚推送的标签
   - 添加详细的发布说明

4. **监控自动构建**:
   - 确保 GitHub Actions 自动构建成功
   - 验证新镜像已推送到 Docker Hub 和阿里云容器镜像服务

## 8. 贡献指南

### 8.1 贡献流程

1. Fork 项目仓库
2. 创建功能分支： `git checkout -b feature/amazing-feature`
3. 提交更改： `git commit -m 'feat: add some amazing feature'`
4. 推送分支： `git push origin feature/amazing-feature`
5. 提交 Pull Request

### 8.2 提交信息规范

使用 Conventional Commits 规范：

- `feat`: 新功能
- `fix`: 修复 bug
- `docs`: 文档更新
- `style`: 代码风格调整
- `refactor`: 重构代码
- `perf`: 性能优化
- `test`: 添加或修改测试
- `build`: 构建系统或依赖相关
- `ci`: CI 配置和脚本

示例：

```
feat: 添加对多区域部署的支持

- 实现了阿里云多区域 DNS 记录添加
- 更新了文档说明多区域配置方法
- 添加了相关测试用例
```

### 8.3 代码审查指南

贡献者应遵循以下代码审查准则：

1. 确保代码满足代码规范
2. 确保添加了适当的测试
3. 确保更新了相关文档
4. 确保所有测试通过
5. 请求多人审查重要变更 