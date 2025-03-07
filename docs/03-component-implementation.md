# X Certbot - 组件实现文档

本文档详细说明系统各个组件的实现细节，包括脚本、配置和工作原理。

## 1. 入口脚本 (entrypoint.sh)

入口脚本是容器启动后的主要入口点，负责初始化环境、处理命令行参数、执行证书申请/续期操作。

### 功能实现

1. **环境变量加载**:
```bash
# 加载环境变量从 .env 文件（如果存在）
if [ -f "/.env" ]; then
    echo "Loading environment variables from /.env file"
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # 跳过注释和空行
        [[ $key =~ ^#.*$ ]] || [ -z "$key" ] && continue
        # 移除首尾空白
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        # 仅在命令行未设置时设置
        if [ -z "${!key}" ]; then
            export "$key"="$value"
            echo "Set $key from .env file"
        else
            echo "$key already set, using existing value"
        fi
    done < /.env
fi
```

2. **环境变量检查**:
```bash
# 检查必需的环境变量
if [ -z "$ALIYUN_REGION" ] || [ -z "$ALIYUN_ACCESS_KEY_ID" ] || [ -z "$ALIYUN_ACCESS_KEY_SECRET" ] || [ -z "$DOMAINS" ] || [ -z "$EMAIL" ]; then
    echo "Error: Missing required environment variables. Please set: ALIYUN_REGION, ALIYUN_ACCESS_KEY_ID, ALIYUN_ACCESS_KEY_SECRET, DOMAINS, EMAIL"
    exit 1
fi
```

3. **Aliyun CLI 配置**:
```bash
# 配置 Aliyun CLI
aliyun configure set --profile akProfile --mode AK --region $ALIYUN_REGION --access-key-id $ALIYUN_ACCESS_KEY_ID --access-key-secret $ALIYUN_ACCESS_KEY_SECRET
```

4. **域名处理函数**:
```bash
# 函数用于解析域名并构建 certbot 命令
process_domains() {
    local domains_array
    # 解析逗号分隔的域名列表
    IFS=',' read -ra domains_array <<< "$DOMAINS"

    local domain_params=""
    for domain in "${domains_array[@]}"; do
        # 去除空白
        domain=$(echo "$domain" | xargs)
        # 添加主域名
        domain_params="$domain_params -d $domain"
        
        # 检查是否为顶级域名（只包含一个点）
        if [[ $(echo "$domain" | grep -o "\." | wc -l) -eq 1 ]]; then
            # 如果是顶级域名，添加通配符
            domain_params="$domain_params -d *.$domain"
            echo "Adding wildcard for top-level domain: *.$domain"
        fi
    done
    
    echo $domain_params
}
```

5. **证书续期处理**:
```bash
# 主执行流程
if [ "$1" == "renew" ]; then
    echo "Renewing certificates using $CHALLENGE_TYPE challenge with $CLOUD_PROVIDER provider..."
    
    certbot_args="--manual --preferred-challenges $CHALLENGE_TYPE \
        --manual-auth-hook \"$AUTH_HOOK\" \
        --manual-cleanup-hook \"$CLEANUP_HOOK\" \
        --agree-tos --email $EMAIL \
        --deploy-hook \"$DEPLOY_HOOK\""
    
    if [ "$CHALLENGE_TYPE" == "dns" ]; then
        # DNS specific arguments
        export DNS_PROPAGATION_SECONDS
    fi
    
    eval "certbot renew $certbot_args"
    
    exit $?
fi
```

6. **证书申请处理**:
```bash
# 获取域名参数
DOMAIN_PARAMS=$(process_domains)

# 为所有域名获取证书
echo "Obtaining certificates for $DOMAIN_PARAMS using $CHALLENGE_TYPE challenge with $CLOUD_PROVIDER provider"

certbot_cmd="certbot certonly $DOMAIN_PARAMS --manual --preferred-challenges $CHALLENGE_TYPE \
    --manual-auth-hook \"$AUTH_HOOK\" \
    --manual-cleanup-hook \"$CLEANUP_HOOK\" \
    --agree-tos --email $EMAIL --non-interactive \
    --deploy-hook \"$DEPLOY_HOOK\""

if [ "$CHALLENGE_TYPE" == "dns" ]; then
    # DNS specific environment variables
    export DNS_PROPAGATION_SECONDS
fi

# Execute certbot command
eval $certbot_cmd
```

7. **启动 Cron 服务**:
```bash
# 启动 cron 守护进程
crond -f -l 2
```

## 2. DNS 验证脚本 (plugins/dns/aliyun.sh)

DNS 验证脚本是处理 Certbot DNS-01 挑战的关键组件，负责添加和删除 DNS TXT 记录。

### 功能实现

1. **环境准备**:
```bash
#!/bin/bash

# 激活 Python 虚拟环境
source /opt/venv/bin/activate

# 设置默认值
PROFILE="akProfile"
DOMAIN=""
RECORD="_acme-challenge"
VALUE=""
ACTION="add"
# 默认 DNS 传播等待时间（秒）
DNS_PROPAGATION_SECONDS=${DNS_PROPAGATION_SECONDS:-60}
```

