#!/bin/bash

# 腾讯云 DNS 验证脚本
# 用途: 用于 Let's Encrypt DNS-01 验证挑战的腾讯云 DNSPod 实现
# 功能: 
#   1. 添加 DNS TXT 记录 (_acme-challenge) - 不带参数执行
#   2. 删除 DNS TXT 记录 - 带 clean 参数执行
#   3. 支持中文域名的 punycode 解码
# 环境变量:
#   CERTBOT_DOMAIN - 要验证的域名 (支持中文域名)
#   CERTBOT_VALIDATION - 验证值
#   TENCENTCLOUD_SECRET_ID - 腾讯云 API 密钥 ID
#   TENCENTCLOUD_SECRET_KEY - 腾讯云 API 密钥
#   TENCENTCLOUD_REGION - 腾讯云区域 (默认: ap-guangzhou)
#   DNS_PROPAGATION_SECONDS - DNS 传播等待时间 (默认: 60秒)
#   DEBUG - 设置为 true 启用调试输出

# ================================
# 腾讯云 DNS 插件
# 参考文档：
# 命令行工具：https://github.com/TencentCloud/tencentcloud-cli
# 创建 DNS 记录：https://cloud.tencent.com/document/product/1427/56180
# 删除 DNS 记录：https://cloud.tencent.com/document/product/1427/56168
# ================================

# 加载控制台工具 (用于美化输出和日志记录)
if [ -f "/usr/local/bin/scripts/console_utils.sh" ]; then
    source "/usr/local/bin/scripts/console_utils.sh"
fi

# 激活 Python 虚拟环境 (用于腾讯云 CLI)
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

# 检查腾讯云 API 凭证是否设置
if [ -z "$TENCENTCLOUD_SECRET_ID" ] || [ -z "$TENCENTCLOUD_SECRET_KEY" ]; then
    print_error "TENCENTCLOUD_SECRET_ID 和 TENCENTCLOUD_SECRET_KEY 环境变量必须设置。"
    exit 1
fi

# 导出腾讯云凭证供 tccli 使用
export TENCENTCLOUD_SECRET_ID
export TENCENTCLOUD_SECRET_KEY
export TENCENTCLOUD_REGION=${TENCENTCLOUD_REGION:-"ap-guangzhou"}  # 默认使用广州区域

# 配置腾讯云 CLI
# 使用非交互方式配置 tccli，避免用户输入
print_cloud_provider "tencentcloud" "配置腾讯云 CLI..."
tccli configure set secretId "$TENCENTCLOUD_SECRET_ID" 2>/dev/null
tccli configure set secretKey "$TENCENTCLOUD_SECRET_KEY" 2>/dev/null
tccli configure set region "$TENCENTCLOUD_REGION" 2>/dev/null
tccli configure set output "json" 2>/dev/null

# 注意：所有域名处理函数现在都在 domain_utils.sh 中统一管理
# 包括：encode_punycode_domain, decode_punycode_domain, get_main_domain, get_subdomain_prefix

# 提取主域名和子域名前缀 (支持 punycode 解码)
ORIGINAL_DOMAIN="$DOMAIN"
DECODED_DOMAIN=$(decode_punycode_domain "$DOMAIN")
MAIN_DOMAIN=$(get_main_domain "$DOMAIN")
SUBDOMAIN_PREFIX=$(get_subdomain_prefix "$DOMAIN" "$MAIN_DOMAIN")

# 构造完整的 DNS 记录名
if [ "$SUBDOMAIN_PREFIX" == "@" ]; then
    FULL_RECORD_NAME="$RECORD"
else
    FULL_RECORD_NAME="$RECORD.$SUBDOMAIN_PREFIX"
fi

# 显示 DNS 验证信息
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

# 函数: 获取域名 ID
# 描述: 根据域名名称获取腾讯云 DNSPod 中的域名 ID
# 参数: $1 - 域名名称
# 返回: 域名 ID
get_domain_id() {
    local domain_name=$1
    local domain_id
    
    print_dns "查询域名 ID: $domain_name"
    
    # 查询域名列表获取域名 ID
    domain_id=$(tccli dnspod DescribeDomainList --cli-unfold-argument \
        --Domain "$domain_name" \
        --output json | jq -r '.DomainList[0].DomainId')
    
    # 检查域名 ID 是否有效
    if [ -z "$domain_id" ] || [ "$domain_id" == "null" ]; then
        print_error "无法获取域名 ID，请确保域名已添加到腾讯云 DNSPod"
        exit 1
    fi
    
    print_dns "域名 ID: $domain_id"
    echo "$domain_id"
}

