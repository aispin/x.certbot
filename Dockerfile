FROM alpine:latest

# Install dependencies
RUN apk --no-cache add wget tar sudo certbot bash python3 py3-pip jq curl openssl && \
    apk --no-cache add --virtual build-dependencies gcc musl-dev python3-dev libffi-dev openssl-dev make

# Install aliyun-cli
RUN wget https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz && \
    tar xzvf aliyun-cli-linux-latest-amd64.tgz && \
    mv aliyun /usr/local/bin && \
    rm aliyun-cli-linux-latest-amd64.tgz

# Install Tencent Cloud CLI (optional - used when CLOUD_PROVIDER=tencentcloud)
RUN mkdir -p /tmp/tencentcloud && \
    cd /tmp/tencentcloud && \
    wget https://github.com/TencentCloud/tencentcloud-cli/archive/refs/tags/3.0.0.zip && \
    unzip 3.0.0.zip && \
    cd tencentcloud-cli-3.0.0 && \
    pip install . && \
    cd / && \
    rm -rf /tmp/tencentcloud

# Create directories
RUN mkdir -p /usr/local/bin/scripts /usr/local/bin/plugins/dns /usr/local/bin/plugins/http

# Copy scripts and plugins
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/deploy-hook.sh /usr/local/bin/scripts/deploy-hook.sh
COPY plugins/dns/ /usr/local/bin/plugins/dns/
COPY plugins/http/ /usr/local/bin/plugins/http/

# Set execute permissions
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/scripts/deploy-hook.sh && \
    chmod +x /usr/local/bin/plugins/dns/*.sh /usr/local/bin/plugins/http/*.sh

# Create virtual environment for Python packages
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install Python dependencies in virtual environment
RUN pip install --upgrade pip && \
    pip install aliyun-python-sdk-core aliyun-python-sdk-alidns tencentcloud-sdk-python

# Create HTTP challenge webroot directory
RUN mkdir -p /var/www/html/.well-known/acme-challenge && \
    chmod -R 755 /var/www/html

# Set environment variables (to be provided during runtime)
# Core variables
ENV DOMAINS=""
ENV EMAIL=""
# Challenge and provider configuration
ENV CHALLENGE_TYPE="dns"
ENV CLOUD_PROVIDER="aliyun"
ENV ENABLE_WILDCARDS="true"
# Provider-specific variables
ENV ALIYUN_REGION=""
ENV ALIYUN_ACCESS_KEY_ID=""
ENV ALIYUN_ACCESS_KEY_SECRET=""
ENV TENCENTCLOUD_SECRET_ID=""
ENV TENCENTCLOUD_SECRET_KEY=""
# HTTP challenge configuration
ENV WEBROOT_PATH="/var/www/html"
# DNS configuration
ENV DNS_PROPAGATION_SECONDS="60"
# Hooks configuration (can be overridden to use custom hooks)
ENV AUTH_HOOK=""
ENV CLEANUP_HOOK=""
ENV DEPLOY_HOOK=""
# Certificate output configuration
ENV CERT_OUTPUT_DIR="/etc/letsencrypt/certs"
ENV CREATE_DOMAIN_DIRS="false"
ENV CREATE_METADATA="false"
ENV CERT_FILE_PERMISSIONS="644"
# Webhook notification (optional)
ENV WEBHOOK_URL=""
# Cron configuration
ENV CRON_ENABLED="false"
ENV CRON_SCHEDULE="0 0 * * 1,4"
# Keep container running even without cron
ENV KEEP_RUNNING="false"

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
