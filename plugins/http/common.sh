#!/bin/bash

# HTTP 验证脚本 (通用实现)
# 用途: 用于 Let's Encrypt HTTP-01 验证挑战
# 功能: 
#   1. 添加 HTTP 验证文件 - 不带参数执行
#   2. 删除 HTTP 验证文件 - 带 clean 参数执行
# 环境变量:
#   CERTBOT_DOMAIN - 要验证的域名
#   CERTBOT_VALIDATION - 验证值
#   CERTBOT_TOKEN - 验证令牌 (由 Certbot 提供)
#   WEBROOT_PATH - Web 根目录路径 (默认: /var/www/html)
#   DEBUG - 设置为 true 启用调试输出

# 加载控制台工具 (用于美化输出和日志记录)
if [ -f "/usr/local/bin/scripts/console_utils.sh" ]; then
    source "/usr/local/bin/scripts/console_utils.sh"
fi

# 设置默认值
DOMAIN=""            # 要验证的域名
VALUE=""             # 验证值
ACTION="add"         # 默认操作: 添加验证文件
WEBROOT_PATH=${WEBROOT_PATH:-"/var/www/html"}  # Web 根目录路径
WELL_KNOWN_PATH="/.well-known/acme-challenge"  # ACME 挑战路径 (标准路径)

# 解析命令行参数
# 如果第一个参数是 "clean"，则设置操作为删除验证文件
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

# 检查 Web 根目录是否可访问
# 这是放置验证文件的基础目录
if [ ! -d "$WEBROOT_PATH" ]; then
    print_error "WEBROOT_PATH 目录 ($WEBROOT_PATH) 不存在或无法访问。"
    print_error "请确保该目录存在并已挂载到容器中。"
    exit 1
fi

# 创建验证目录 (如果不存在)
# Let's Encrypt 将在 /.well-known/acme-challenge/ 路径下查找验证文件
CHALLENGE_DIR="$WEBROOT_PATH$WELL_KNOWN_PATH"
if [ ! -d "$CHALLENGE_DIR" ]; then
    print_info "创建验证目录: $CHALLENGE_DIR"
    mkdir -p "$CHALLENGE_DIR"
    
    # 检查目录创建是否成功
    if [ $? -ne 0 ]; then
        print_error "创建验证目录失败: $CHALLENGE_DIR"
        exit 1
    fi
fi

# 验证文件的完整路径
# 文件名为验证值，内容也为验证值
CHALLENGE_FILE="$CHALLENGE_DIR/$VALUE"

# 显示 HTTP 验证信息
print_subheader "HTTP 验证信息"
print_key_value "域名" "$DOMAIN"
print_key_value "验证文件" "$CHALLENGE_FILE"
print_key_value "验证值" "$VALUE"
print_key_value "操作" "$ACTION"

# 执行 HTTP 验证操作
if [ "$ACTION" == "add" ]; then
    # 添加验证文件
    # Let's Encrypt 将通过 HTTP 请求 http://<域名>/.well-known/acme-challenge/<验证值> 
    # 并期望响应内容为验证值
    print_http "添加 HTTP 验证文件..."
    echo "$VALUE" > "$CHALLENGE_FILE"
    
    # 检查文件创建是否成功
    if [ $? -ne 0 ]; then
        print_error "创建验证文件失败: $CHALLENGE_FILE"
        exit 1
    fi
    
    # 设置适当的文件权限，确保 Web 服务器可以读取
    chmod 644 "$CHALLENGE_FILE"
    
    print_success "HTTP 验证文件创建成功"
    print_info "文件内容: $(cat $CHALLENGE_FILE)"
    
    # 调试信息 - 列出验证目录的内容
    if [ "$DEBUG" = "true" ]; then
        print_debug "验证目录内容:"
        ls -la "$CHALLENGE_DIR"
    fi
    
elif [ "$ACTION" == "delete" ]; then
    # 删除验证文件
    # 验证完成后清理文件，避免安全风险
    print_http "删除 HTTP 验证文件..."
    if [ -f "$CHALLENGE_FILE" ]; then
        rm -f "$CHALLENGE_FILE"
        
        # 检查文件删除是否成功
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