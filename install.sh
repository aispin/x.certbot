#!/bin/bash

# X Certbot 安装脚本
# 用于在无 Docker 环境的服务器上直接安装和配置 X Certbot

# 默认设置
REPO_URL="https://github.com/aispin/x.certbot.git"
BRANCH="main"
INSTALL_DIR="/etc/xcertbot"
TEMP_DIR="/tmp/xcertbot-install"
VERSION=""

# 显示帮助信息
show_help() {
    echo "X Certbot 安装脚本"
    echo "用法: $0 [选项]"
    echo
    echo "选项:"
    echo "  -h, --help              显示此帮助信息"
    echo "  -r, --repo URL          指定 Git 仓库 URL (默认: $REPO_URL)"
    echo "  -b, --branch BRANCH     指定 Git 分支 (默认: $BRANCH)"
    echo "  -v, --version VERSION   指定版本标签 (如果指定，将覆盖分支设置)"
    echo "  -d, --dir DIRECTORY     指定安装目录 (默认: $INSTALL_DIR)"
    echo
    echo "示例:"
    echo "  $0                                  # 使用默认设置安装"
    echo "  $0 --repo https://github.com/yourusername/x.certbot.git  # 使用自定义仓库"
    echo "  $0 --version v1.0.0                 # 安装特定版本"
    echo
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -h|--help)
            show_help
            exit 0
            ;;
        -r|--repo)
            REPO_URL="$2"
            shift 2
            ;;
        -b|--branch)
            BRANCH="$2"
            shift 2
            ;;
        -v|--version)
            VERSION="$2"
            shift 2
            ;;
        -d|--dir)
            INSTALL_DIR="$2"
            shift 2
            ;;
        *)
            echo "未知选项: $1"
            show_help
            exit 1
            ;;
    esac
done

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误: 请使用 root 权限运行此脚本"
    echo "例如: sudo $0"
    exit 1
fi

echo "=== X Certbot 安装脚本 ==="
echo "此脚本将在您的服务器上安装 X Certbot 及其依赖"
echo

# 检查必要工具
check_command() {
    if ! command -v $1 &> /dev/null; then
        echo "错误: 未找到命令 '$1'"
        echo "请先安装 $1"
        exit 1
    fi
}

# 检查 git 命令
check_command git

# 检测操作系统
echo "检测操作系统..."
if command -v apt-get &> /dev/null; then
    PKG_MANAGER="apt-get"
    echo "检测到 Debian/Ubuntu 系统"
    $PKG_MANAGER update
    $PKG_MANAGER install -y certbot python3 python3-pip python3-venv jq curl wget git
elif command -v yum &> /dev/null; then
    PKG_MANAGER="yum"
    echo "检测到 CentOS/RHEL 系统"
    $PKG_MANAGER install -y epel-release
    $PKG_MANAGER install -y certbot python3 python3-pip jq curl wget git
elif command -v apk &> /dev/null; then
    PKG_MANAGER="apk"
    echo "检测到 Alpine 系统"
    $PKG_MANAGER add --no-cache certbot python3 py3-pip jq curl wget bash git
else
    echo "不支持的操作系统，请手动安装依赖"
    exit 1
fi

# 创建临时目录
echo "创建临时目录..."
rm -rf "$TEMP_DIR"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"

# 克隆仓库
echo "从 GitHub 克隆 X Certbot 仓库..."
if [ -n "$VERSION" ]; then
    echo "克隆版本: $VERSION"
    git clone --depth 1 --branch "$VERSION" "$REPO_URL" .
else
    echo "克隆分支: $BRANCH"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" .
fi

if [ $? -ne 0 ]; then
    echo "错误: 克隆仓库失败"
    exit 1
fi

# 安装阿里云 CLI
echo "安装阿里云 CLI..."
if [ ! -f "/usr/local/bin/aliyun" ]; then
    wget -O aliyun-cli.tgz https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz
    tar -xzvf aliyun-cli.tgz
    mv aliyun /usr/local/bin/
    rm aliyun-cli.tgz
    echo "阿里云 CLI 安装完成"
else
    echo "阿里云 CLI 已安装，跳过"
fi

# 创建目录结构
echo "创建目录结构..."
mkdir -p $INSTALL_DIR/scripts
mkdir -p $INSTALL_DIR/plugins/dns
mkdir -p $INSTALL_DIR/plugins/http
mkdir -p /etc/letsencrypt/certs
mkdir -p /var/log/xcertbot

# 创建 Python 虚拟环境
echo "创建 Python 虚拟环境..."
if [ ! -d "/opt/xcertbot-venv" ]; then
    python3 -m venv /opt/xcertbot-venv
    source /opt/xcertbot-venv/bin/activate
    pip install --upgrade pip
    pip install aliyun-python-sdk-core aliyun-python-sdk-alidns
    echo "Python 虚拟环境创建完成"