# 函数: 获取记录 ID
# 描述: 根据域名 ID、记录名称、记录类型和记录值获取 DNS 记录 ID
# 参数: 
#   $1 - 域名 ID
#   $2 - 记录名称
#   $3 - 记录类型 (默认: TXT)
#   $4 - 记录值 (可选)
# 返回: 记录 ID，如果未找到则返回空
get_record_id() {
    local domain_id=$1
    local record_name=$2
    local record_type=${3:-"TXT"}
    local record_value=${4:-""}
    local record_id
    
    print_dns "查询记录 ID: $record_name"
    
    # 查询记录列表获取记录 ID
    if [ -n "$record_value" ]; then
        # 如果提供了记录值，按记录值过滤
        record_id=$(tccli dnspod DescribeRecordList --cli-unfold-argument \
            --Domain "$MAIN_DOMAIN" \
            --DomainId "$domain_id" \
            --Subdomain "$record_name" \
            --RecordType "$record_type" \
            --output json | jq -r --arg value "$record_value" '.RecordList[] | select(.Value == $value) | .RecordId')
    else
        # 否则获取第一个匹配的记录
        record_id=$(tccli dnspod DescribeRecordList --cli-unfold-argument \
            --Domain "$MAIN_DOMAIN" \
            --DomainId "$domain_id" \
            --Subdomain "$record_name" \
            --RecordType "$record_type" \
            --output json | jq -r '.RecordList[0].RecordId')
    fi
    
    # 检查记录 ID 是否有效
    if [ -z "$record_id" ] || [ "$record_id" == "null" ]; then
        print_warning "未找到记录 ID"
        return 1
    fi
    
    print_dns "记录 ID: $record_id"
    echo "$record_id"
}

# 执行 DNS 操作
if [ "$ACTION" == "add" ]; then
    # 获取域名 ID
    DOMAIN_ID=$(get_domain_id "$MAIN_DOMAIN")
    
    # 添加 DNS 记录
    print_dns "添加 DNS 记录..."
    
    # 创建 TXT 记录
    RESPONSE=$(tccli dnspod CreateRecord --cli-unfold-argument \
        --Domain "$MAIN_DOMAIN" \
        --DomainId "$DOMAIN_ID" \
        --SubDomain "$FULL_RECORD_NAME" \
        --RecordType "TXT" \
        --RecordLine "默认" \
        --Value "$VALUE" \
        --TTL 600 \
        --output json)
    
    # 检查响应是否成功
    RESULT_CODE=$(echo "$RESPONSE" | jq -r '.RequestId')
    
    if [ -z "$RESULT_CODE" ] || [ "$RESULT_CODE" == "null" ]; then
        print_error "添加 DNS 记录失败: $RESPONSE"
        exit 1
    fi
    
    print_success "DNS 记录添加成功"
    
    # 等待 DNS 传播
    print_info "等待 DNS 传播 (${DNS_PROPAGATION_SECONDS} 秒)..."
    sleep $DNS_PROPAGATION_SECONDS
elif [ "$ACTION" == "delete" ]; then
    # 获取域名 ID
    DOMAIN_ID=$(get_domain_id "$MAIN_DOMAIN")
    
    # 查找记录 ID
    RECORD_ID=$(get_record_id "$DOMAIN_ID" "$FULL_RECORD_NAME" "TXT" "$VALUE")
    
    if [ -n "$RECORD_ID" ]; then
        # 删除记录
        print_dns "删除记录 ID: $RECORD_ID"
        
        RESPONSE=$(tccli dnspod DeleteRecord --cli-unfold-argument \
            --Domain "$MAIN_DOMAIN" \
            --DomainId "$DOMAIN_ID" \
            --RecordId "$RECORD_ID" \
            --output json)
        
        # 检查响应是否成功
        RESULT_CODE=$(echo "$RESPONSE" | jq -r '.RequestId')
        
        if [ -z "$RESULT_CODE" ] || [ "$RESULT_CODE" == "null" ]; then
            print_error "删除 DNS 记录失败: $RESPONSE"
            exit 1
        fi
        
        print_success "DNS 记录删除成功"
    else
        print_warning "未找到记录，无需删除"
    fi
fi

print_success "腾讯云 DNS 操作成功完成"
exit 0 