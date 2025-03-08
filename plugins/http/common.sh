#!/bin/bash

# This script is used by certbot for HTTP-01 challenge
# It can be used as both auth and cleanup hook

# 加载控制台工具
if [ -f "/usr/local/bin/scripts/console_utils.sh" ]; then
    source "/usr/local/bin/scripts/console_utils.sh"
fi

# Set default values
DOMAIN=""
VALUE=""
ACTION="add"
WEBROOT_PATH=${WEBROOT_PATH:-"/var/www/html"}
WELL_KNOWN_PATH="/.well-known/acme-challenge"

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
    print_error "CERTBOT_DOMAIN 和 CERTBOT_VALIDATION 环境变量必须设置。"
    exit 1
fi

# Check if WEBROOT_PATH is accessible
if [ ! -d "$WEBROOT_PATH" ]; then
    print_error "WEBROOT_PATH 目录 ($WEBROOT_PATH) 不存在或无法访问。"
    print_error "请确保该目录存在并已挂载到容器中。"
    exit 1
fi

# Create challenge directory if it doesn't exist
CHALLENGE_DIR="$WEBROOT_PATH$WELL_KNOWN_PATH"
if [ ! -d "$CHALLENGE_DIR" ]; then
    print_info "创建验证目录: $CHALLENGE_DIR"
    mkdir -p "$CHALLENGE_DIR"
    
    if [ $? -ne 0 ]; then
        print_error "创建验证目录失败: $CHALLENGE_DIR"
        exit 1
    fi
fi

# Full path to the challenge file
CHALLENGE_FILE="$CHALLENGE_DIR/$VALUE"

print_subheader "HTTP 验证信息"
print_key_value "域名" "$DOMAIN"
print_key_value "验证文件" "$CHALLENGE_FILE"
print_key_value "验证值" "$VALUE"
print_key_value "操作" "$ACTION"

# Perform the HTTP challenge operation
if [ "$ACTION" == "add" ]; then
    # Add challenge file
    print_http "添加 HTTP 验证文件..."
    echo "$VALUE" > "$CHALLENGE_FILE"
    
    if [ $? -ne 0 ]; then
        print_error "创建验证文件失败: $CHALLENGE_FILE"
        exit 1
    fi
    
    # Set appropriate permissions
    chmod 644 "$CHALLENGE_FILE"
    
    print_success "HTTP 验证文件创建成功"
    print_info "文件内容: $(cat $CHALLENGE_FILE)"
    
    # For debugging - list content of challenge directory
    if [ "$DEBUG" = "true" ]; then
        print_debug "验证目录内容:"
        ls -la "$CHALLENGE_DIR"
    fi
    
elif [ "$ACTION" == "delete" ]; then
    # Remove challenge file
    print_http "删除 HTTP 验证文件..."
    if [ -f "$CHALLENGE_FILE" ]; then
        rm -f "$CHALLENGE_FILE"
        
        if [ $? -ne 0 ]; then
            print_error "删除验证文件失败: $CHALLENGE_FILE"
            exit 1
        fi
        
        print_success "HTTP 验证文件删除成功"
    else
        print_warning "验证文件未找到，无需删除"
    fi
fi

print_success "HTTP 验证操作成功完成"
exit 0 