2. **命令行参数处理**:
```bash
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
```

3. **域名处理函数**:
```bash
# 函数用于从子域名提取主域名
get_main_domain() {
    local domain=$1
    
    # 处理特殊中文 TLD，如 .com.cn, .net.cn 等
    if [[ "$domain" =~ .*\.(com|net|org|gov|edu)\.(cn|hk|tw)$ ]]; then
        echo "$domain" | grep -o '[^.]*\.[^.]*\.[^.]*$'
    else
        echo "$domain" | grep -o '[^.]*\.[^.]*$'
    fi
}

# 函数用于获取子域名前缀
get_subdomain_prefix() {
    local domain=$1
    local main_domain=$2
    
    if [ "$domain" == "$main_domain" ]; then
        echo "@"
    else
        echo "${domain%.$main_domain}"
    fi
}
```

4. **域名解析**:
```bash
# 主域名提取
MAIN_DOMAIN=$(get_main_domain "$DOMAIN")
SUBDOMAIN_PREFIX=$(get_subdomain_prefix "$DOMAIN" "$MAIN_DOMAIN")

# 构造完整记录名
if [ "$SUBDOMAIN_PREFIX" == "@" ]; then
    FULL_RECORD_NAME="$RECORD"
else
    FULL_RECORD_NAME="$RECORD.$SUBDOMAIN_PREFIX"
fi
```

5. **DNS 记录添加**:
```bash
# 执行 DNS 操作
if [ "$ACTION" == "add" ]; then
    # 添加 DNS 记录
    echo "Adding DNS record..."
    aliyun --profile "$PROFILE" alidns AddDomainRecord \
        --DomainName "$MAIN_DOMAIN" \
        --RR "$FULL_RECORD_NAME" \
        --Type "TXT" \
        --Value "$VALUE" \
        --TTL 600
    
    # 等待 DNS 传播
    echo "Waiting for DNS propagation (${DNS_PROPAGATION_SECONDS} seconds)..."
    sleep $DNS_PROPAGATION_SECONDS
```

6. **DNS 记录删除**:
```bash
elif [ "$ACTION" == "delete" ]; then
    # 查找记录 ID
    echo "Finding record ID..."
    RECORD_ID=$(aliyun --profile "$PROFILE" alidns DescribeDomainRecords \
        --DomainName "$MAIN_DOMAIN" \
        --RRKeyWord "$FULL_RECORD_NAME" \
        --Type "TXT" \
        --ValueKeyWord "$VALUE" \
        | jq -r '.DomainRecords.Record[0].RecordId')
    
    if [ -n "$RECORD_ID" ] && [ "$RECORD_ID" != "null" ]; then
        # 删除记录
        echo "Deleting record ID: $RECORD_ID"
        aliyun --profile "$PROFILE" alidns DeleteDomainRecord \
            --RecordId "$RECORD_ID"
    else
        echo "Record not found, nothing to delete"
    fi
fi
```

## 3. 证书部署脚本 (deploy-hook.sh)

证书部署脚本负责在证书成功续期后将其部署到指定位置并执行相关操作。

### 功能实现

1. **证书复制**:
```bash
#!/bin/bash

# 该脚本在证书成功续期后由 certbot 调用
# $RENEWED_LINEAGE 包含续期证书的路径

echo "Certificate renewal successful for $RENEWED_LINEAGE"

# 如果不存在则创建目标目录
mkdir -p /etc/letsencrypt/certs

# 将所有证书文件复制到 certs 目录
echo "Copying certificates from $RENEWED_LINEAGE to /etc/letsencrypt/certs"
cp -L "$RENEWED_LINEAGE/fullchain.pem" "/etc/letsencrypt/certs/"
cp -L "$RENEWED_LINEAGE/privkey.pem" "/etc/letsencrypt/certs/"
cp -L "$RENEWED_LINEAGE/cert.pem" "/etc/letsencrypt/certs/"
cp -L "$RENEWED_LINEAGE/chain.pem" "/etc/letsencrypt/certs/"

# 设置适当的权限
chmod 644 /etc/letsencrypt/certs/*.pem
```

2. **执行宿主机脚本**:
```bash
# 如果存在且可执行则执行宿主机脚本
if [ -f "/host-scripts/post-renewal.sh" ] && [ -x "/host-scripts/post-renewal.sh" ]; then
    echo "Executing host post-renewal script..."
    /host-scripts/post-renewal.sh
    echo "Host post-renewal script executed with exit code: $?"
else
    echo "No executable host post-renewal script found at /host-scripts/post-renewal.sh"
fi
```

## 4. Dockerfile 实现

Dockerfile 定义了容器的构建过程，包括依赖安装、脚本配置和环境设置。

### 主要实现

1. **基础镜像与依赖**:
```dockerfile
FROM alpine:latest

# 安装依赖
RUN apk --no-cache add wget tar sudo certbot bash python3 py3-pip jq && \
    apk --no-cache add --virtual build-dependencies gcc musl-dev python3-dev libffi-dev openssl-dev make
```

