#!/bin/bash

# 证书部署钩子脚本
# 用途: 在证书成功续期后由 Certbot 调用，处理证书部署和后续操作
# 功能: 
#   1. 复制更新的证书文件到指定目录
#   2. 设置适当的文件权限
#   3. 可选创建元数据文件
#   4. 执行自定义后续脚本
#   5. 发送 Webhook 通知
#   6. 支持中文域名：将 punycode 编码的目录名解码为中文域名
# 环境变量:
#   RENEWED_LINEAGE - 续期证书的路径 (由 Certbot 提供)
#   CERT_OUTPUT_DIR - 证书输出目录 (默认: /etc/letsencrypt/certs/live)
#   CREATE_DOMAIN_DIRS - 是否为每个域名创建单独的目录 (true/false)
#   CERT_FILE_PERMISSIONS - 证书文件权限 (默认: 644)
#   CREATE_METADATA - 是否创建元数据文件 (true/false)
#   POST_RENEWAL_SCRIPT - 自定义更新后脚本路径
#   WEBHOOK_URL - Webhook 通知 URL

# 加载控制台工具 (用于美化输出和日志记录)
if [ -f "/usr/local/bin/scripts/console_utils.sh" ]; then
    source "/usr/local/bin/scripts/console_utils.sh"
fi

# 加载域名处理工具 (用于 punycode 解码)
if [ -f "/usr/local/bin/scripts/domain_utils.sh" ]; then
    source "/usr/local/bin/scripts/domain_utils.sh"
    [ "$DEBUG" = "true" ] && print_debug "已加载 domain_utils.sh"
fi

print_deploy "证书更新成功: $RENEWED_LINEAGE"

# 证书目标目录 (可通过 CERT_OUTPUT_DIR 环境变量覆盖)
# 这是存储证书文件的基础目录
CERT_OUTPUT_DIR=${CERT_OUTPUT_DIR:-"/etc/letsencrypt/certs/live"}

# 创建目标目录 (如果不存在)
mkdir -p "$CERT_OUTPUT_DIR"

# 从证书中获取域名 (用于域名特定目录，如果需要)
# 如果 CREATE_DOMAIN_DIRS=true，则为每个域名创建单独的目录
if [ "$CREATE_DOMAIN_DIRS" == "true" ]; then
    # 从证书目录名称提取域名
    PUNYCODE_DOMAIN=$(basename "$RENEWED_LINEAGE")
    
    # 解码 punycode 域名为中文域名（如果 domain_utils.sh 可用）
    if command -v decode_punycode_domain >/dev/null 2>&1; then
        DECODED_DOMAIN=$(decode_punycode_domain "$PUNYCODE_DOMAIN")
        if [ "$PUNYCODE_DOMAIN" != "$DECODED_DOMAIN" ]; then
            print_info "检测到 punycode 编码域名: $PUNYCODE_DOMAIN"
            print_info "解码为中文域名: $DECODED_DOMAIN"
            DOMAIN="$DECODED_DOMAIN"
        else
            DOMAIN="$PUNYCODE_DOMAIN"
        fi
    else
        # 如果域名处理工具不可用，使用原始域名
        DOMAIN="$PUNYCODE_DOMAIN"
        print_warning "域名处理工具不可用，使用原始域名: $DOMAIN"
    fi
    
    DOMAIN_DIR="$CERT_OUTPUT_DIR/$DOMAIN"
    mkdir -p "$DOMAIN_DIR"
    OUTPUT_DIR="$DOMAIN_DIR"
    print_info "将证书存储在域名特定目录: $OUTPUT_DIR"
else
    # 否则使用公共目录
    OUTPUT_DIR="$CERT_OUTPUT_DIR"
    print_info "将证书存储在公共目录: $OUTPUT_DIR"
fi

# 证书文件名称 (可通过环境变量自定义)
# 这些是输出文件的名称，可以根据需要修改
FULLCHAIN_NAME=${FULLCHAIN_NAME:-"fullchain.pem"}  # 完整证书链 (证书+中间证书)
PRIVKEY_NAME=${PRIVKEY_NAME:-"privkey.pem"}        # 私钥
CERT_NAME=${CERT_NAME:-"cert.pem"}                 # 证书
CHAIN_NAME=${CHAIN_NAME:-"chain.pem"}              # 证书链 (中间证书)

# 复制所有证书文件到输出目录
# 使用 -L 参数跟随符号链接，确保复制实际文件而不是链接
print_deploy "从 $RENEWED_LINEAGE 复制证书到 $OUTPUT_DIR"
cp -L "$RENEWED_LINEAGE/fullchain.pem" "$OUTPUT_DIR/$FULLCHAIN_NAME"
cp -L "$RENEWED_LINEAGE/privkey.pem" "$OUTPUT_DIR/$PRIVKEY_NAME"
cp -L "$RENEWED_LINEAGE/cert.pem" "$OUTPUT_DIR/$CERT_NAME"
cp -L "$RENEWED_LINEAGE/chain.pem" "$OUTPUT_DIR/$CHAIN_NAME"