else
    echo "Python 虚拟环境已存在，跳过"
fi

# 复制脚本文件
echo "复制脚本文件..."
cp entrypoint.sh $INSTALL_DIR/
cp scripts/deploy-hook.sh $INSTALL_DIR/scripts/

# 确保插件目录存在
if [ -d "plugins/dns" ]; then
    cp plugins/dns/* $INSTALL_DIR/plugins/dns/
else
    echo "警告: plugins/dns 目录不存在，跳过复制"
fi

if [ -d "plugins/http" ]; then
    cp plugins/http/* $INSTALL_DIR/plugins/http/
else
    echo "警告: plugins/http 目录不存在，跳过复制"
fi

# 设置执行权限
chmod +x $INSTALL_DIR/entrypoint.sh
chmod +x $INSTALL_DIR/scripts/deploy-hook.sh
if [ -d "$INSTALL_DIR/plugins/dns" ]; then
    chmod +x $INSTALL_DIR/plugins/dns/*.sh
fi
if [ -d "$INSTALL_DIR/plugins/http" ]; then
    chmod +x $INSTALL_DIR/plugins/http/*.sh
fi

# 创建配置文件
if [ ! -f "$INSTALL_DIR/.env" ]; then
    echo "创建配置文件..."
    if [ -f "docs/.env.example" ]; then
        # 使用 .env.example 作为模板
        cp docs/.env.example $INSTALL_DIR/.env
        echo "已使用 docs/.env.example 作为配置模板"
    else
        echo "警告: docs/.env.example 文件不存在，将创建基本配置文件"
        cat > $INSTALL_DIR/.env <<EOL
# X Certbot 环境变量配置文件
# 请根据您的需求修改以下配置

# 阿里云区域
ALIYUN_REGION=cn-hangzhou

# 阿里云访问密钥（建议使用RAM用户的密钥，只需要DNS修改权限）
ALIYUN_ACCESS_KEY_ID=your-access-key-id
ALIYUN_ACCESS_KEY_SECRET=your-access-key-secret

# 域名参数，使用逗号分隔
DOMAIN_ARG=-d example.com -d *.example.com

# 证书所有者的电子邮件地址
EMAIL=your-email@example.com

# 验证方式：dns 或 http
CHALLENGE_TYPE=dns

# 云服务提供商：aliyun 或 tencentcloud
CLOUD_PROVIDER=aliyun

# DNS记录传播等待时间（秒）
DNS_PROPAGATION_SECONDS=60

# 证书自动续期的cron表达式
CRON_SCHEDULE=0 0 * * 1,4
EOL
    fi
    echo "请编辑 $INSTALL_DIR/.env 文件，填入您的配置信息"
else
    echo "配置文件已存在，跳过创建"
fi

# 创建启动脚本
echo "创建启动脚本..."
cat > /usr/local/bin/xcertbot <<EOL
#!/bin/bash
export PATH="/opt/xcertbot-venv/bin:\$PATH"
source /opt/xcertbot-venv/bin/activate
$INSTALL_DIR/entrypoint.sh "\$@" 2>&1 | tee -a /var/log/xcertbot/xcertbot.log
EOL
chmod +x /usr/local/bin/xcertbot

# 设置 cron 任务
echo "设置自动续期任务..."
CRON_SCHEDULE=$(grep CRON_SCHEDULE $INSTALL_DIR/.env | cut -d= -f2 | xargs || echo "0 0 * * 1,4")
echo "$CRON_SCHEDULE /usr/local/bin/xcertbot renew > /var/log/xcertbot/renewal.log 2>&1" > /etc/cron.d/xcertbot
chmod 0644 /etc/cron.d/xcertbot

# 创建符号链接
ln -sf $INSTALL_DIR/entrypoint.sh /usr/local/bin/entrypoint.sh

# 清理临时目录
echo "清理临时文件..."
cd /
rm -rf "$TEMP_DIR"

echo
echo "=== 安装完成 ==="
echo "X Certbot 已安装到 $INSTALL_DIR"
echo
echo "请执行以下步骤完成配置："
echo "1. 编辑配置文件："
echo "   nano $INSTALL_DIR/.env"
echo
echo "2. 获取证书："
echo "   xcertbot"
echo
echo "3. 证书将保存在 /etc/letsencrypt/certs/ 目录中"
echo
echo "4. 证书会根据 cron 设置自动续期，您也可以手动触发续期："
echo "   xcertbot renew"
echo
echo "5. 查看日志："
echo "   cat /var/log/xcertbot/xcertbot.log"
echo
echo "感谢使用 X Certbot！" 