2. **安装 Aliyun CLI**:
```dockerfile
# 安装 aliyun-cli
RUN wget https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz && \
    tar xzvf aliyun-cli-linux-latest-amd64.tgz && \
    mv aliyun /usr/local/bin && \
    rm aliyun-cli-linux-latest-amd64.tgz
```

3. **复制脚本**:
```dockerfile
# 创建脚本目录
RUN mkdir -p /usr/local/bin/scripts /usr/local/bin/plugins/dns /usr/local/bin/plugins/http

# 复制脚本
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/deploy-hook.sh /usr/local/bin/scripts/deploy-hook.sh
COPY plugins/dns/ /usr/local/bin/plugins/dns/
COPY plugins/http/ /usr/local/bin/plugins/http/

# 设置执行权限
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/scripts/deploy-hook.sh && \
    chmod +x /usr/local/bin/plugins/dns/*.sh /usr/local/bin/plugins/http/*.sh
```

4. **Python 环境配置**:
```dockerfile
# 为 Python 包创建虚拟环境
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# 在虚拟环境中安装 Python 依赖
RUN pip install --upgrade pip && \
    pip install aliyun-python-sdk-core aliyun-python-sdk-alidns
```

5. **环境变量设置**:
```dockerfile
# 设置环境变量（运行时提供）
ENV ALIYUN_REGION=""
ENV ALIYUN_ACCESS_KEY_ID=""
ENV ALIYUN_ACCESS_KEY_SECRET=""
# 域名，以逗号分隔（例如 example.com,test.domain.com）
ENV DOMAINS=""
ENV EMAIL=""
ENV CRON_SCHEDULE="0 0 * * 1,4"
# DNS 传播等待时间（秒）
ENV DNS_PROPAGATION_SECONDS="60"
```

6. **Cron 配置**:
```dockerfile
# 设置 certbot renew 的 cron 任务
RUN echo "$CRON_SCHEDULE /usr/local/bin/entrypoint.sh renew" > /etc/crontabs/root
```

7. **入口点设置**:
```dockerfile
# 确保 cron 运行
RUN touch /var/log/cron.log

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

## 5. Docker 容器运行配置

容器运行配置是将上述组件整合到一起的关键部分。本节主要介绍容器运行的技术实现原理，详细的使用方法请参考[使用指南](04-usage-guide.md)中的"运行容器"章节。

### 5.1 容器运行原理

容器启动时会执行以下步骤：

1. **环境变量加载**：
   - 首先检查是否存在 `/.env` 文件，如存在则加载其中的环境变量
   - 命令行传入的环境变量优先级高于 `.env` 文件中的设置

2. **配置验证**：
   - 验证必要的环境变量是否已设置
   - 配置阿里云 CLI 工具

3. **证书处理流程**：
   - 如果是首次运行，执行证书申请流程
   - 如果指定了 `renew` 参数，执行证书续期流程
   - 根据 `CHALLENGE_TYPE` 和 `CLOUD_PROVIDER` 选择适当的验证钩子

4. **持久化与集成**：
   - 证书文件通过卷映射持久化到宿主机
   - 支持通过 `host-scripts` 目录集成宿主机脚本

### 5.2 容器环境变量处理

入口脚本中的环境变量处理逻辑：

```bash
# 加载环境变量从 .env 文件（如果存在）
if [ -f "/.env" ]; then
    echo "Loading environment variables from /.env file"
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # 跳过注释和空行
        [[ $key =~ ^#.*$ ]] || [ -z "$key" ] && continue
        # 移除首尾空白
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        # 仅在命令行未设置时设置
        if [ -z "${!key}" ]; then
            export "$key"="$value"
            echo "Set $key from .env file"
        else
            echo "$key already set, using existing value"
        fi
    done < /.env
fi
```

### 5.3 技术实现要点

1. **卷映射机制**：
   - `/etc/letsencrypt/certs` - 证书输出目录
   - `/.env` - 环境变量配置文件
   - `/host-scripts` - 宿主机脚本目录

2. **环境变量优先级**：
   - 命令行参数 > .env 文件 > 默认值

3. **容器生命周期**：
   - 容器启动后执行证书申请
   - 通过 cron 任务定期执行证书续期
   - 支持手动触发证书续期

## 6. 错误处理与日志

系统在各个组件中实现了错误处理和日志记录。

1. **入口脚本错误处理**:
   - 检查必需环境变量是否设置
   - 捕获和传递 certbot 命令的退出码

2. **DNS 脚本错误处理**:
   - 在添加和删除 DNS 记录时进行错误检查
   - 记录详细的操作日志

3. **部署钩子错误处理**:
   - 记录宿主机脚本的执行结果和退出码
   - 确保目录存在和权限正确

4. **容器日志**:
   - 所有脚本输出都会记录到 Docker 日志
   - 可通过 `docker logs x.certbot` 查看 