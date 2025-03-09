#!/bin/bash

# 控制台工具库
# 用途: 提供美化终端输出的函数集合，用于增强脚本的可读性和用户体验
# 功能:
#   1. 彩色输出 - 使用 ANSI 颜色代码为不同类型的消息设置颜色
#   2. 格式化输出 - 提供标题、子标题、键值对等格式化输出函数
#   3. 状态消息 - 提供成功、错误、警告、信息等状态消息函数
#   4. 特定领域消息 - 提供 DNS、HTTP、部署等特定领域的消息函数
# 使用方法:
#   1. 在脚本中引入此文件: source /path/to/console_utils.sh
#   2. 使用提供的函数输出消息，如 print_success "操作成功"
# 环境变量:
#   NO_COLOR - 设置为 true 禁用颜色输出
#   TERM - 终端类型，用于检测颜色支持
#   DEBUG - 设置为 true 启用调试输出

# 检测终端是否支持颜色
# 通过检查是否是交互式终端以及终端类型来确定
if [ -t 1 ] && [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; then
  SUPPORTS_COLOR=true
else
  SUPPORTS_COLOR=false
fi

# 检测是否禁用颜色
# 可以通过设置 NO_COLOR=true 环境变量来禁用颜色
if [ "$NO_COLOR" = "true" ] || [ "$TERM" = "dumb" ]; then
  SUPPORTS_COLOR=false
fi

# 颜色定义
# 使用 ANSI 转义序列定义各种颜色和格式
if [ "$SUPPORTS_COLOR" = "true" ]; then
  # 文本颜色 - 用于设置文本前景色
  C_RESET="\033[0m"       # 重置所有属性
  C_BLACK="\033[0;30m"    # 黑色
  C_RED="\033[0;31m"      # 红色
  C_GREEN="\033[0;32m"    # 绿色
  C_YELLOW="\033[0;33m"   # 黄色
  C_BLUE="\033[0;34m"     # 蓝色
  C_PURPLE="\033[0;35m"   # 紫色
  C_CYAN="\033[0;36m"     # 青色
  C_WHITE="\033[0;37m"    # 白色
  
  # 粗体文本 - 用于强调重要信息
  C_BOLD_BLACK="\033[1;30m"   # 粗体黑色
  C_BOLD_RED="\033[1;31m"     # 粗体红色
  C_BOLD_GREEN="\033[1;32m"   # 粗体绿色
  C_BOLD_YELLOW="\033[1;33m"  # 粗体黄色
  C_BOLD_BLUE="\033[1;34m"    # 粗体蓝色
  C_BOLD_PURPLE="\033[1;35m"  # 粗体紫色
  C_BOLD_CYAN="\033[1;36m"    # 粗体青色
  C_BOLD_WHITE="\033[1;37m"   # 粗体白色
  
  # 背景颜色 - 用于设置文本背景色
  C_BG_BLACK="\033[40m"   # 黑色背景
  C_BG_RED="\033[41m"     # 红色背景
  C_BG_GREEN="\033[42m"   # 绿色背景
  C_BG_YELLOW="\033[43m"  # 黄色背景
  C_BG_BLUE="\033[44m"    # 蓝色背景
  C_BG_PURPLE="\033[45m"  # 紫色背景
  C_BG_CYAN="\033[46m"    # 青色背景
  C_BG_WHITE="\033[47m"   # 白色背景
else
  # 如果不支持颜色，则所有颜色变量设为空字符串
  C_RESET=""
  C_BLACK=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_PURPLE=""
  C_CYAN=""
  C_WHITE=""
  
  C_BOLD_BLACK=""
  C_BOLD_RED=""
  C_BOLD_GREEN=""
  C_BOLD_YELLOW=""
  C_BOLD_BLUE=""
  C_BOLD_PURPLE=""
  C_BOLD_CYAN=""
  C_BOLD_WHITE=""
  
  C_BG_BLACK=""
  C_BG_RED=""
  C_BG_GREEN=""
  C_BG_YELLOW=""
  C_BG_BLUE=""
  C_BG_PURPLE=""
  C_BG_CYAN=""
  C_BG_WHITE=""
fi

# Emoji 定义（可通过环境变量 NO_EMOJI 禁用）
if [ "$NO_EMOJI" != "true" ]; then
  EMOJI_SUCCESS="✅ "
  EMOJI_ERROR="❌ "
  EMOJI_WARNING="⚠️  "
  EMOJI_INFO="ℹ️  "
  EMOJI_DEBUG="🔍 "
  EMOJI_LOCK="🔒 "
  EMOJI_KEY="🔑 "
  EMOJI_CLOUD="☁️  "
  EMOJI_GLOBE="🌐 "
  EMOJI_TIME="⏱️  "
  EMOJI_ROCKET="🚀 "
  EMOJI_GEAR="⚙️  "
  EMOJI_CHECK="✓ "
  EMOJI_CROSS="✗ "
  EMOJI_BULLET="• "
  EMOJI_CERTIFICATE="📜 "
  EMOJI_ALIYUN="☁️🇨🇳 "
  EMOJI_TENCENT="☁️🇨🇳 "
  EMOJI_DNS="🔄 "
  EMOJI_HTTP="🌍 "
  EMOJI_HOOK="🔗 "
  EMOJI_ENV="🧪 "
  EMOJI_CRON="🕒 "
  EMOJI_DEPLOY="📦 "
else
  EMOJI_SUCCESS=""
  EMOJI_ERROR=""
  EMOJI_WARNING=""
  EMOJI_INFO=""
  EMOJI_DEBUG=""
  EMOJI_LOCK=""
  EMOJI_KEY=""
  EMOJI_CLOUD=""
  EMOJI_GLOBE=""
  EMOJI_TIME=""
  EMOJI_ROCKET=""
  EMOJI_GEAR=""
  EMOJI_CHECK=""
  EMOJI_CROSS=""
  EMOJI_BULLET=""
  EMOJI_CERTIFICATE=""
  EMOJI_ALIYUN=""
  EMOJI_TENCENT=""
  EMOJI_DNS=""
  EMOJI_HTTP=""
  EMOJI_HOOK=""
  EMOJI_ENV=""
  EMOJI_CRON=""
  EMOJI_DEPLOY=""
fi

# 辅助函数：打印带颜色的文本
print_colored() {
  local color="$1"
  local text="$2"
  
  if [ "$SUPPORTS_COLOR" = "true" ]; then
    echo -e "${color}${text}${C_RESET}"
  else
    echo "$text"
  fi
}

# 辅助函数：打印带颜色和 emoji 的文本
print_with_emoji() {
  local color="$1"
  local emoji="$2"
  local text="$3"
  
  if [ "$NO_EMOJI" != "true" ]; then
    print_colored "$color" "${emoji}${text}"
  else
    print_colored "$color" "$text"
  fi
}

# 打印标题
print_header() {
  local text="$1"
  local width=80
  local padding=$(( (width - ${#text} - 4) / 2 ))
  local line=$(printf '%*s' "$width" | tr ' ' '=')
  
  echo ""
  print_colored "$C_BOLD_PURPLE" "$line"
  print_colored "$C_BOLD_PURPLE" "$(printf "%*s %s %*s" $padding "" "$text" $padding "")"
  print_colored "$C_BOLD_PURPLE" "$line"
  echo ""
}

# 打印子标题
print_subheader() {
  local text="$1"
  local width=80
  local line=$(printf '%*s' "$width" | tr ' ' '-')
  
  echo ""
  print_colored "$C_BOLD_CYAN" "$text"
  print_colored "$C_CYAN" "$line"
}

# 打印成功消息
print_success() {
  local text="$1"
  print_with_emoji "$C_GREEN" "$EMOJI_SUCCESS" "$text"
}

# 打印错误消息
print_error() {
  local text="$1"
  print_with_emoji "$C_RED" "$EMOJI_ERROR" "$text"
}

# 打印警告消息
print_warning() {
  local text="$1"
  print_with_emoji "$C_YELLOW" "$EMOJI_WARNING" "$text"
}

# 打印信息消息
print_info() {
  local text="$1"
  print_with_emoji "$C_BLUE" "$EMOJI_INFO" "$text"
}

# 打印调试消息
print_debug() {
  if [ "$DEBUG" = "true" ]; then
    local text="$1"
    print_with_emoji "$C_CYAN" "$EMOJI_DEBUG" "$text"
  fi
}

# 打印证书相关消息
print_cert() {
  local text="$1"
  print_with_emoji "$C_GREEN" "$EMOJI_CERTIFICATE" "$text"
}

# 打印 DNS 相关消息
print_dns() {
  local text="$1"
  print_with_emoji "$C_PURPLE" "$EMOJI_DNS" "$text"
}

# 打印 HTTP 相关消息
print_http() {
  local text="$1"
  print_with_emoji "$C_BLUE" "$EMOJI_HTTP" "$text"
}

# 打印云服务提供商相关消息
print_cloud_provider() {
  local provider="$1"
  local text="$2"
  
  case "$provider" in
    "aliyun")
      print_with_emoji "$C_CYAN" "$EMOJI_ALIYUN" "$text"
      ;;
    "tencentcloud")
      print_with_emoji "$C_BLUE" "$EMOJI_TENCENT" "$text"
      ;;
    *)
      print_with_emoji "$C_BLUE" "$EMOJI_CLOUD" "$text"
      ;;
  esac
}

# 打印环境变量相关消息
print_env() {
  local text="$1"
  print_with_emoji "$C_YELLOW" "$EMOJI_ENV" "$text"
}

# 打印钩子相关消息
print_hook() {
  local text="$1"
  print_with_emoji "$C_PURPLE" "$EMOJI_HOOK" "$text"
}

# 打印定时任务相关消息
print_cron() {
  local text="$1"
  print_with_emoji "$C_BLUE" "$EMOJI_CRON" "$text"
}

# 打印部署相关消息
print_deploy() {
  local text="$1"
  print_with_emoji "$C_GREEN" "$EMOJI_DEPLOY" "$text"
}

# 打印步骤信息
print_step() {
  local step_num="$1"
  local text="$2"
  print_colored "$C_BOLD_BLUE" "[步骤 ${step_num}] ${text}"
}

# 打印分隔线
print_separator() {
  local width=80
  local line=$(printf '%*s' "$width" | tr ' ' '-')
  echo ""
  print_colored "$C_CYAN" "$line"
  echo ""
}

# 打印键值对
print_key_value() {
  local key="$1"
  local value="$2"
  
  printf "${C_BOLD_WHITE}%-20s${C_RESET} : ${C_CYAN}%s${C_RESET}\n" "$key" "$value"
}

# 导出所有函数，使其可在其他脚本中使用
export -f print_colored
export -f print_with_emoji
export -f print_header
export -f print_subheader
export -f print_success
export -f print_error
export -f print_warning
export -f print_info
export -f print_debug
export -f print_cert
export -f print_dns
export -f print_http
export -f print_cloud_provider
export -f print_env
export -f print_hook
export -f print_cron
export -f print_deploy
export -f print_step
export -f print_separator
export -f print_key_value 