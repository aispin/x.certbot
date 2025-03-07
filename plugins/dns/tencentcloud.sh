#!/bin/bash

# This script is used by certbot for DNS-01 challenge with Tencent Cloud DNS
# It can be used as both auth and cleanup hook

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

# Get domain ID
get_domain_id() {
    local domain=$1
    local timestamp=$(date +%s)
    local nonce=$RANDOM
    local endpoint="dnspod.tencentcloudapi.com"
    local method="POST"
    local path="/"
    local req_body="{\"Domain\":\"$domain\"}"
    
    # Create payload for signing
    local payload="DescribeDomainRequest=$req_body"
    
    # Use tencent cloud CLI or API library to get domain ID
    # For this example, we'll use curl with the Tencent Cloud API
    result=$(curl -s -X POST "https://$endpoint" \
        -H "Authorization: TC3-HMAC-SHA256 Credential=$TENCENTCLOUD_SECRET_ID/$timestamp, SignedHeaders=content-type;host, Signature=xxx" \
        -H "Content-Type: application/json" \
        -H "Host: $endpoint" \
        -d "{\"Domain\":\"$domain\"}")
    
    # Parse result to get domain ID
    domain_id=$(echo "$result" | jq -r '.Response.DomainInfo.Id')
    echo $domain_id
}

# Perform the DNS operation
if [ "$ACTION" == "add" ]; then
    # Add DNS record
    echo "Adding DNS record using Tencent Cloud API..."
    
    # Get domain ID
    domain_id=$(get_domain_id "$MAIN_DOMAIN")
    if [ -z "$domain_id" ] || [ "$domain_id" == "null" ]; then
        echo "Error: Could not retrieve domain ID for $MAIN_DOMAIN"
        exit 1
    fi
    
    # Add TXT record
    result=$(curl -s -X POST "https://dnspod.tencentcloudapi.com" \
        -H "Authorization: TC3-HMAC-SHA256 Credential=$TENCENTCLOUD_SECRET_ID/$(date +%Y-%m-%d)/dnspod/tc3_request, SignedHeaders=content-type;host, Signature=xxx" \
        -H "Content-Type: application/json" \
        -H "Host: dnspod.tencentcloudapi.com" \
        -d "{
            \"Domain\": \"$MAIN_DOMAIN\",
            \"DomainId\": $domain_id,
            \"SubDomain\": \"$FULL_RECORD_NAME\",
            \"RecordType\": \"TXT\",
            \"RecordLine\": \"默认\",
            \"Value\": \"$VALUE\",
            \"TTL\": 600
        }")
    
    # Check for errors in response
    error=$(echo "$result" | jq -r '.Response.Error')
    if [ "$error" != "null" ]; then
        echo "Error adding DNS record: $error"
        exit 1
    fi
    
    echo "TXT record added successfully"
    
    # Wait for DNS propagation
    echo "Waiting for DNS propagation (${DNS_PROPAGATION_SECONDS} seconds)..."
    sleep $DNS_PROPAGATION_SECONDS
    
elif [ "$ACTION" == "delete" ]; then
    # Find the record ID
    echo "Finding record ID using Tencent Cloud API..."
    
    # Get domain ID
    domain_id=$(get_domain_id "$MAIN_DOMAIN")
    if [ -z "$domain_id" ] || [ "$domain_id" == "null" ]; then
        echo "Error: Could not retrieve domain ID for $MAIN_DOMAIN"
        exit 1
    fi
    
    # Get record list
    result=$(curl -s -X POST "https://dnspod.tencentcloudapi.com" \
        -H "Authorization: TC3-HMAC-SHA256 Credential=$TENCENTCLOUD_SECRET_ID/$(date +%Y-%m-%d)/dnspod/tc3_request, SignedHeaders=content-type;host, Signature=xxx" \
        -H "Content-Type: application/json" \
        -H "Host: dnspod.tencentcloudapi.com" \
        -d "{
            \"Domain\": \"$MAIN_DOMAIN\",
            \"DomainId\": $domain_id,
            \"Subdomain\": \"$FULL_RECORD_NAME\",
            \"RecordType\": \"TXT\"
        }")
    
    # Parse result to get record ID
    record_id=$(echo "$result" | jq -r ".Response.RecordList[] | select(.Value==\"$VALUE\") | .RecordId")
    
    if [ -n "$record_id" ] && [ "$record_id" != "null" ]; then
        # Delete the record
        echo "Deleting record ID: $record_id"
        delete_result=$(curl -s -X POST "https://dnspod.tencentcloudapi.com" \
            -H "Authorization: TC3-HMAC-SHA256 Credential=$TENCENTCLOUD_SECRET_ID/$(date +%Y-%m-%d)/dnspod/tc3_request, SignedHeaders=content-type;host, Signature=xxx" \
            -H "Content-Type: application/json" \
            -H "Host: dnspod.tencentcloudapi.com" \
            -d "{
                \"Domain\": \"$MAIN_DOMAIN\",
                \"DomainId\": $domain_id,
                \"RecordId\": $record_id
            }")
        
        # Check for errors in response
        error=$(echo "$delete_result" | jq -r '.Response.Error')
        if [ "$error" != "null" ]; then
            echo "Error deleting DNS record: $error"
            exit 1
        fi
        
        echo "TXT record deleted successfully"
    else
        echo "Record not found, nothing to delete"
    fi
fi

echo "Tencent Cloud DNS operation completed successfully"
exit 0 