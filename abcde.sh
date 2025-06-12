#!/bin/bash

# Docker环境Nginx配置修复脚本
# 适用于已通过Docker Compose部署的Next.js应用

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

# 配置变量
DOCKER_NETWORK="relayx_default"  # Docker网络名称（根据compose文件修改）
FRONTEND_PORT=3000                # Next.js前端端口
BACKEND_PORT=3000                 # 后端端口
NGINX_SITE_AVAILABLE="/etc/nginx/sites-available/relayx-docker"
NGINX_SITE_ENABLED="/etc/nginx/sites-enabled/relayx-docker"
BACKUP_DIR="/root/nginx_docker_backup_$(date +%Y%m%d_%H%M%S)"

# 检测Docker网络是否存在
DOCKER_NETWORK_EXISTS=$(docker network list | grep -w "$DOCKER_NETWORK")
if [ -z "$DOCKER_NETWORK_EXISTS" ]; then
    log_warn "未找到Docker网络 '$DOCKER_NETWORK'，尝试自动检测..."
    DOCKER_NETWORK=$(docker network list | grep "bridge" | head -1 | awk '{print $2}')
    log_info "使用默认网络: $DOCKER_NETWORK"
fi

# 创建备份目录
mkdir -p $BACKUP_DIR
log_info "创建备份目录: $BACK
