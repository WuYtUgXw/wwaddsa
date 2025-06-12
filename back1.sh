#!/bin/bash

# Docker环境Nginx配置脚本（适用于 rtx.sly666.xyz）
# 自动配置Nginx反向代理到Docker容器中的Next.js前端和后端服务

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
    exit 1
}

# 检查root权限
if [ "$(id -u)" != "0" ]; then
   log_error "此脚本需要root权限运行，请使用sudo执行"
fi

# 配置变量（已设置您的域名）
DOMAIN="rtx.sly666.xyz"
DOCKER_NETWORK="relayx_default"  # Docker网络名称
FRONTEND_SERVICE="web"            # 前端服务名称
BACKEND_SERVICE="backend"        # 后端服务名称
FRONTEND_PORT=3000                # 前端容器端口
BACKEND_PORT=3000                 # 后端容器端口
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/$DOMAIN"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/$DOMAIN"
BACKUP_DIR="/root/nginx_backup_$(date +%Y%m%d_%H%M%S)"

# 检测Docker服务是否运行
log_info "检测Docker服务状态..."
FRONTEND_CONTAINER=$(docker ps -q --filter name=$FRONTEND_SERVICE)
BACKEND_CONTAINER=$(docker ps -q --filter name=$BACKEND_SERVICE)

if [ -z "$FRONTEND_CONTAINER" ]; then
    log_error "前端服务 '$FRONTEND_SERVICE' 未运行，请先通过Docker Compose启动服务"
fi

if [ -z "$BACKEND_CONTAINER" ]; then
    log_error "后端服务 '$BACKEND_SERVICE' 未运行，请先通过Docker Compose启动服务"
fi

# 获取容器IP地址
FRONTEND_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $FRONTEND_CONTAINER)
BACKEND_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $BACKEND_CONTAINER)

if [ -z "$FRONTEND_IP" ] || [ -z "$BACKEND_IP" ]; then
    log_warn "无法获取容器IP，将使用服务发现方式"
    FRONTEND_TARGET="$FRONTEND_SERVICE:$FRONTEND_PORT"
    BACKEND_TARGET="$BACKEND_SERVICE:$BACKEND_PORT"
else
    FRONTEND_TARGET="$FRONTEND_IP:$FRONTEND_PORT"
    BACKEND_TARGET="$BACKEND_IP:$BACKEND_PORT"
fi

# 创建备份目录
mkdir -p $BACKUP_DIR
log_info "创建备份目录: $BACKUP_DIR"

# 备份现有Nginx配置
log_info "备份Nginx配置..."
if [ -d "/etc/nginx" ]; then
    cp -rf /etc/nginx $BACKUP_DIR/nginx_config_bak
    log_info "Nginx配置已备份到: $BACKUP_DIR/nginx_config_bak"
else
    log_warn "未找到Nginx配置目录，跳过备份"
fi

# 检查并安装Nginx
log_info "检查Nginx安装..."
if ! command -v nginx &> /dev/null; then
    log_info "安装Nginx..."
    apt-get update -y
    apt-get install -y nginx
fi

# 配置Nginx站点（含域名和SSL准备）
log_info "配置Nginx站点: $DOMAIN"
cat > $NGINX_SITE_AVAILABLE << EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https
