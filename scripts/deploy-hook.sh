#!/bin/bash

# This script is called by certbot after successful certificate renewal
# $RENEWED_LINEAGE contains the path to the renewed certificate

# 加载控制台工具
if [ -f "/usr/local/bin/scripts/console_utils.sh" ]; then
    source "/usr/local/bin/scripts/console_utils.sh"
fi

print_deploy "证书更新成功: $RENEWED_LINEAGE"

# Certificate target directory (can be overridden via CERT_OUTPUT_DIR environment variable)
CERT_OUTPUT_DIR=${CERT_OUTPUT_DIR:-"/etc/letsencrypt/certs"}

# Create destination directory if it doesn't exist
mkdir -p "$CERT_OUTPUT_DIR"

# Get domain name from certificate (for domain-specific directories if needed)
if [ "$CREATE_DOMAIN_DIRS" == "true" ]; then
    # Extract domain from certificate directory name
    DOMAIN=$(basename "$RENEWED_LINEAGE")
    DOMAIN_DIR="$CERT_OUTPUT_DIR/$DOMAIN"
    mkdir -p "$DOMAIN_DIR"
    OUTPUT_DIR="$DOMAIN_DIR"
    print_info "将证书存储在域名特定目录: $OUTPUT_DIR"
else
    OUTPUT_DIR="$CERT_OUTPUT_DIR"
    print_info "将证书存储在公共目录: $OUTPUT_DIR"
fi

# Certificate file names (can be customized via environment variables)
FULLCHAIN_NAME=${FULLCHAIN_NAME:-"fullchain.pem"}
PRIVKEY_NAME=${PRIVKEY_NAME:-"privkey.pem"}
CERT_NAME=${CERT_NAME:-"cert.pem"}
CHAIN_NAME=${CHAIN_NAME:-"chain.pem"}

# Copy all certificate files to the output directory
print_deploy "从 $RENEWED_LINEAGE 复制证书到 $OUTPUT_DIR"
cp -L "$RENEWED_LINEAGE/fullchain.pem" "$OUTPUT_DIR/$FULLCHAIN_NAME"
cp -L "$RENEWED_LINEAGE/privkey.pem" "$OUTPUT_DIR/$PRIVKEY_NAME"
cp -L "$RENEWED_LINEAGE/cert.pem" "$OUTPUT_DIR/$CERT_NAME"
cp -L "$RENEWED_LINEAGE/chain.pem" "$OUTPUT_DIR/$CHAIN_NAME"

# Set proper permissions
chmod ${CERT_FILE_PERMISSIONS:-644} "$OUTPUT_DIR"/*.pem
print_success "已设置证书文件权限: ${CERT_FILE_PERMISSIONS:-644}"

# Create a metadata file with information about the certificate
if [ "$CREATE_METADATA" == "true" ]; then
    METADATA_FILE="$OUTPUT_DIR/metadata.json"
    print_info "创建元数据文件: $METADATA_FILE"
    
    # Extract information from certificate
    CERT_SUBJECT=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -subject)
    CERT_ISSUER=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -issuer)
    CERT_DATES=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -dates)
    CERT_FINGERPRINT=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -fingerprint)
    
    # Create JSON metadata
    cat > "$METADATA_FILE" <<EOL
{
  "domain": "$(basename "$RENEWED_LINEAGE")",
  "renewed_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "certificate": {
    "subject": "$CERT_SUBJECT",
    "issuer": "$CERT_ISSUER",
    "dates": "$CERT_DATES",
    "fingerprint": "$CERT_FINGERPRINT"
  },
  "files": {
    "fullchain": "$OUTPUT_DIR/$FULLCHAIN_NAME",
    "privkey": "$OUTPUT_DIR/$PRIVKEY_NAME",
    "cert": "$OUTPUT_DIR/$CERT_NAME",
    "chain": "$OUTPUT_DIR/$CHAIN_NAME"
  }
}
EOL
    chmod ${CERT_FILE_PERMISSIONS:-644} "$METADATA_FILE"
    print_success "元数据文件创建成功"
fi

# Execute host-side post-renewal script if configured
# Check custom script path first
if [ -n "$POST_RENEWAL_SCRIPT" ] && [ -f "$POST_RENEWAL_SCRIPT" ] && [ -x "$POST_RENEWAL_SCRIPT" ]; then
    print_deploy "执行自定义更新后脚本: $POST_RENEWAL_SCRIPT"
    
    # Pass certificate details to the script as environment variables
    RENEWED_DOMAIN=$(basename "$RENEWED_LINEAGE") \
    RENEWED_FULLCHAIN="$OUTPUT_DIR/$FULLCHAIN_NAME" \
    RENEWED_PRIVKEY="$OUTPUT_DIR/$PRIVKEY_NAME" \
    RENEWED_CERT="$OUTPUT_DIR/$CERT_NAME" \
    RENEWED_CHAIN="$OUTPUT_DIR/$CHAIN_NAME" \
    "$POST_RENEWAL_SCRIPT"
    
    if [ $? -eq 0 ]; then
        print_success "自定义更新后脚本执行成功"
    else
        print_warning "自定义更新后脚本执行失败，退出代码: $?"
    fi
# Fall back to default location
elif [ -f "/host-scripts/post-renewal.sh" ] && [ -x "/host-scripts/post-renewal.sh" ]; then
    print_deploy "执行宿主机更新后脚本..."
    
    # Pass certificate details to the script as environment variables
    RENEWED_DOMAIN=$(basename "$RENEWED_LINEAGE") \
    RENEWED_FULLCHAIN="$OUTPUT_DIR/$FULLCHAIN_NAME" \
    RENEWED_PRIVKEY="$OUTPUT_DIR/$PRIVKEY_NAME" \
    RENEWED_CERT="$OUTPUT_DIR/$CERT_NAME" \
    RENEWED_CHAIN="$OUTPUT_DIR/$CHAIN_NAME" \
    /host-scripts/post-renewal.sh
    
    if [ $? -eq 0 ]; then
        print_success "宿主机更新后脚本执行成功"
    else
        print_warning "宿主机更新后脚本执行失败，退出代码: $?"
    fi
else
    print_info "未找到可执行的更新后脚本"
fi

# Send webhook notification if configured
if [ -n "$WEBHOOK_URL" ]; then
    print_info "发送 Webhook 通知到 $WEBHOOK_URL"
    
    # Prepare webhook data
    WEBHOOK_DATA="{\"domain\":\"$(basename "$RENEWED_LINEAGE")\",\"status\":\"success\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
    
    # Send webhook request
    curl -s -X POST -H "Content-Type: application/json" -d "$WEBHOOK_DATA" "$WEBHOOK_URL"
    
    if [ $? -eq 0 ]; then
        print_success "Webhook 通知发送成功"
    else
        print_error "Webhook 通知发送失败"
    fi
fi

print_success "部署钩子执行完成"