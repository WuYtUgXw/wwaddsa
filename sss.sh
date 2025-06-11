#!/bin/bash
# Nginx反代网站全自动部署脚本 - 支持HTTPS证书自动申请
# 最后更新：2025-06-12

# 全局配置（需提前修改）
DOMAIN="your-domain.com"        # 网站域名
EMAIL="admin@your-domain.com"   # 证书申请邮箱
APP_PORT="3000"                 # 后端应用端口
TIMEZONE="Asia/Shanghai"        # 系统时区

# 颜色与日志函数
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
RESET="\033[0m"

log_info() { echo -e "${YELLOW}[INFO] $1${RESET}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${RESET}"; }
log_error() { echo -e "${RED}[ERROR] $1${RESET}"; exit 1; }

# 环境检测
log_info "开始环境检测..."
if [ "$(id -u)" -ne 0 ]; then
    log_error "请使用root权限执行脚本（sudo ./script.sh）"
fi

# 系统兼容性处理
OS_ID=$(grep -i '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')
OS_VERSION=$(grep -i '^VERSION_ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')

log_info "检测到系统：${OS_ID} ${OS_VERSION}"
PACKAGE_MANAGER=""
if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    PACKAGE_MANAGER="apt"
elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" ]]; then
    PACKAGE_MANAGER="yum"
else
    log_error "暂不支持此系统：${OS_ID}"
fi

# 1. 基础环境配置
log_info "步骤1/8：配置系统基础环境"
# 设置时区
timedatectl set-timezone $TIMEZONE || log_error "时区设置失败"

# 安装基础工具
if [ "$PACKAGE_MANAGER" == "apt" ]; then
    apt-get update || log_error "软件源更新失败"
    apt-get install -y curl nginx git python3 python3-pip || log_error "基础工具安装失败"
else
    yum update -y || log_error "软件源更新失败"
    yum install -y curl nginx git python3 || log_error "基础工具安装失败"
    pip3 install --upgrade pip || log_info "Python包管理器已更新"
fi

# 2. 安装Docker与Docker Compose（如需要部署Docker应用）
log_info "步骤2/8：安装Docker与Docker Compose（可选）"
install_docker() {
    # 移除旧版Docker
    if [ "$PACKAGE_MANAGER" == "apt" ]; then
        apt-get remove -y docker docker-engine docker.io containerd runc || log_info "无旧版Docker"
    else
        yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine || log_info "无旧版Docker"
    fi

    # 安装Docker（含国内镜像）
    curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
    if [ $? -ne 0 ]; then
        log_error "Docker安装失败，请检查网络连接"
    fi
    systemctl start docker && systemctl enable docker || log_error "Docker服务启动失败"

    # 安装Docker Compose
    COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep "tag_name" | cut -d'"' -f4 | sed 's/v//')
    curl -L "https://github.com/docker/compose/releases/download/v${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose || log_info "Docker Compose软链接已存在"
    docker compose version || log_error "Docker Compose安装失败"
}

# 询问是否安装Docker（可注释此行实现全自动安装）
read -p "是否需要安装Docker环境？(y/n): " INSTALL_DOCKER
if [[ "$INSTALL_DOCKER" == "y" || "$INSTALL_DOCKER" == "Y" ]]; then
    install_docker
else
    log_info "跳过Docker安装，仅配置Nginx反代"
fi

# 3. 申请Let's Encrypt证书
log_info "步骤3/8：自动申请HTTPS证书"
mkdir -p /etc/nginx/ssl/${DOMAIN}
CERT_PATH="/etc/nginx/ssl/${DOMAIN}/fullchain.pem"
KEY_PATH="/etc/nginx/ssl/${DOMAIN}/privkey.pem"

if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
    log_info "正在申请证书，可能需要1-2分钟..."
    if [ "$PACKAGE_MANAGER" == "apt" ]; then
        apt-get install -y certbot python3-certbot-nginx || log_error "Certbot安装失败"
    else
        yum install -y certbot python3-certbot-nginx || log_error "Certbot安装失败"
    fi
    
    certbot certonly --nginx -d ${DOMAIN} --email ${EMAIL} --non-interactive --agree-tos
    if [ $? -ne 0 ]; then
        log_info "尝试使用standalone模式申请证书..."
        certbot certonly --standalone -d ${DOMAIN} --email ${EMAIL} --non-interactive --agree-tos
        if [ $? -ne 0 ]; then
            log_error "证书申请失败，请手动准备证书"
        fi
        cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem $CERT_PATH
        cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem $KEY_PATH
    else
        cp /etc/letsencrypt/live/${DOMAIN}/fullchain.pem $CERT_PATH
        cp /etc/letsencrypt/live/${DOMAIN}/privkey.pem $KEY_PATH
    fi
    chmod 600 $CERT_PATH $KEY_PATH
    log_success "HTTPS证书申请成功"
else
    log_success "检测到已有证书，跳过申请"
fi

