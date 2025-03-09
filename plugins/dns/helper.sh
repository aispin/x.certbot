#!/bin/bash

# DNS Helper Functions
# 这个脚本包含 DNS 验证脚本中使用的共享函数
# 主要提供域名处理相关的功能，用于 DNS-01 验证过程中

# Function: get_main_domain
# 描述: 从完整域名中提取主域名部分
# 参数:
#   $1 - 完整域名 (例如: sub.example.com)
# 返回:
#   主域名 (例如: example.com)
#   对于中国特殊域名后缀，如 .com.cn, .net.cn 等，会正确处理
get_main_domain() {
    local domain=$1
    
    # 处理特殊中文 TLDs，如 .com.cn, .net.cn, .org.cn, .gov.cn, .edu.cn 等
    # 以及香港和台湾的特殊域名后缀 .hk, .tw
    if [[ "$domain" =~ .*\.(com|net|org|gov|edu)\.(cn|hk|tw)$ ]]; then
        echo "$domain" | grep -o '[^.]*\.[^.]*\.[^.]*$'
    else
        # 处理标准域名，提取最后两个部分
        echo "$domain" | grep -o '[^.]*\.[^.]*$'
    fi
}

# Function: get_subdomain_prefix
# 描述: 获取子域名前缀部分
# 参数:
#   $1 - 完整域名 (例如: sub.example.com)
#   $2 - 主域名 (例如: example.com)
# 返回:
#   子域名前缀 (例如: sub)
#   如果是主域名本身，则返回 "@" 符号，表示根域
get_subdomain_prefix() {
    local domain=$1
    local main_domain=$2
    
    if [ "$domain" == "$main_domain" ]; then
        # 如果域名与主域名相同，返回 "@" 表示根域
        echo "@"
    else
        # 否则移除主域名部分，返回前缀
        echo "${domain%.$main_domain}"
    fi
}

# 导出函数，使其可在其他脚本中使用
export -f get_main_domain
export -f get_subdomain_prefix 