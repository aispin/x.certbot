#!/bin/bash

# This script is used by certbot for DNS-01 challenge with Aliyun DNS
# It can be used as both auth and cleanup hook

# Activate the virtual environment
source /opt/venv/bin/activate

# Source the helper functions
if [ -f "$(dirname "$0")/helper.sh" ]; then
    source "$(dirname "$0")/helper.sh"
else
    echo "Warning: helper.sh not found, using built-in functions"
fi

# Set default values
PROFILE="akProfile"
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

# Perform the DNS operation
if [ "$ACTION" == "add" ]; then
    # Add DNS record
    echo "Adding DNS record using Aliyun API..."
    aliyun --profile "$PROFILE" alidns AddDomainRecord \
        --DomainName "$MAIN_DOMAIN" \
        --RR "$FULL_RECORD_NAME" \
        --Type "TXT" \
        --Value "$VALUE" \
        --TTL 600
    
    result=$?
    if [ $result -ne 0 ]; then
        echo "Error: Failed to add DNS record"
        exit 1
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
    # Find the record ID
    echo "Finding record ID using Aliyun API..."
    RECORD_ID=$(aliyun --profile "$PROFILE" alidns DescribeDomainRecords \
        --DomainName "$MAIN_DOMAIN" \
        --RRKeyWord "$FULL_RECORD_NAME" \
        --Type "TXT" \
        --ValueKeyWord "$VALUE" \
        | jq -r '.DomainRecords.Record[0].RecordId')
    
    if [ -n "$RECORD_ID" ] && [ "$RECORD_ID" != "null" ]; then
        # Delete the record
        echo "Deleting record ID: $RECORD_ID"
        aliyun --profile "$PROFILE" alidns DeleteDomainRecord \
            --RecordId "$RECORD_ID"
        
        if [ $? -ne 0 ]; then
            echo "Error: Failed to delete DNS record"
            exit 1
        fi
    else
        echo "Record not found, nothing to delete"
    fi
fi

echo "Aliyun DNS operation completed successfully"
exit 0 