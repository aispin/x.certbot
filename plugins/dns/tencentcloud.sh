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
    result=$(tccli dnspod DescribeDomain --Domain "$domain" 2>/dev/null)
    
    # Check if command was successful
    if [ $? -ne 0 ]; then
        echo "Error: Failed to get domain information for $domain"
        return 1
    fi
    
    # Extract domain ID
    domain_id=$(echo "$result" | jq -r '.DomainInfo.Id')
    
    if [ -z "$domain_id" ] || [ "$domain_id" == "null" ]; then
        echo "Error: Could not retrieve domain ID for $domain"
        return 1
    fi
    
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
    result=$(tccli dnspod CreateRecord --Domain "$MAIN_DOMAIN" --DomainId "$domain_id" --SubDomain "$FULL_RECORD_NAME" --RecordType "TXT" --RecordLine "默认" --Value "$VALUE" --TTL 600 2>/dev/null)
    
    # Check if command was successful
    if [ $? -ne 0 ]; then
        echo "Error: Failed to add TXT record"
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
    
    # Wait for DNS propagation
    echo "Waiting for DNS propagation (${DNS_PROPAGATION_SECONDS} seconds)..."
    sleep $DNS_PROPAGATION_SECONDS
    
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
            exit 1
        fi
        
        # Find record with matching value
        record_id=$(echo "$result" | jq -r ".RecordList[] | select(.Value==\"$VALUE\") | .RecordId")
    fi
    
    if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        # Delete the record using tccli
        echo "Deleting record ID: $record_id"
        tccli dnspod DeleteRecord --Domain "$MAIN_DOMAIN" --DomainId "$domain_id" --RecordId "$record_id" >/dev/null 2>&1
        
        # Check if command was successful
        if [ $? -ne 0 ]; then
            echo "Error: Failed to delete TXT record"
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