#!/bin/bash

# 加载控制台工具
if [ -f "/usr/local/bin/scripts/console_utils.sh" ]; then
    source /usr/local/bin/scripts/console_utils.sh
fi

# 打印欢迎标题
print_header "Let's Encrypt 证书自动化工具"
print_info "开始执行证书管理流程..."

# Load environment variables from .env file if it exists
if [ -f "/.env" ]; then
    print_env "从 /.env 文件加载环境变量"
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        [[ $key =~ ^#.*$ ]] || [ -z "$key" ] && continue
        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        # Only set if not already set from command line
        if [ -z "${!key}" ]; then
            export "$key"="$value"
            print_env "设置变量: $key"
        else
            print_env "$key 已设置，使用现有值"
        fi
    done < /.env
fi

# Activate the virtual environment
source /opt/venv/bin/activate
print_success "已激活 Python 虚拟环境"

# Check required environment variables
if [ -z "$DOMAIN_ARG" ] || [ -z "$EMAIL" ]; then
    print_error "缺少必需的环境变量。请设置: DOMAIN_ARG, EMAIL"
    exit 1
fi

# Set default values
CHALLENGE_TYPE=${CHALLENGE_TYPE:-"dns"}
CLOUD_PROVIDER=${CLOUD_PROVIDER:-"aliyun"}
DNS_PROPAGATION_SECONDS=${DNS_PROPAGATION_SECONDS:-60}

print_subheader "配置信息"
print_key_value "域名参数" "$DOMAIN_ARG"
print_key_value "邮箱" "$EMAIL"
print_key_value "验证类型" "$CHALLENGE_TYPE"
print_key_value "云服务提供商" "$CLOUD_PROVIDER"
if [ "$CHALLENGE_TYPE" == "dns" ]; then
    print_key_value "DNS 传播时间" "${DNS_PROPAGATION_SECONDS}秒"
fi

# Define hooks based on provider and challenge type
if [ -z "$AUTH_HOOK" ]; then
    if [ "$CHALLENGE_TYPE" == "dns" ]; then
        AUTH_HOOK="/usr/local/bin/plugins/dns/${CLOUD_PROVIDER}.sh"
        print_dns "使用 DNS 验证钩子: $AUTH_HOOK"
    elif [ "$CHALLENGE_TYPE" == "http" ]; then
        AUTH_HOOK="/usr/local/bin/plugins/http/${CLOUD_PROVIDER}.sh"
        print_http "使用 HTTP 验证钩子: $AUTH_HOOK"
    else
        print_error "不支持的验证类型: $CHALLENGE_TYPE。支持的类型: dns, http"
        exit 1
    fi
fi

if [ -z "$CLEANUP_HOOK" ]; then
    if [ "$CHALLENGE_TYPE" == "dns" ]; then
        CLEANUP_HOOK="/usr/local/bin/plugins/dns/${CLOUD_PROVIDER}.sh clean"
        print_dns "使用 DNS 清理钩子: $CLEANUP_HOOK"
    elif [ "$CHALLENGE_TYPE" == "http" ]; then
        CLEANUP_HOOK="/usr/local/bin/plugins/http/${CLOUD_PROVIDER}.sh clean"
        print_http "使用 HTTP 清理钩子: $CLEANUP_HOOK"
    fi
fi

DEPLOY_HOOK=${DEPLOY_HOOK:-"/usr/local/bin/scripts/deploy-hook.sh"}
print_deploy "使用部署钩子: $DEPLOY_HOOK"

# Check if hook scripts exist and are executable
check_hook() {
    local hook_path=$1
    local hook_type=$2
    local clean_arg=$3
    
    # Extract base path for clean argument
    if [ -n "$clean_arg" ]; then
        hook_path=${hook_path% clean}
    fi
    
    if [ ! -f "$hook_path" ]; then
        print_error "$hook_type 钩子未找到: $hook_path"
        exit 1
    fi
    
    if [ ! -x "$hook_path" ]; then
        print_warning "$hook_type 钩子不可执行: $hook_path"
        chmod +x "$hook_path"
        print_success "已将 $hook_type 钩子设为可执行"
    fi
}

# Configure cloud provider if needed
configure_provider() {
    print_subheader "配置云服务提供商"
    
    if [ "$CLOUD_PROVIDER" == "aliyun" ]; then
        if [ -z "$ALIYUN_REGION" ] || [ -z "$ALIYUN_ACCESS_KEY_ID" ] || [ -z "$ALIYUN_ACCESS_KEY_SECRET" ]; then
            print_error "对于阿里云提供商，请设置: ALIYUN_REGION, ALIYUN_ACCESS_KEY_ID, ALIYUN_ACCESS_KEY_SECRET"
            exit 1
        fi
        
        # Configure Aliyun CLI
        print_cloud_provider "aliyun" "配置阿里云 CLI..."
        aliyun configure set --profile akProfile --mode AK --region $ALIYUN_REGION --access-key-id $ALIYUN_ACCESS_KEY_ID --access-key-secret $ALIYUN_ACCESS_KEY_SECRET
        print_success "阿里云 CLI 配置完成"
        
    elif [ "$CLOUD_PROVIDER" == "tencentcloud" ]; then
        if [ -z "$TENCENTCLOUD_SECRET_ID" ] || [ -z "$TENCENTCLOUD_SECRET_KEY" ]; then
            print_error "对于腾讯云提供商，请设置: TENCENTCLOUD_SECRET_ID, TENCENTCLOUD_SECRET_KEY"
            exit 1
        fi
        
        # Set default region if not provided
        TENCENTCLOUD_REGION=${TENCENTCLOUD_REGION:-"ap-guangzhou"}
        
        # Export environment variables for Tencent Cloud CLI and SDK
        export TENCENTCLOUD_SECRET_ID=$TENCENTCLOUD_SECRET_ID
        export TENCENTCLOUD_SECRET_KEY=$TENCENTCLOUD_SECRET_KEY
        export TENCENTCLOUD_REGION=$TENCENTCLOUD_REGION
        
        # Ensure tccli from virtual environment is used
        print_cloud_provider "tencentcloud" "使用虚拟环境中的 tccli"
        export PATH="/opt/venv/bin:$PATH"
        
        # Configure Tencent Cloud CLI non-interactively
        print_cloud_provider "tencentcloud" "配置腾讯云 CLI..."
        tccli configure set secretId "$TENCENTCLOUD_SECRET_ID" 2>/dev/null
        tccli configure set secretKey "$TENCENTCLOUD_SECRET_KEY" 2>/dev/null
        tccli configure set region "$TENCENTCLOUD_REGION" 2>/dev/null
        tccli configure set output "json" 2>/dev/null
        
        # Verify configuration
        print_cloud_provider "tencentcloud" "验证腾讯云 CLI 配置..."
        if ! tccli configure list >/dev/null 2>&1; then
            print_warning "无法验证腾讯云 CLI 配置"
        else
            print_success "腾讯云 CLI 配置成功"
        fi
    fi
    
    # Additional providers can be added here
}

# Execute hook check
print_subheader "检查钩子脚本"
check_hook "$AUTH_HOOK" "验证" 
check_hook "$CLEANUP_HOOK" "清理" "clean"
check_hook "$DEPLOY_HOOK" "部署"
print_success "所有钩子脚本检查通过"

# Configure the selected cloud provider
configure_provider

# Main execution
if [ "$1" == "renew" ]; then
    print_header "更新证书" >&2
    print_info "使用 $CHALLENGE_TYPE 验证方式和 $CLOUD_PROVIDER 提供商更新证书..." >&2
    
    if [ "$CHALLENGE_TYPE" == "dns" ]; then
        # DNS specific arguments
        export DNS_PROPAGATION_SECONDS
        print_dns "设置 DNS 传播等待时间: ${DNS_PROPAGATION_SECONDS}秒" >&2
    fi
    
    # 打印完整的 certbot 命令
    print_subheader "Certbot 命令" >&2
    print_info "certbot renew --manual --preferred-challenges $CHALLENGE_TYPE --manual-auth-hook $AUTH_HOOK --manual-cleanup-hook $CLEANUP_HOOK --agree-tos --email $EMAIL --deploy-hook $DEPLOY_HOOK" >&2
    
    print_info "执行证书更新命令..." >&2
    
    # 直接执行命令，不使用 eval
    certbot renew --manual \
        --preferred-challenges "$CHALLENGE_TYPE" \
        --manual-auth-hook "$AUTH_HOOK" \
        --manual-cleanup-hook "$CLEANUP_HOOK" \
        --agree-tos \
        --email "$EMAIL" \
        --deploy-hook "$DEPLOY_HOOK"
    
    if [ $? -eq 0 ]; then
        print_success "证书更新完成" >&2
    else
        print_error "证书更新失败" >&2
    fi
    
    exit $?
fi

# Get domain parameters
print_step "1" "准备域名参数" >&2
print_subheader "处理域名" >&2
print_info "直接使用用户提供的域名参数" >&2
print_cert "域名参数: $DOMAIN_ARG" >&2

# Obtain the certificates for all domains
print_step "2" "获取证书" >&2
print_info "使用 $CHALLENGE_TYPE 验证方式和 $CLOUD_PROVIDER 提供商获取证书" >&2

if [ "$CHALLENGE_TYPE" == "dns" ]; then
    # DNS specific environment variables
    export DNS_PROPAGATION_SECONDS
    print_dns "设置 DNS 传播等待时间: ${DNS_PROPAGATION_SECONDS}秒" >&2
fi

# 打印完整的 certbot 命令
print_subheader "Certbot 命令" >&2
cmd_preview="certbot certonly $DOMAIN_ARG --manual --preferred-challenges $CHALLENGE_TYPE --manual-auth-hook $AUTH_HOOK --manual-cleanup-hook $CLEANUP_HOOK --agree-tos --email $EMAIL --non-interactive --deploy-hook $DEPLOY_HOOK"
print_info "$cmd_preview" >&2

# Execute certbot command
print_info "执行 Certbot 命令..." >&2

# 直接执行命令，不使用 eval，但要注意 DOMAIN_ARG 可能包含空格，所以不加引号
certbot certonly $DOMAIN_ARG \
    --manual \
    --preferred-challenges "$CHALLENGE_TYPE" \
    --manual-auth-hook "$AUTH_HOOK" \
    --manual-cleanup-hook "$CLEANUP_HOOK" \
    --agree-tos \
    --email "$EMAIL" \
    --non-interactive \
    --deploy-hook "$DEPLOY_HOOK"

if [ $? -eq 0 ]; then
    print_success "证书获取成功" >&2
else
    print_error "证书获取失败" >&2
fi

# Start cron daemon if CRON_ENABLED is true
if [ "$CRON_ENABLED" == "true" ]; then
    print_step "3" "设置定时任务" >&2
    echo "$CRON_SCHEDULE /usr/local/bin/entrypoint.sh renew" > /etc/crontabs/root
    print_cron "启动定时任务，计划: $CRON_SCHEDULE" >&2
    crond -f -l 2
else
    print_info "未启用定时任务 (CRON_ENABLED != true)" >&2
    # Keep container running if KEEP_RUNNING is true
    if [ "$KEEP_RUNNING" == "true" ]; then
        print_info "容器将保持运行 (KEEP_RUNNING=true)" >&2
        tail -f /dev/null
    fi
fi

print_header "任务完成" >&2
