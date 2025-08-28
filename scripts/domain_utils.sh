#!/bin/bash

# 域名处理工具脚本
# 用于处理中文域名的 punycode 编码和解码
# 提供统一的域名处理功能，供其他脚本使用

# Function: encode_punycode_domain
# 描述: 将域名编码为 punycode 格式（统一编码策略）
# 参数:
#   $1 - 域名（可能是中文域名或英文域名）
# 返回:
#   punycode 编码后的域名，如果编码失败则返回原域名
encode_punycode_domain() {
    local domain=$1
    
    # 统一进行 punycode 编码，无论是否包含中文
    # 对于英文域名，编码后结果不变
    local encoded_domain
    # 尝试不同的 idn2 参数格式（兼容不同系统）
    encoded_domain=$(idn2 "$domain" 2>/dev/null || idn2 -a "$domain" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$encoded_domain" ]; then
        echo "$encoded_domain"
    else
        # 编码失败，返回原域名
        echo "$domain"
    fi
}

# Function: process_domain_args
# 描述: 处理 DOMAIN_ARG 中的域名，将中文域名编码为 punycode
# 参数:
#   $1 - 原始的 DOMAIN_ARG 字符串
# 返回:
#   处理后的 DOMAIN_ARG 字符串，中文域名已编码为 punycode
process_domain_args() {
    local domain_args="$1"
    local processed_args=""
    
    # 使用更兼容的方法分割参数
    while IFS=' ' read -r -d ' ' arg || [ -n "$arg" ]; do
        if [[ "$arg" == "-d" ]]; then
            # 这是域名参数标识符，直接添加
            processed_args="$processed_args $arg"
        elif [[ "$arg" == -* ]]; then
            # 这是其他参数，直接添加
            processed_args="$processed_args $arg"
        else
            # 这是域名，需要检查是否需要编码
            local encoded_domain
            encoded_domain=$(encode_punycode_domain "$arg")
            processed_args="$processed_args $encoded_domain"
        fi
    done <<< "$domain_args"
    
    # 移除开头的空格并返回
    echo "${processed_args# }"
}

# Function: decode_punycode_domain
# 描述: 将域名解码为可读格式（统一解码策略）
# 参数:
#   $1 - 域名（可能是 punycode 编码或普通域名）
# 返回:
#   解码后的域名，如果解码失败则返回原域名
decode_punycode_domain() {
    local domain=$1
    
    # 统一进行 punycode 解码，无论是否包含 punycode 编码
    # 对于普通域名，解码后结果不变
    local decoded_domain
    decoded_domain=$(idn2 -d "$domain" 2>/dev/null)
    
    if [ $? -eq 0 ] && [ -n "$decoded_domain" ]; then
        echo "$decoded_domain"
    else
        # 解码失败，返回原域名
        echo "$domain"
    fi
}

# Function: get_main_domain
# 描述: 从完整域名中提取主域名部分
# 参数:
#   $1 - 完整域名 (例如: sub.example.com 或 中文域名)
# 返回:
#   主域名 (例如: example.com 或 解码后的中文域名)
#   对于中国特殊域名后缀，如 .com.cn, .net.cn 等，会正确处理
#   支持中文域名的 punycode 解码
get_main_domain() {
    local domain=$1
    
    # 首先解码 punycode 域名
    local decoded_domain
    decoded_domain=$(decode_punycode_domain "$domain")
    
    # 处理特殊中文 TLDs，如 .com.cn, .net.cn, .org.cn, .gov.cn, .edu.cn 等
    # 以及香港和台湾的特殊域名后缀 .hk, .tw
    if [[ "$decoded_domain" =~ .*\.(com|net|org|gov|edu)\.(cn|hk|tw)$ ]]; then
        echo "$decoded_domain" | grep -o '[^.]*\.[^.]*\.[^.]*$'
    else
        # 处理标准域名，提取最后两个部分
        echo "$decoded_domain" | grep -o '[^.]*\.[^.]*$'
    fi
}

# Function: get_subdomain_prefix
# 描述: 获取子域名前缀部分
# 参数: 
#   $1 - 完整域名 (例如: sub.example.com 或 中文域名)
#   $2 - 主域名 (例如: example.com 或 解码后的中文域名)
# 返回:
#   子域名前缀 (例如: sub)
#   如果是主域名本身，则返回 "@" 符号，表示根域
#   支持中文域名的 punycode 解码
get_subdomain_prefix() {
    local domain=$1
    local main_domain=$2
    
    # 首先解码 punycode 域名
    local decoded_domain
    decoded_domain=$(decode_punycode_domain "$domain")
    
    if [ "$decoded_domain" == "$main_domain" ]; then
        # 如果域名与主域名相同，返回 "@" 表示根域
        echo "@"
    else
        # 否则移除主域名部分，返回前缀
        echo "${decoded_domain%.$main_domain}"
    fi
}

# 导出函数，使其可在其他脚本中使用
export -f encode_punycode_domain
export -f decode_punycode_domain
export -f get_main_domain
export -f get_subdomain_prefix
export -f process_domain_args
