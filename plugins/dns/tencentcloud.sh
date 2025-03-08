#!/bin/bash

# This script is used by certbot for DNS-01 challenge with Tencent Cloud DNS
# It can be used as both auth and cleanup hook

# ================================
# 腾讯云 DNS 插件
# 参考文档：
# 命令行工具：https://github.com/TencentCloud/tencentcloud-cli
# 创建 DNS 记录：https://cloud.tencent.com/document/product/1427/56180
# 删除 DNS 记录：https://cloud.tencent.com/document/product/1427/56168
# ================================

# Activate the virtual environment
source /opt/venv/bin/activate

# Source the helper functions
if [ -f "$(dirname "$0")/helper.sh" ]; then
    source "$(dirname "$0")/helper.sh"
else
    echo "Warning: helper.sh not found, using built-in functions"
fi

# Set default values
DOMAIN=""
RECORD="_acme-challenge"
VALUE=""
ACTION="add"
# Default DNS propagation wait time (in seconds)
DNS_PROPAGATION_SECONDS=${DNS_PROPAGATION_SECONDS:-60}

# Parse command line arguments
if [ "$1" == "clean" ]; then
    ACTION="delete"
    shift
fi

# Get domain and validation from environment variables
if [ -n "$CERTBOT_DOMAIN" ]; then
    DOMAIN="$CERTBOT_DOMAIN"
fi

if [ -n "$CERTBOT_VALIDATION" ]; then
    VALUE="$CERTBOT_VALIDATION"
fi

# Check if required variables are set
if [ -z "$DOMAIN" ] || [ -z "$VALUE" ]; then
    echo "Error: CERTBOT_DOMAIN and CERTBOT_VALIDATION environment variables must be set."
    exit 1
fi

if [ -z "$TENCENTCLOUD_SECRET_ID" ] || [ -z "$TENCENTCLOUD_SECRET_KEY" ]; then
    echo "Error: TENCENTCLOUD_SECRET_ID and TENCENTCLOUD_SECRET_KEY environment variables must be set."
    exit 1
fi

# Export Tencent Cloud credentials for tccli
export TENCENTCLOUD_SECRET_ID
export TENCENTCLOUD_SECRET_KEY
export TENCENTCLOUD_REGION=${TENCENTCLOUD_REGION:-"ap-guangzhou"}

# Configure tccli if not already configured
# This is a non-interactive way to configure tccli
echo "Configuring Tencent Cloud CLI..."
tccli configure set secretId "$TENCENTCLOUD_SECRET_ID" 2>/dev/null
tccli configure set secretKey "$TENCENTCLOUD_SECRET_KEY" 2>/dev/null
tccli configure set region "$TENCENTCLOUD_REGION" 2>/dev/null
tccli configure set output "json" 2>/dev/null

# Use helper functions if available, otherwise use built-in functions
if ! type get_main_domain >/dev/null 2>&1; then
    # Function to extract the main domain from a subdomain
    get_main_domain() {
        local domain=$1
        
        # Handle special Chinese TLDs like .com.cn, .net.cn, etc.
        if [[ "$domain" =~ .*\.(com|net|org|gov|edu)\.(cn|hk|tw)$ ]]; then
            echo "$domain" | grep -o '[^.]*\.[^.]*\.[^.]*$'
        else
            echo "$domain" | grep -o '[^.]*\.[^.]*$'
        fi
    }
fi

if ! type get_subdomain_prefix >/dev/null 2>&1; then
    # Function to get the subdomain prefix
    get_subdomain_prefix() {
        local domain=$1
        local main_domain=$2
        
        if [ "$domain" == "$main_domain" ]; then
            echo "@"
        else
            echo "${domain%.$main_domain}"
        fi
    }
fi

# Main domain extraction
MAIN_DOMAIN=$(get_main_domain "$DOMAIN")
SUBDOMAIN_PREFIX=$(get_subdomain_prefix "$DOMAIN" "$MAIN_DOMAIN")

# Construct the full record name
if [ "$SUBDOMAIN_PREFIX" == "@" ]; then
    FULL_RECORD_NAME="$RECORD"
else
    FULL_RECORD_NAME="$RECORD.$SUBDOMAIN_PREFIX"
fi

echo "Domain: $DOMAIN"
echo "Main domain: $MAIN_DOMAIN"
echo "Subdomain prefix: $SUBDOMAIN_PREFIX"
echo "Record: $FULL_RECORD_NAME"
echo "Value: $VALUE"
echo "Action: $ACTION"

# Function to get domain ID
get_domain_id() {
    local domain=$1
    
    # Use tccli to get domain information
    echo "Getting domain information for $domain..."
    result=$(tccli dnspod DescribeDomain --Domain "$domain" 2>/dev/null)
    
    # Check if command was successful
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get domain information for $domain"
        echo "Command output: $result"
        return 1
    fi
    
    # Extract domain ID
    domain_id=$(echo "$result" | jq -r '.DomainInfo.Id')
    
    if [ -z "$domain_id" ] || [ "$domain_id" == "null" ]; then
        echo "Error: Could not retrieve domain ID for $domain"
        echo "API response: $result"
        return 1
    fi
    
    echo "Domain ID for $domain: $domain_id"
    echo "$domain_id"
}

