#!/bin/bash

# Load environment variables from .env file if it exists
if [ -f "/.env" ]; then
    echo "Loading environment variables from /.env file"
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        [[ $key =~ ^#.*$ ]] || [ -z "$key" ] && continue
        # Remove leading/trailing whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        # Only set if not already set from command line
        if [ -z "${!key}" ]; then
            export "$key"="$value"
            echo "Set $key from .env file"
        else
            echo "$key already set, using existing value"
        fi
    done < /.env
fi

# Activate the virtual environment
source /opt/venv/bin/activate

# Check required environment variables
if [ -z "$DOMAINS" ] || [ -z "$EMAIL" ]; then
    echo "Error: Missing required environment variables. Please set: DOMAINS, EMAIL"
    exit 1
fi

# Set default values
CHALLENGE_TYPE=${CHALLENGE_TYPE:-"dns"}
CLOUD_PROVIDER=${CLOUD_PROVIDER:-"aliyun"}
DNS_PROPAGATION_SECONDS=${DNS_PROPAGATION_SECONDS:-60}

# Define hooks based on provider and challenge type
if [ -z "$AUTH_HOOK" ]; then
    if [ "$CHALLENGE_TYPE" == "dns" ]; then
        AUTH_HOOK="/usr/local/bin/plugins/dns/${CLOUD_PROVIDER}.sh"
    elif [ "$CHALLENGE_TYPE" == "http" ]; then
        AUTH_HOOK="/usr/local/bin/plugins/http/${CLOUD_PROVIDER}.sh"
    else
        echo "Error: Unsupported challenge type: $CHALLENGE_TYPE. Supported types: dns, http"
        exit 1
    fi
fi

if [ -z "$CLEANUP_HOOK" ]; then
    if [ "$CHALLENGE_TYPE" == "dns" ]; then
        CLEANUP_HOOK="/usr/local/bin/plugins/dns/${CLOUD_PROVIDER}.sh clean"
    elif [ "$CHALLENGE_TYPE" == "http" ]; then
        CLEANUP_HOOK="/usr/local/bin/plugins/http/${CLOUD_PROVIDER}.sh clean"
    fi
fi

DEPLOY_HOOK=${DEPLOY_HOOK:-"/usr/local/bin/scripts/deploy-hook.sh"}

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
        echo "Error: $hook_type hook not found at $hook_path"
        exit 1
    fi
    
    if [ ! -x "$hook_path" ]; then
        echo "Error: $hook_type hook at $hook_path is not executable"
        chmod +x "$hook_path"
        echo "Made $hook_type hook executable"
    fi
}

# Configure cloud provider if needed
configure_provider() {
    if [ "$CLOUD_PROVIDER" == "aliyun" ]; then
        if [ -z "$ALIYUN_REGION" ] || [ -z "$ALIYUN_ACCESS_KEY_ID" ] || [ -z "$ALIYUN_ACCESS_KEY_SECRET" ]; then
            echo "Error: For Aliyun provider, please set: ALIYUN_REGION, ALIYUN_ACCESS_KEY_ID, ALIYUN_ACCESS_KEY_SECRET"
            exit 1
        fi
        
        # Configure Aliyun CLI
        aliyun configure set --profile akProfile --mode AK --region $ALIYUN_REGION --access-key-id $ALIYUN_ACCESS_KEY_ID --access-key-secret $ALIYUN_ACCESS_KEY_SECRET
    elif [ "$CLOUD_PROVIDER" == "tencentcloud" ]; then
        if [ -z "$TENCENTCLOUD_SECRET_ID" ] || [ -z "$TENCENTCLOUD_SECRET_KEY" ]; then
            echo "Error: For TencentCloud provider, please set: TENCENTCLOUD_SECRET_ID, TENCENTCLOUD_SECRET_KEY"
            exit 1
        fi
        
        # Environment variables will be used by the Tencent Cloud plugin
        export TENCENTCLOUD_SECRET_ID=$TENCENTCLOUD_SECRET_ID
        export TENCENTCLOUD_SECRET_KEY=$TENCENTCLOUD_SECRET_KEY
    fi
    
    # Additional providers can be added here
}

# Function to parse domains and build certbot command
process_domains() {
    local domains_array
    # Parse comma-separated list of domains
    IFS=',' read -ra domains_array <<< "$DOMAINS"

    local domain_params=""
    for domain in "${domains_array[@]}"; do
        # Trim whitespace
        domain=$(echo "$domain" | xargs)
        # Add the primary domain
        domain_params="$domain_params -d $domain"
        
        # Check if this is a top-level domain and if wildcards are enabled
        if [[ "$ENABLE_WILDCARDS" == "true" && $(echo "$domain" | grep -o "\." | wc -l) -eq 1 ]]; then
            # If it's a top-level domain and wildcards are enabled, add wildcard
            domain_params="$domain_params -d *.$domain"
            echo "Adding wildcard for top-level domain: *.$domain"
        fi
    done
    
    echo $domain_params
}

# Execute hook check
check_hook "$AUTH_HOOK" "Auth"
check_hook "$CLEANUP_HOOK" "Cleanup" "clean"
check_hook "$DEPLOY_HOOK" "Deploy"

# Configure the selected cloud provider
configure_provider

# Main execution
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

# Get domain parameters
DOMAIN_PARAMS=$(process_domains)

# Obtain the certificates for all domains
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

# Start cron daemon if CRON_ENABLED is true
if [ "$CRON_ENABLED" == "true" ]; then
    echo "$CRON_SCHEDULE /usr/local/bin/entrypoint.sh renew" > /etc/crontabs/root
    echo "Starting cron daemon with schedule: $CRON_SCHEDULE"
    crond -f -l 2
else
    echo "Cron daemon not started (CRON_ENABLED != true)"
    # Keep container running if KEEP_RUNNING is true
    if [ "$KEEP_RUNNING" == "true" ]; then
        echo "Container will keep running (KEEP_RUNNING=true)"
        tail -f /dev/null
    fi
fi
