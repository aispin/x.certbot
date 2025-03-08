#!/bin/bash

# DNS Helper Functions
# 这个脚本包含 DNS 验证脚本中使用的共享函数

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

# Function to verify DNS record propagation
verify_dns_record() {
    local domain=$1
    local expected_value=$2
    local max_attempts=${3:-3}
    local wait_time=${4:-20}
    
    echo "验证 DNS 记录传播情况..."
    echo "域名: _acme-challenge.$domain"
    echo "预期值: $expected_value"
    
    # 初始等待，给 DNS 一些传播时间
    sleep $wait_time
    
    for attempt in $(seq 1 $max_attempts); do
        echo "尝试 $attempt/$max_attempts 验证 DNS 记录..."
        
        # 使用 dig 查询 TXT 记录
        TXT_RECORD=$(dig +short TXT _acme-challenge.$domain)
        echo "查询结果: $TXT_RECORD"
        
        if [[ "$TXT_RECORD" == *"$expected_value"* ]]; then
            echo "✅ DNS 验证成功: 找到匹配的 TXT 记录"
            return 0
        else
            echo "⚠️ 警告: 未找到匹配的 TXT 记录，继续尝试..."
            
            # 使用多个 DNS 服务器查询
            echo "尝试使用其他 DNS 服务器查询..."
            for dns_server in 8.8.8.8 1.1.1.1 114.114.114.114; do
                echo "使用 DNS 服务器 $dns_server 查询:"
                OTHER_RESULT=$(dig @$dns_server +short TXT _acme-challenge.$domain)
                echo "结果: $OTHER_RESULT"
                
                if [[ "$OTHER_RESULT" == *"$expected_value"* ]]; then
                    echo "✅ 使用 $dns_server 验证成功"
                    return 0
                fi
            done
            
            # 如果不是最后一次尝试，则等待后重试
            if [ $attempt -lt $max_attempts ]; then
                echo "等待 $wait_time 秒后重试..."
                sleep $wait_time
            fi
        fi
    done
    
    echo "⚠️ 警告: DNS 验证未成功，但将继续尝试 Let's Encrypt 验证"
    echo "可能原因:"
    echo "1. DNS 传播需要更长时间"
    echo "2. DNS 记录未正确添加"
    echo "3. DNS 服务器缓存问题"
    echo "建议增加 DNS_PROPAGATION_SECONDS 值或检查 DNS 配置"
    
    # 返回非零但不退出脚本，让 Certbot 继续尝试验证
    return 1
}

# Function to calculate verification timing
calculate_verification_timing() {
    local total_time=$1
    local attempts=${2:-3}
    
    # 计算每次验证之间的等待时间
    local wait_time=$((total_time / (attempts + 1)))
    
    # 计算剩余等待时间
    local remaining_time=$((total_time - attempts * wait_time))
    
    # 返回结果
    echo "$attempts $wait_time $remaining_time"
}

# 导出函数，使其可在其他脚本中使用
export -f get_main_domain
export -f get_subdomain_prefix
export -f verify_dns_record
export -f calculate_verification_timing 