# 设置适当的文件权限
# 默认为 644 (所有者可读写，组和其他用户只读)
chmod ${CERT_FILE_PERMISSIONS:-644} "$OUTPUT_DIR"/*.pem
print_success "已设置证书文件权限: ${CERT_FILE_PERMISSIONS:-644}"

# 创建元数据文件 (如果配置了 CREATE_METADATA=true)
# 元数据文件包含证书的详细信息，如主题、颁发者、有效期等
if [ "$CREATE_METADATA" == "true" ]; then
    METADATA_FILE="$OUTPUT_DIR/metadata.json"
    print_info "创建元数据文件: $METADATA_FILE"
    
    # 从证书中提取信息
    # 使用 openssl 命令获取证书的详细信息
    CERT_SUBJECT=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -subject)
    CERT_ISSUER=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -issuer)
    CERT_DATES=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -dates)
    CERT_FINGERPRINT=$(openssl x509 -in "$RENEWED_LINEAGE/cert.pem" -noout -fingerprint)
    
    # 创建 JSON 格式的元数据
    # 包含域名、更新时间、证书信息和文件路径
    cat > "$METADATA_FILE" <<EOL
{
  "domain": "$DOMAIN",
  "punycode_domain": "$PUNYCODE_DOMAIN",
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
    # 设置元数据文件权限
    chmod ${CERT_FILE_PERMISSIONS:-644} "$METADATA_FILE"
    print_success "元数据文件创建成功"
fi

# 执行更新后脚本 (如果配置了)
# 首先检查自定义脚本路径
if [ -n "$POST_RENEWAL_SCRIPT" ] && [ -f "$POST_RENEWAL_SCRIPT" ] && [ -x "$POST_RENEWAL_SCRIPT" ]; then
    # 执行自定义脚本
    print_deploy "执行自定义更新后脚本: $POST_RENEWAL_SCRIPT"
    
    # 将证书详细信息作为环境变量传递给脚本
    # 这些变量可以在脚本中使用，例如重启 Web 服务器或分发证书
    RENEWED_DOMAIN="$DOMAIN" \
    RENEWED_PUNYCODE_DOMAIN="$PUNYCODE_DOMAIN" \
    RENEWED_FULLCHAIN="$OUTPUT_DIR/$FULLCHAIN_NAME" \
    RENEWED_PRIVKEY="$OUTPUT_DIR/$PRIVKEY_NAME" \
    RENEWED_CERT="$OUTPUT_DIR/$CERT_NAME" \
    RENEWED_CHAIN="$OUTPUT_DIR/$CHAIN_NAME" \
    "$POST_RENEWAL_SCRIPT"
    
    # 检查脚本执行结果
    if [ $? -eq 0 ]; then
        print_success "自定义更新后脚本执行成功"
    else
        print_warning "自定义更新后脚本执行失败，退出代码: $?"
    fi
# 如果没有自定义脚本，则尝试使用默认位置的脚本
elif [ -f "/host-scripts/post-renewal.sh" ] && [ -x "/host-scripts/post-renewal.sh" ]; then
    # 执行宿主机脚本
    print_deploy "执行宿主机更新后脚本..."
    
    # 将证书详细信息作为环境变量传递给脚本
    RENEWED_DOMAIN="$DOMAIN" \
    RENEWED_PUNYCODE_DOMAIN="$PUNYCODE_DOMAIN" \
    RENEWED_FULLCHAIN="$OUTPUT_DIR/$FULLCHAIN_NAME" \
    RENEWED_PRIVKEY="$OUTPUT_DIR/$PRIVKEY_NAME" \
    RENEWED_CERT="$OUTPUT_DIR/$CERT_NAME" \
    RENEWED_CHAIN="$OUTPUT_DIR/$CHAIN_NAME" \
    /host-scripts/post-renewal.sh
    
    # 检查脚本执行结果
    if [ $? -eq 0 ]; then
        print_success "宿主机更新后脚本执行成功"
    else
        print_warning "宿主机更新后脚本执行失败，退出代码: $?"
    fi
else
    print_info "未找到可执行的更新后脚本"
fi

# 发送 Webhook 通知 (如果配置了 WEBHOOK_URL)
# Webhook 可用于通知外部系统证书已更新
if [ -n "$WEBHOOK_URL" ]; then
    print_info "发送 Webhook 通知到 $WEBHOOK_URL"
    
    # 准备 Webhook 数据
    # 包含域名、状态和时间戳
    WEBHOOK_DATA="{\"domain\":\"$DOMAIN\",\"punycode_domain\":\"$PUNYCODE_DOMAIN\",\"status\":\"success\",\"timestamp\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
    
    # 发送 Webhook 请求
    # 使用 curl 发送 POST 请求，内容类型为 application/json
    curl -s -X POST -H "Content-Type: application/json" -d "$WEBHOOK_DATA" "$WEBHOOK_URL"
    
    # 检查请求结果
    if [ $? -eq 0 ]; then
        print_success "Webhook 通知发送成功"
    else
        print_error "Webhook 通知发送失败"
    fi
fi

print_success "部署钩子执行完成"