# 4. 配置Nginx反代
log_info "步骤4/8：生成Nginx反代配置"
cat > /etc/nginx/conf.d/${DOMAIN}.conf << EOF
# HTTP自动跳转HTTPS
server {
    listen 80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

# HTTPS反代配置（含Websocket支持）
server {
    listen 443 ssl http2;
    server_name ${DOMAIN};
    
    # SSL证书配置
    ssl_certificate ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    
    # SSL安全配置
    ssl_protocols TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 8.8.8.8 8.8.4.4 valid=300s;
    resolver_timeout 5s;
    
    # 反代基础配置
    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        
        # Websocket支持
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    
    # 错误页面配置
    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /usr/share/nginx/html;
    }
}
EOF

# 验证并重启Nginx
nginx -t || log_error "Nginx配置错误，请检查证书路径"
systemctl restart nginx || log_error "Nginx服务重启失败"
log_success "Nginx反代配置完成"

# 5. 配置证书自动更新
log_info "步骤5/8：设置证书自动更新"
if [ "$PACKAGE_MANAGER" == "apt" ]; then
    CRON_CMD="0 0 1 * * certbot renew --quiet && systemctl restart nginx"
else
    CRON_CMD="0 0 1 * * /usr/bin/certbot renew --quiet && systemctl restart nginx"
fi
(crontab -l 2>/dev/null; echo "$CRON_CMD") | crontab - || log_info "证书更新计划已存在"
log_success "证书将每月1日自动更新"

# 6. 部署示例Docker应用（可选）
log_info "步骤6/8：部署示例应用（可选）"
read -p "是否部署示例Docker应用？(y/n): " DEPLOY_APP
if [[ "$DEPLOY_APP" == "y" || "$DEPLOY_APP" == "Y" ]]; then
    mkdir -p /opt/app && cd /opt/app
    
    # 生成Docker Compose示例（以Nginx官方测试页面为例）
    cat > docker-compose.yaml << EOF
services:
  web:
    image: nginx:stable
    container_name: ${DOMAIN}-web
    ports:
      - "${APP_PORT}:80"
    volumes:
      - ./html:/usr/share/nginx/html
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

volumes:
  html:
EOF

    # 生成测试页面
    mkdir -p html
    cat > html/index.html << EOF
<!DOCTYPE html>
<html>
<head>
    <title>${DOMAIN} - 反代测试页面</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; margin: 50px; }
        h1 { color: #3498db; }
        p { font-size: 18px; }
        .info { margin-top: 30px; color: #7f8c8d; }
    </style>
</head>
<body>
    <h1>反代部署成功！</h1>
    <p>这是通过Nginx反代访问的Docker应用</p>
    <div class="info">
        <p>域名: ${DOMAIN}</p>
        <p>反代端口: ${APP_PORT}</p>
        <p>当前时间: <span id="current-time"></span></p>
    </div>
    <script>
        document.getElementById('current-time').textContent = new Date().toLocaleString();
    </script>
</body>
</html>
EOF

    # 启动Docker应用
    log_info "启动示例应用..."
    docker compose up -d
    if [ $? -ne 0 ]; then
        log_error "示例应用启动失败，请执行'docker compose logs'查看详情"
    fi
    log_success "示例应用部署完成，可通过http://127.0.0.1:${APP_PORT}测试"
else
    log_info "跳过应用部署，假设后端应用已在${APP_PORT}端口运行"
fi

# 7. 防火墙配置
log_info "步骤7/8：配置防火墙"
if [ "$PACKAGE_MANAGER" == "apt" ]; then
    if command -v ufw &> /dev/null; then
        ufw allow 'Nginx Full' || log_info "UFW已配置或不支持"
        ufw allow 22 || log_info "SSH端口已开放"
        ufw enable || log_info "UFW已启用或不支持"
    else
        log_info "未检测到UFW，跳过防火墙配置"
    fi
else
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-service=https || log_info "HTTPS规则已存在"
        firewall-cmd --permanent --add-service=http || log_info "HTTP规则已存在"
        firewall-cmd --permanent --add-port=${APP_PORT}/tcp || log_info "应用端口规则已存在"
        firewall-cmd --reload || log_error "防火墙重载失败"
    else
        log_info "未检测到firewalld，跳过防火墙配置"
    fi
fi
log_success "防火墙配置完成"

# 8. 完成部署
log_success "Nginx反代网站部署全部完成！"
log_info "重要信息："
log_info "  网站地址：https://${DOMAIN}"
log_info "  后端应用端口：${APP_PORT}"
log_info "  证书路径：${CERT_PATH}"
log_info "  Nginx配置：/etc/nginx/conf.d/${DOMAIN}.conf"

# 验证部署结果
log_info "开始验证部署结果..."
if [[ "$INSTALL_DOCKER" == "y" || "$INSTALL_DOCKER" == "Y" && "$DEPLOY_APP" == "y" || "$DEPLOY_APP" == "Y" ]]; then
    if [ "$(docker compose ps | grep -c "Up")" -ge 1 ]; then
        log_success "Docker应用运行正常"
    else
        log_info "Docker应用状态异常，建议执行'docker compose ps'查看"
    fi
fi

NGINX_STATUS=$(systemctl status nginx | grep "active (running)")
if [ -n "$NGINX_STATUS" ]; then
    log_success "Nginx服务运行正常"
else
    log_error "Nginx服务未正常运行，请执行'systemctl status nginx'检查"
fi

log_success "部署流程结束，现在可以访问https://${DOMAIN}查看网站"
