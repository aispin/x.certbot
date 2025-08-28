FROM alpine:latest

# Define build arguments for CLI download URLs
ARG ALIYUN_CLI_URL="https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz"

# Install dependencies
RUN apk --no-cache add wget tar sudo certbot bash python3 py3-pip jq curl openssl bind-tools idn2-utils && \
    apk --no-cache add --virtual build-dependencies gcc musl-dev python3-dev libffi-dev openssl-dev make

# Install aliyun-cli
RUN wget ${ALIYUN_CLI_URL} -O aliyun-cli.tgz && \
    tar xzvf aliyun-cli.tgz && \
    mv aliyun /usr/local/bin && \
    rm aliyun-cli.tgz

# Create directories
RUN mkdir -p /usr/local/bin/scripts /usr/local/bin/plugins/dns /usr/local/bin/plugins/http

# Copy scripts and plugins
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/deploy-hook.sh /usr/local/bin/scripts/deploy-hook.sh
COPY scripts/console_utils.sh /usr/local/bin/scripts/console_utils.sh
COPY scripts/domain_utils.sh /usr/local/bin/scripts/domain_utils.sh
COPY plugins/dns/ /usr/local/bin/plugins/dns/
COPY plugins/http/ /usr/local/bin/plugins/http/

# Set execute permissions
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/scripts/deploy-hook.sh /usr/local/bin/scripts/console_utils.sh /usr/local/bin/scripts/domain_utils.sh && \
    chmod +x /usr/local/bin/plugins/dns/*.sh /usr/local/bin/plugins/http/*.sh

# Create virtual environment for Python packages
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install Python dependencies in virtual environment
# 阿里云：aliyun-python-sdk-core aliyun-python-sdk-alidns
# 腾讯云：tccli
RUN pip install --upgrade pip && \
    pip install aliyun-python-sdk-core aliyun-python-sdk-alidns tccli

# Create HTTP challenge webroot directory
RUN mkdir -p /var/www/html/.well-known/acme-challenge && \
    chmod -R 755 /var/www/html

# Set environment variables (to be provided during runtime)
#---------------------------------
# 核心配置
#---------------------------------
# 域名参数 - 传递给 certbot 的完整的参数，如 -d example.com -d *.example.com
ENV DOMAIN_ARG=""
# 邮箱 - 用于接收证书更新通知
ENV EMAIL=""

#---------------------------------
# 验证方式与云服务商配置
#---------------------------------
# 验证方式 - dns 或 http
ENV CHALLENGE_TYPE="dns"
# 云服务提供商 - aliyun 或 tencentcloud
ENV CLOUD_PROVIDER="aliyun"

#---------------------------------
# 阿里云配置 (当 CLOUD_PROVIDER=aliyun 时使用)
#---------------------------------
# 阿里云区域
ENV ALIYUN_REGION=""
# 阿里云访问密钥（建议使用 RAM 用户的密钥，只需要 DNS 修改权限）
ENV ALIYUN_ACCESS_KEY_ID=""
ENV ALIYUN_ACCESS_KEY_SECRET=""

#---------------------------------
# 腾讯云配置 (当 CLOUD_PROVIDER=tencentcloud 时使用)
#---------------------------------
# 腾讯云 API 密钥
ENV TENCENTCLOUD_SECRET_ID=""
ENV TENCENTCLOUD_SECRET_KEY=""
# 腾讯云区域
ENV TENCENTCLOUD_REGION="ap-guangzhou"

#---------------------------------
# HTTP 验证配置 (当 CHALLENGE_TYPE=http 时使用)
#---------------------------------
# Web 根目录路径（用于放置验证文件）
ENV WEBROOT_PATH="/var/www/html"

#---------------------------------
# DNS 验证配置 (当 CHALLENGE_TYPE=dns 时使用)
#---------------------------------
# DNS 记录传播等待时间（秒）
ENV DNS_PROPAGATION_SECONDS="60"

#---------------------------------
# 钩子脚本配置 (可选)
#---------------------------------
# 认证钩子 - 根据 CHALLENGE_TYPE 和 CLOUD_PROVIDER 自动选择对应的钩子
# 除非想完全自定义，否则不要设置
ENV AUTH_HOOK=""
# 清理钩子 - 根据 CHALLENGE_TYPE 和 CLOUD_PROVIDER 自动选择对应的钩子
# 除非想完全自定义，否则不要设置
ENV CLEANUP_HOOK=""
# 部署钩子 - 证书实际更新后调用，见 scripts/deploy-hook.sh
# 除非想完全自定义，否则不要设置
ENV DEPLOY_HOOK=""
# 证书更新后执行的自定义脚本 - 用于重启服务或分发证书等操作
# 推荐直接使用挂载宿主机脚本 -v /path/on/host/restart-services.sh:/host-scripts/post-renewal.sh
ENV POST_RENEWAL_SCRIPT=""

#---------------------------------
# 证书输出配置
#---------------------------------
# 证书输出目录
ENV CERT_OUTPUT_DIR="/etc/letsencrypt/certs/live"
# 是否为每个域名创建单独的子目录
ENV CREATE_DOMAIN_DIRS="true"
# 是否创建证书元数据文件
ENV CREATE_METADATA="true"
# 证书文件权限
ENV CERT_FILE_PERMISSIONS="644"

#---------------------------------
# 通知配置
#---------------------------------
# Webhook URL（证书续期成功后通知）
ENV WEBHOOK_URL=""

#---------------------------------
# 自动续期与容器运行配置
#---------------------------------
# 是否启用 cron 自动续期
ENV CRON_ENABLED="false"
# 证书自动续期的 cron 表达式（默认每周一和周四凌晨 0 点）
ENV CRON_SCHEDULE="0 0 * * 1,4"
# 是否保持容器运行（即使不启用 cron）
ENV KEEP_RUNNING="false"

#---------------------------------
# 控制台输出配置
#---------------------------------
# 禁用彩色输出
ENV NO_COLOR="false"
# 禁用 emoji 图标
ENV NO_EMOJI="false"
# 启用调试输出
ENV DEBUG="false"

# Create directories for various purposes
RUN mkdir -p /host-scripts /etc/letsencrypt/certs

# Make sure cron is available
RUN touch /var/log/cron.log

# Define build argument for version
ARG VERSION=dev

# Label container
LABEL org.opencontainers.image.title="X Certbot"
LABEL org.opencontainers.image.description="A Docker container for managing Let's Encrypt certificates with support for multiple cloud providers and challenge types"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.source="https://github.com/aispin/x.certbot"
LABEL org.opencontainers.image.licenses="MIT"
LABEL maintainer="aispin"

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
