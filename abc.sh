#!/bin/bash

# 静态网站Nginx配置修复脚本
# 适用于纯HTML/CSS/JS项目（无Node.js）

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 恢复默认颜色

# 日志函数
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查root权限
if [ "$(id -u)" != "0" ]; then
   log_error "此脚本需要root权限运行，请使用sudo执行"
   exit 1
fi

# 配置变量（纯静态网站）
STATIC_PATH="/var/www/relayx"  # 静态资源实际路径
NGINX_HTML="/usr/share/nginx/html"
NGINX_CONFIG_MAIN="/etc/nginx/nginx.conf"
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/relayx"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/relayx"
BACKUP_DIR="/root/nginx_backup_$(date +%Y%m%d_%H%M%S)"

# 创建备份目录
mkdir -p $BACKUP_DIR
log_info "创建备份目录: $BACKUP_DIR"

# 备份现有配置
log_info "备份当前Nginx配置..."
cp -rf $NGINX_CONFIG_MAIN $BACKUP_DIR/nginx.conf.bak
cp -rf /etc/nginx/conf.d $BACKUP_DIR/conf.d.bak
if [ -f "$NGINX_SITE_AVAILABLE" ]; then
    cp $NGINX_SITE_AVAILABLE $BACKUP_DIR/relayx_site.bak
fi
if [ -f "$NGINX_SITE_ENABLED" ]; then
    cp $NGINX_SITE_ENABLED $BACKUP_DIR/relayx_site_enabled.bak
fi

# 检查并安装必要工具
log_info "检查并安装必要工具..."
apt-get update -y
apt-get install -y nginx curl

# 检查静态资源目录
if [ ! -d "$STATIC_PATH" ]; then
    log_warn "静态资源目录不存在，创建示例目录: $STATIC_PATH"
    mkdir -p $STATIC_PATH
    
    # 创建示例首页
    cat > $STATIC_PATH/index.html << 'EOL'
<!DOCTYPE html>
<html>
<head>
    <title>RelayX 静态网站</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; padding: 50px; }
        .container { max-width: 800px; margin: 0 auto; }
        h1 { color: #3498db; }
        p { color: #555; }
    </style>
</head>
<body>
    <div class="container">
        <h1>RelayX 静态网站测试</h1>
        <p>此页面由Nginx直接提供静态内容，无需Node.js环境。</p>
        <p>当前时间: <span id="current-time"></span></p>
    </div>
    <script>
