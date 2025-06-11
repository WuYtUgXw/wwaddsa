#!/bin/bash

# RelayX一键部署脚本
# 基于官方Docker Compose配置
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
NGINX_SITE_CONFIG="/etc/nginx/sites-available/$DOMAIN"
NGINX_SITE_LINK="/etc/nginx/sites-enabled/$DOMAIN"
MYSQL_PASSWORD="changeme"  # 可以修改为更安全的密码
TELEGRAM_BOT_TOKEN="your_telegram_bot_token"  # 需要替换为实际的Telegram Bot Token

# 安装必要的依赖
install_dependencies() {
    log_info "正在更新系统并安装必要的依赖..."
    
    # 更新包列表
    apt-get update -y
    
    # 安装基础工具
    apt-get install -y curl gnupg2 ca-certificates lsb-release build-essential software-properties-common apt-transport-https
    
    # 安装Docker
    log_info "正在安装Docker..."
    if [ -f /etc/apt/sources.list.d/docker.list ]; then
        log_info "Docker仓库已配置，跳过添加"
    else
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io
    
    # 安装Docker Compose
    log_info "正在安装Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/download/v2.16.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    
    # 安装Nginx
    log_info "正在安装Nginx..."
    apt-get install -y nginx
    
    # 安装Certbot
    log_info "正在安装Certbot..."
    add-apt-repository -y ppa:certbot/certbot
    apt-get update -y
    apt-get install -y certbot python3-certbot-nginx
    
    # 安装dig工具
    apt-get install -y dnsutils
    
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

# 检查端口占用情况
check_port_usage() {
    log_info "检查端口占用情况..."
    
    # 检查80端口
    if netstat -tulpn | grep -q :80; then
        log_warn "端口80已被占用"
        log_info "占用进程:"
        netstat -tulpn | grep :80
        return 1
    fi
    
    # 检查443端口
    if netstat -tulpn | grep -q :443; then
        log_warn "端口443已被占用"
        log_info "占用进程:"
        netstat -tulpn | grep :443
        return 1
    fi
    
    log_info "所需端口未被占用"
    return 0
}

# 停止占用端口的服务
stop_port_conflicts() {
    log_info "尝试停止占用端口的服务..."
    
    # 检查并停止Nginx（如果是其他应用占用）
    if systemctl is-active --quiet nginx && ! netstat -tulpn | grep -q "nginx.*:80"; then
        log_info "停止Nginx服务..."
        systemctl stop nginx
        systemctl disable nginx
    fi
    
    # 检查并停止Apache
    if systemctl is-active --quiet apache2; then
        log_info "停止Apache服务..."
        systemctl stop apache2
        systemctl disable apache2
    fi
    
    # 再次检查端口
    if check_port_usage; then
        log_info "端口冲突已解决"
        return 0
    else
        log_error "无法自动解决端口冲突，请手动停止占用80和443端口的服务"
        return 1
    fi
}

# 设置Docker Compose
setup_docker_compose() {
    log_info "正在配置Docker Compose..."
    
    # 创建应用目录
    mkdir -p $APP_DIR
    cd $APP_DIR
    
    # 创建Docker Compose文件 - 不包含Caddy服务
    log_info "创建Docker Compose配置..."
    cat > docker-compose.yml << EOF
version: '3'
services:
  db-migrate:
    image: relayx/db-migrate
    container_name: db-migrate
    env_file:
      - .env
    depends_on:
      mysql:
        condition: service_healthy
  relayx:
    image: relayx/backend
    container_name: backend
    restart: always
    env_file:
      - .env
    depends_on:
      redis:
        condition: service_healthy
      mysql:
        condition: service_healthy
      db-migrate:
        condition: service_completed_successfully
  worker:
    image: relayx/backend
    container_name: worker
    restart: always
    env_file:
      - .env
    command: ["./relayx-worker"]
    depends_on:
      redis:
        condition: service_healthy
      mysql:
        condition: service_healthy
      db-migrate:
        condition: service_completed_successfully
  web:
    image: relayx/web
    container_name: web
    restart: always
    env_file:
      - .env
    ports:
      - "3000:3000"  # 暴露web服务的3000端口
    depends_on:
      - relayx
  redis:
    image: redis
    container_name: redis
    restart: always
    volumes:
      - redis:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
  mysql:
    image: mysql
    container_name: mysql
    environment:
      MYSQL_ROOT_PASSWORD: $MYSQL_PASSWORD
      MYSQL_DATABASE: relayx
    restart: always
    volumes:
      - mysql:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
volumes:
  redis:
  mysql:
EOF
    
    # 创建环境变量文件
    log_info "创建环境变量配置..."
    cat > .env << EOF
DATABASE_URL="mysql://root:$MYSQL_PASSWORD@mysql:3306/relayx"
REDIS_URL="redis://redis:6379"
SITE_URL="https://$DOMAIN"
STACK_API_URL="https://api.stack-auth.com"
STACK_PROJECT_ID=$STACK_PROJECT_ID
STACK_SECRET_SERVER_KEY=$STACK_SECRET_SERVER_KEY
STACK_PUBLISHABLE_CLIENT_KEY=$STACK_PUBLISHABLE_CLIENT_KEY
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
API_URL="http://relayx:3000"
EOF
    
    # 创建数据目录
    mkdir -p $APP_DIR/data
    
    log_info "Docker Compose配置完成"
}

# 配置Nginx反向代理
setup_nginx_proxy() {
    log_info "正在配置Nginx反向代理..."
    
    # 创建Nginx配置文件
    cat > $NGINX_SITE_CONFIG << EOF
# 添加websocket支持的映射配置
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 80;
    listen 443 ssl http2;
    server_name $DOMAIN;

    # SSL配置（将由Certbot自动配置）
    # ssl_certificate /path/to/your/cert.pem;
    # ssl_certificate_key /path/to/your/key.pem;

    location / {
        proxy_pass http://localhost:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        # websocket支持
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    
    # 静态资源缓存
    location ~* \.(jpg|jpeg|png|gif|ico|css|js)$ {
        expires 30d;
    }
    
    # 错误页面
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF
    
    # 创建软链接启用站点
    ln -sf $NGINX_SITE_CONFIG $NGINX_SITE_LINK
    
    # 移除默认站点
    rm -f /etc/nginx/sites-enabled/default
    
    # 测试Nginx配置
    log_info "测试Nginx配置..."
    if ! nginx -t; then
        log_error "Nginx配置测试失败，请检查配置文件"
        return 1
    fi
    
    # 重启Nginx
    log_info "重启Nginx服务..."
    if ! systemctl restart nginx; then
        log_error "Nginx重启失败"
        return 1
    fi
    
    log_info "Nginx配置完成"
    return 0
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

# 启动服务
start_services() {
    log_info "正在启动RelayX服务..."
    
    cd $APP_DIR
    
    # 检查Docker Compose文件
    if [ ! -f "docker-compose.yml" ]; then
        log_error "Docker Compose文件不存在，请检查配置"
        return 1
    fi
    
    # 启动服务
    if ! docker-compose up -d; then
        log_error "服务启动失败"
        return 1
    fi
    
    log_info "服务启动命令已执行"
    
    # 等待服务启动
    log_info "等待服务完全启动..."
    sleep 30
    
    # 检查服务状态
    log_info "检查服务状态..."
    docker-compose ps
    
    # 检查关键服务是否运行
    if ! docker ps | grep -q web; then
        log_warn "Web服务未运行"
        log_info "Web日志:"
        docker logs web
    fi
    
    # 检查db-migrate容器状态
    if [ "$(docker inspect -f '{{.State.ExitCode}}' db-migrate 2>/dev/null)" != "0" ]; then
        log_warn "数据库迁移服务可能未成功完成"
        log_info "db-migrate日志:"
        docker logs db-migrate
    fi
    
    log_info "服务启动检查完成"
    return 0
}

# 检查域名DNS解析
check_dns() {
    log_info "检查域名DNS解析..."
    
    # 获取当前服务器IP
    SERVER_IP=$(curl -s ifconfig.me)
    
    # 获取域名解析IP
    DOMAIN_IP=$(dig +short $DOMAIN)
    
    if [ "$SERVER_IP" != "$DOMAIN_IP" ]; then
        log_warn "域名DNS解析可能不正确"
        log_warn "服务器IP: $SERVER_IP"
        log_warn "域名解析IP: $DOMAIN_IP"
        log_warn "这可能导致HTTPS证书申请失败"
        
        read -p "是否继续部署? (y/n): " choice
        if [ "$choice" != "y" ] && [ "$choice" != "Y" ]; then
            log_info "部署已取消"
            return 1
        fi
    fi
    
    log_info "域名DNS检查完成"
    return 0
}

# 主函数
main() {
    log_info "开始使用Docker Compose部署RelayX应用..."
    
    install_dependencies
    configure_firewall
    
    if ! check_dns; then
        log_error "DNS检查失败，中止部署"
        exit 1
    fi
    
    # 检查端口占用
    if ! check_port_usage; then
        log_warn "发现端口冲突"
        if ! stop_port_conflicts; then
            log_error "无法解决端口冲突，中止部署"
            exit 1
        fi
    fi
    
    setup_docker_compose
    
    if ! start_services; then
        log_error "服务启动失败，中止部署"
        exit 1
    fi
    
    if ! setup_nginx_proxy; then
        log_error "Nginx配置失败，中止部署"
        exit 1
    fi
    
    # 尝试设置SSL，如果失败则继续部署HTTP版本
    if setup_ssl; then
        log_info "RelayX应用已成功部署到https://$DOMAIN"
    else
        log_info "RelayX应用已成功部署到http://$DOMAIN"
        log_info "请手动配置SSL证书以启用HTTPS"
    fi
    
    log_info "部署完成！"
    
    # 显示部署信息
    log_info "========== 部署信息 =========="
    log_info "应用访问地址: https://$DOMAIN"
    log_info "应用目录: $APP_DIR"
    log_info "MySQL密码: $MYSQL_PASSWORD (请妥善保管)"
    log_info "服务管理命令: docker-compose [start|stop|restart|logs]"
    log_info "Nginx配置文件: $NGINX_SITE_CONFIG"
    log_info "=============================="
}

# 执行主函数
main