# Perform the DNS operation
if [ "$ACTION" == "add" ]; then
    # Add DNS record
    echo "Adding DNS TXT record using Tencent Cloud CLI..."
    
    # Get domain ID
    domain_id=$(get_domain_id "$MAIN_DOMAIN")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    # Add TXT record using tccli
    echo "Creating TXT record for $FULL_RECORD_NAME..."
    result=$(tccli dnspod CreateRecord --Domain "$MAIN_DOMAIN" --DomainId "$domain_id" --SubDomain "$FULL_RECORD_NAME" --RecordType "TXT" --RecordLine "默认" --Value "$VALUE" --TTL 600 2>/dev/null)
    
    # Check if command was successful
    if [ $? -ne 0 ]; then
        echo "Error: Failed to add TXT record"
        echo "Command output: $result"
        exit 1
    fi
    
    # Extract record ID for reference
    record_id=$(echo "$result" | jq -r '.RecordId')
    echo "TXT record added successfully with ID: $record_id"
    
    # Store record ID for cleanup (optional)
    if [ -n "$CERTBOT_TOKEN" ]; then
        mkdir -p /tmp/CERTBOT_$CERTBOT_TOKEN
        echo "$record_id" > /tmp/CERTBOT_$CERTBOT_TOKEN/RECORD_ID
    fi
    
    # 计算验证尝试次数和等待时间
    if type calculate_verification_timing >/dev/null 2>&1; then
        read -r VERIFY_ATTEMPTS VERIFY_WAIT_TIME REMAINING_WAIT_TIME <<< $(calculate_verification_timing $DNS_PROPAGATION_SECONDS 3)
        echo "验证配置: $VERIFY_ATTEMPTS 次尝试, 每次等待 $VERIFY_WAIT_TIME 秒, 剩余等待 $REMAINING_WAIT_TIME 秒"
    else
        VERIFY_ATTEMPTS=3
        VERIFY_WAIT_TIME=$((DNS_PROPAGATION_SECONDS / 4))
        REMAINING_WAIT_TIME=$((DNS_PROPAGATION_SECONDS - VERIFY_ATTEMPTS * VERIFY_WAIT_TIME))
    fi
    
    # 验证 DNS 记录
    if type verify_dns_record >/dev/null 2>&1; then
        verify_dns_record "$DOMAIN" "$VALUE" $VERIFY_ATTEMPTS $VERIFY_WAIT_TIME
        VERIFY_RESULT=$?
        
        if [ $VERIFY_RESULT -eq 0 ]; then
            echo "DNS 验证成功，继续处理..."
        else
            echo "DNS 验证未成功，但将继续等待剩余时间..."
            # 即使验证失败，也等待剩余时间，让 Certbot 有机会验证
            if [ $REMAINING_WAIT_TIME -gt 0 ]; then
                echo "等待剩余 $REMAINING_WAIT_TIME 秒..."
                sleep $REMAINING_WAIT_TIME
            fi
        fi
    else
        # 如果没有验证函数，则使用原来的等待逻辑
        echo "Waiting for DNS propagation (${DNS_PROPAGATION_SECONDS} seconds)..."
        sleep $DNS_PROPAGATION_SECONDS
    fi
    
elif [ "$ACTION" == "delete" ]; then
    echo "Deleting DNS TXT record using Tencent Cloud CLI..."
    
    # Get domain ID
    domain_id=$(get_domain_id "$MAIN_DOMAIN")
    if [ $? -ne 0 ]; then
        exit 1
    fi
    
    # Try to get record ID from temp file if available
    record_id=""
    if [ -n "$CERTBOT_TOKEN" ] && [ -f "/tmp/CERTBOT_$CERTBOT_TOKEN/RECORD_ID" ]; then
        record_id=$(cat "/tmp/CERTBOT_$CERTBOT_TOKEN/RECORD_ID")
        echo "Found stored record ID: $record_id"
    fi
    
    if [ -z "$record_id" ]; then
        # Find the record ID by listing records and filtering
        echo "Searching for TXT record..."
        result=$(tccli dnspod DescribeRecordList --Domain "$MAIN_DOMAIN" --DomainId "$domain_id" --Subdomain "$FULL_RECORD_NAME" --RecordType "TXT" 2>/dev/null)
        
        # Check if command was successful
        if [ $? -ne 0 ]; then
            echo "Error: Failed to list DNS records"
            echo "Command output: $result"
            exit 1
        fi
        
        # Find record with matching value
        record_id=$(echo "$result" | jq -r ".RecordList[] | select(.Value==\"$VALUE\") | .RecordId")
    fi
    
    if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        # Delete the record using tccli
        echo "Deleting record ID: $record_id"
        delete_result=$(tccli dnspod DeleteRecord --Domain "$MAIN_DOMAIN" --DomainId "$domain_id" --RecordId "$record_id" 2>/dev/null)
        
        # Check if command was successful
        if [ $? -ne 0 ]; then
            echo "Error: Failed to delete TXT record"
            echo "Command output: $delete_result"
            exit 1
        fi
        
        echo "TXT record deleted successfully"
        
        # Clean up temp file if it exists
        if [ -n "$CERTBOT_TOKEN" ] && [ -d "/tmp/CERTBOT_$CERTBOT_TOKEN" ]; then
            rm -rf "/tmp/CERTBOT_$CERTBOT_TOKEN"
        fi
    else
        echo "Record not found, nothing to delete"
    fi
fi

echo "Tencent Cloud DNS operation completed successfully"
exit 0 