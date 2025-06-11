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
    ufw allow 80/tcp
    ufw allow 443/tcp
    
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
    log_info "创建Docker Compose配置..."
    cat > docker-compose.yml << EOF
version: '3'
services:
  caddy:
    image: caddy
    cap_add:
      - NET_ADMIN
    container_name: caddy
    restart: always
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    ports:
      - 80:80
      - 443:443
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
  caddy_data:
  caddy_config:
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
    
    # 创建Caddyfile
    log_info "创建Caddy配置文件..."
    cat > Caddyfile << EOF
$DOMAIN {
    reverse_proxy web:3000
}
EOF
    
    # 创建数据目录
    mkdir -p $APP_DIR/data
    
    log_info "Docker Compose配置完成"
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
    if ! docker ps | grep -q caddy; then
        log_warn "Caddy服务未运行"
        log_info "Caddy日志:"
        docker logs caddy
    fi
    
    if ! docker ps | grep -q web; then
        log_warn "Web服务未运行"
        log_info "Web日志:"
        docker logs web
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
    
    setup_docker_compose
    
    if ! start_services; then
        log_error "服务启动失败，中止部署"
        exit 1
    fi
    
    log_info "RelayX应用已成功部署到https://$DOMAIN"
    log_info "部署完成！"
    
    # 显示部署信息
    log_info "========== 部署信息 =========="
    log_info "应用访问地址: https://$DOMAIN"
    log_info "应用目录: $APP_DIR"
    log_info "MySQL密码: $MYSQL_PASSWORD (请妥善保管)"
    log_info "服务管理命令: docker-compose [start|stop|restart|logs]"
    log_info "=============================="
}

# 执行主函数
main
