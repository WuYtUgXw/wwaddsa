#!/bin/bash

# RelayX Docker Compose一键部署脚本
# 适用于Ubuntu/Debian系统

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
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

# 检查是否为root用户
if [ "$(id -u)" != "0" ]; then
    log_error "此脚本需要root权限运行，请使用sudo执行"
    exit 1
fi

# 配置参数
DOMAIN="rtx.sly666.xyz"
STACK_PROJECT_ID="a9842990-fc88-4a3e-a0ed-ee7ec0c9dd27"
STACK_PUBLISHABLE_CLIENT_KEY="pck_24nn23tvpmne289pdz62xfy4b9tx1sqnmpkcww2n74rc8"
STACK_SECRET_SERVER_KEY="ssk_1gjt814kznam5hrybej005z3wxkn7tqwxcp4rf8xjj5tr"
APP_DIR="/var/www/relayx"
PORT=3000

# 安装必要的依赖
install_dependencies() {
    log_info "正在更新系统并安装必要的依赖..."
    
    # 更新包列表
    apt-get update -y
    
    # 安装基础工具
    apt-get install -y curl gnupg2 ca-certificates lsb-release build-essential software-properties-common apt-transport-https
    
    # 安装Docker
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io
    
    # 安装Docker Compose
    curl -L "https://github.com/docker/compose/releases/download/v2.16.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # 安装Nginx
    apt-get install -y nginx
    
    # 安装Certbot
    add-apt-repository -y ppa:certbot/certbot
    apt-get update -y
    apt-get install -y certbot python3-certbot-nginx
    
    # 添加当前用户到docker组
    usermod -aG docker $SUDO_USER
    
    log_info "依赖安装完成"
}

# 配置防火墙
configure_firewall() {
    log_info "正在配置防火墙..."
    
    # 检查是否安装了ufw
    if ! command -v ufw &> /dev/null; then
        apt-get install -y ufw
    fi
    
    # 允许SSH、HTTP和HTTPS
    ufw allow OpenSSH
    ufw allow 'Nginx Full'
    
    # 启用防火墙
    echo "y" | ufw enable
    
    log_info "防火墙配置完成"
}

# 设置Docker Compose
setup_docker_compose() {
    log_info "正在配置Docker Compose..."
    
    # 创建应用目录
    mkdir -p $APP_DIR
    cd $APP_DIR
    
    # 创建Docker Compose文件
    cat > docker-compose.yml << EOF
version: '3'
services:
  relayx:
    image: ghcr.io/relayx-io/relayx:latest
    container_name: relayx
    restart: always
    environment:
      - NEXT_PUBLIC_STACK_PROJECT_ID=$STACK_PROJECT_ID
      - NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY=$STACK_PUBLISHABLE_CLIENT_KEY
      - STACK_SECRET_SERVER_KEY=$STACK_SECRET_SERVER_KEY
    ports:
      - "$PORT:3000"
    volumes:
      - ./data:/app/data
EOF
    
    # 创建数据目录
    mkdir -p $APP_DIR/data
    
    # 启动Docker容器
    docker-compose up -d
    
    log_info "Docker Compose配置完成，RelayX容器已启动"
}

# 配置Nginx反向代理
setup_nginx() {
    log_info "正在配置Nginx反向代理..."
    
    # 创建Nginx配置文件
    cat > /etc/nginx/sites-available/$DOMAIN << EOF
server {
    listen 80;
    server_name $DOMAIN;
    
    location / {
        proxy_pass http://localhost:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
    
    # 静态资源缓存
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 30d;
    }
}
EOF
    
    # 创建软链接启用站点
    ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/
    
    # 移除默认站点
    rm -f /etc/nginx/sites-enabled/default
    
    # 测试Nginx配置
    if ! nginx -t; then
        log_error "Nginx配置测试失败，请检查配置文件"
        exit 1
    fi
    
    # 重启Nginx
    systemctl restart nginx
    
    log_info "Nginx配置完成"
}

# 获取SSL证书
setup_ssl() {
    log_info "正在获取SSL证书..."
    
    # 使用Certbot获取SSL证书
    if ! certbot --nginx -d $DOMAIN --non-interactive --agree-tos --email admin@$DOMAIN; then
        log_warn "SSL证书获取失败，网站将以HTTP方式运行"
        log_warn "请检查域名DNS设置是否正确，或手动运行certbot获取证书"
        return 1
    fi
    
    # 设置证书自动更新
    systemctl enable certbot.timer
    systemctl start certbot.timer
    
    log_info "SSL证书配置完成"
    return 0
}

# 主函数
main() {
    log_info "开始使用Docker Compose部署RelayX应用..."
    
    install_dependencies
    configure_firewall
    setup_docker_compose
    setup_nginx
    
    # 尝试设置SSL，如果失败则继续部署HTTP版本
    if setup_ssl; then
        log_info "RelayX应用已成功部署到https://$DOMAIN"
    else
        log_info "RelayX应用已成功部署到http://$DOMAIN"
        log_info "请手动配置SSL证书以启用HTTPS"
    fi
    
    log_info "部署完成！"
}

# 执行主函数
main
