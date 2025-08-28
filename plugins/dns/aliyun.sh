#!/bin/bash

# 阿里云 DNS 验证脚本
# 用途: 用于 Let's Encrypt DNS-01 验证挑战的阿里云 DNS 实现
# 功能: 
#   1. 添加 DNS TXT 记录 (_acme-challenge) - 不带参数执行
#   2. 删除 DNS TXT 记录 - 带 clean 参数执行
#   3. 支持中文域名的 punycode 解码
# 环境变量:
#   CERTBOT_DOMAIN - 要验证的域名 (支持中文域名)
#   CERTBOT_VALIDATION - 验证值
#   DNS_PROPAGATION_SECONDS - DNS 传播等待时间 (默认: 60秒)
#   DEBUG - 设置为 true 启用调试输出

# 加载控制台工具 (如果存在)
if [ -f "/usr/local/bin/scripts/console_utils.sh" ]; then
    source "/usr/local/bin/scripts/console_utils.sh"
fi

# 激活 Python 虚拟环境 (用于阿里云 SDK)
source /opt/venv/bin/activate
[ "$DEBUG" = "true" ] && print_debug "已激活 Python 虚拟环境"

# 加载统一的域名处理工具
# 这些函数用于处理域名解析，如提取主域名和子域名前缀
if [ -f "/usr/local/bin/scripts/domain_utils.sh" ]; then
    source "/usr/local/bin/scripts/domain_utils.sh"
    [ "$DEBUG" = "true" ] && print_debug "已加载 domain_utils.sh"
else
    print_error "domain_utils.sh 未找到，这是必需的依赖文件"
    exit 1
fi

# 设置默认值
PROFILE="akProfile"  # 阿里云 CLI 配置文件名
DOMAIN=""            # 要验证的域名
RECORD="_acme-challenge"  # DNS 验证记录名
VALUE=""             # 验证值
ACTION="add"         # 默认操作: 添加记录
# DNS 传播等待时间 (秒)
# 可通过环境变量自定义，适应不同 DNS 提供商的传播速度
DNS_PROPAGATION_SECONDS=${DNS_PROPAGATION_SECONDS:-60}

# 解析命令行参数
# 如果第一个参数是 "clean"，则设置操作为删除记录
if [ "$1" == "clean" ]; then
    ACTION="delete"
    shift
fi

# 从 Certbot 提供的环境变量获取域名和验证值
if [ -n "$CERTBOT_DOMAIN" ]; then
    DOMAIN="$CERTBOT_DOMAIN"
fi

if [ -n "$CERTBOT_VALIDATION" ]; then
    VALUE="$CERTBOT_VALIDATION"
fi

# 检查必要的环境变量是否设置
if [ -z "$DOMAIN" ] || [ -z "$VALUE" ]; then
    print_error "CERTBOT_DOMAIN 和 CERTBOT_VALIDATION 环境变量必须设置。"
    exit 1
fi

# 注意：所有域名处理函数现在都在 domain_utils.sh 中统一管理
# 包括：encode_punycode_domain, decode_punycode_domain, get_main_domain, get_subdomain_prefix

# Main domain extraction with punycode decoding
ORIGINAL_DOMAIN="$DOMAIN"
DECODED_DOMAIN=$(decode_punycode_domain "$DOMAIN")
MAIN_DOMAIN=$(get_main_domain "$DOMAIN")
SUBDOMAIN_PREFIX=$(get_subdomain_prefix "$DOMAIN" "$MAIN_DOMAIN")

# Construct the full record name
if [ "$SUBDOMAIN_PREFIX" == "@" ]; then
    FULL_RECORD_NAME="$RECORD"
else
    FULL_RECORD_NAME="$RECORD.$SUBDOMAIN_PREFIX"
fi

print_subheader "DNS 验证信息"
print_key_value "原始域名" "$ORIGINAL_DOMAIN"
if [ "$ORIGINAL_DOMAIN" != "$DECODED_DOMAIN" ]; then
    print_key_value "解码后域名" "$DECODED_DOMAIN"
fi
print_key_value "主域名" "$MAIN_DOMAIN"
print_key_value "子域名前缀" "$SUBDOMAIN_PREFIX"
print_key_value "记录名" "$FULL_RECORD_NAME"
print_key_value "记录值" "$VALUE"
print_key_value "操作" "$ACTION"

# Perform the DNS operation
if [ "$ACTION" == "add" ]; then
    # Add DNS record
    print_dns "使用阿里云 API 添加 DNS 记录..."
    aliyun --profile "$PROFILE" alidns AddDomainRecord \
        --DomainName "$MAIN_DOMAIN" \
        --RR "$FULL_RECORD_NAME" \
        --Type "TXT" \
        --Value "$VALUE" \
        --TTL 600
    
    result=$?
    if [ $result -ne 0 ]; then
        print_error "添加 DNS 记录失败"
        exit 1
    fi
    
    # 等待 DNS 传播
    print_info "等待 DNS 传播 (${DNS_PROPAGATION_SECONDS} 秒)..."
    sleep $DNS_PROPAGATION_SECONDS
elif [ "$ACTION" == "delete" ]; then
    # Find the record ID
    print_dns "使用阿里云 API 查找记录 ID..."
    RECORD_ID=$(aliyun --profile "$PROFILE" alidns DescribeDomainRecords \
        --DomainName "$MAIN_DOMAIN" \
        --RRKeyWord "$FULL_RECORD_NAME" \
        --Type "TXT" \
        --ValueKeyWord "$VALUE" \
        | jq -r '.DomainRecords.Record[0].RecordId')
    
    if [ -n "$RECORD_ID" ] && [ "$RECORD_ID" != "null" ]; then
        # Delete the record
        print_dns "删除记录 ID: $RECORD_ID"
        aliyun --profile "$PROFILE" alidns DeleteDomainRecord \
            --RecordId "$RECORD_ID"
        
        if [ $? -ne 0 ]; then
            print_error "删除 DNS 记录失败"
            exit 1
        fi
    else
        print_warning "未找到记录，无需删除"
    fi
fi

print_success "阿里云 DNS 操作成功完成"
exit 0 