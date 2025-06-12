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
cp -rf $NGINX_CONFIG_MAIN $
