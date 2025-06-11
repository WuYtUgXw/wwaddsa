#!/bin/bash
# Relayx平台Debian系统完整部署脚本 - 基于提供的Auth参数
# 最后更新：2025-06-12

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # 恢复默认颜色

# 检查root权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}[错误] 请使用root权限运行：sudo bash $0${NC}"
    exit 1
fi

# 检查Debian系统
if ! grep -q "Debian" /etc/os-release; then
    echo -e "${RED}[错误] 仅支持Debian系统（检测到非Debian系统）${NC}"
    exit 1
fi

# 显示欢迎信息
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}         Relayx平台一键部署工具 v1.2          ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}[提示] 此脚本将自动完成：${NC}"
echo -e "  1. 环境准备（Docker/Nginx/certbot）"
echo -e "  2. Relayx服务部署（Docker Compose）"
echo -e "  3. Nginx反代配置（含HTTPS）"
echo -e "  4. 防火墙配置（ufw）"
echo -e "${YELLOW}[注意] 请确保：${NC}"
echo -e "  • 域名 rtx.sly666.xyz 已解析到当前服务器IP"
echo -e "  • 服务器能访问外网（用于申请证书）"
echo -e "${GREEN}==============================================${NC}"

# 1. 环境准备
echo -e "${YELLOW}[步骤1/6] 准备系统环境...${NC}"
apt-get update -y
apt-get install -y curl nginx docker.io docker-compose certbot python3-certbot-nginx ufw git

# 检查依赖安装
for cmd in docker nginx certbot; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}[错误] $cmd 安装失败，请检查网络${NC}"
        exit 1
    fi
done

# 2. 配置防火墙
echo -e "${YELLOW}[步骤2/6] 配置防火墙...${NC}"
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 'Nginx Full'
ufw --force enable
echo -e "${GREEN}[成功] 防火墙配置完成${NC}"

# 3. 部署Relayx服务
echo -e "${YELLOW}[步骤3/6] 部署Relayx服务...${NC}"
RELAYX_DIR="/opt/relayx"
mkdir -p $RELAYX_DIR && cd $RELAYX_DIR

# 生成Docker Compose配置
cat > docker-compose.yaml << 'EOF'
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
    depends_on:
      - relayx
    ports:
      - "3000:3000"

  redis:
    image: redis
    container_name: redis
    restart: always
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  mysql:
    image: mysql:8.0
    container_name: mysql
    environment:
      MYSQL_ROOT_PASSWORD: relayx123
      MYSQL_DATABASE: relayx
    restart: always
    volumes:
      - mysql-data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 5s
      timeout: 5s
      retries: 5

volumes:
  redis-data:
  mysql-data:
EOF

# 生成环境变量文件（使用提供的Auth参数）
cat > .env << EOF
DATABASE_URL="mysql://root:relayx123@mysql:3306/relayx"
REDIS_URL="redis://redis:6379"
SITE_URL="https://rtx.sly666.xyz"
STACK_API_URL="https://api.stack-auth.com"
STACK_PROJECT_ID="a9842990-fc88-4a3e-a0ed-ee7ec0c9dd27"
STACK_SECRET_SERVER_KEY="ssk_1gjt814kznam5hrybej005z3wxkn7tqwxcp4rf8xjj5tr"
STACK_PUBLISHABLE_CLIENT_KEY="pck_24nn23tvpmne289pdz62xfy4b9tx1sqnmpkcww2n74rc8"
TELEGRAM_BOT_TOKEN="your_telegram_bot_token"
API_URL="http://relayx:3000"
EOF

# 启动服务
echo -e "${YELLOW}[信息] 启动Relayx服务，可能需要2-3分钟...${NC}"
docker-compose up -d

# 检查服务启动状态
sleep 20
if ! docker-compose ps | grep -q "Up"; then
    echo -e "${RED}[错误] Relayx服务启动失败，查看日志：${NC}"
    docker-compose logs
    exit 1
fi
echo -e "${GREEN}[成功] Relayx服务启动完成${NC}"

# 4. 配置Nginx反代
echo -e "${YELLOW}[步骤4/6] 配置Nginx反代...${NC}"
NGINX_CONF="/etc/nginx/sites-available/rtx.sly666.xyz"
cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name rtx.sly666.xyz www.rtx.sly666.xyz;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name rtx.sly666.xyz www.rtx.sly666.xyz;
    
    # SSL证书配置
    ssl_certificate /etc/letsencrypt/live/rtx.sly666.xyz/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/rtx.sly666.xyz/privkey.pem;
    
    # SSL安全配置
    ssl_protocols TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    
    # 反代配置
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_read_timeout 3600s;
    }
}
EOF

# 启用Nginx配置
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
rm /etc/nginx/sites-enabled/default 2>/dev/null

# 检查Nginx配置
nginx -t
if [ $? -ne 0 ]; then
    echo -e "${RED}[错误] Nginx配置错误，请检查：$NGINX_CONF${NC}"
    exit 1
fi

# 重启Nginx
systemctl restart nginx
echo -e "${GREEN}[成功] Nginx反代配置完成${NC}"

# 5. 申请HTTPS证书
echo -e "${YELLOW}[步骤5/6] 申请HTTPS证书...${NC}"
read -p "请输入管理员邮箱（用于HTTPS证书）: " ADMIN_EMAIL

certbot --nginx -d rtx.sly666.xyz -d www.rtx.sly666.xyz --email ${ADMIN_EMAIL} --agree-tos --non-interactive
if [ $? -ne 0 ]; then
    echo -e "${YELLOW}[警告] HTTPS证书申请失败，网站将仅支持HTTP${NC}"
    echo -e "${YELLOW}[提示] 手动申请：certbot --nginx -d rtx.sly666.xyz${NC}"
else
    echo -e "${GREEN}[成功] HTTPS证书申请并配置完成${NC}"
    
    # 配置证书自动续期
    crontab -l > mycron
    echo "0 0 1 * * /usr/bin/certbot renew --quiet && systemctl restart nginx" >> mycron
    crontab mycron
    rm mycron
    echo -e "${GREEN}[成功] 证书自动续期已配置${NC}"
fi

# 6. 完成部署
echo -e "${YELLOW}[步骤6/6] 部署完成！${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}            Relayx平台部署成功！             ${NC}"
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}[访问地址]${NC}"
echo -e "  HTTPS: https://rtx.sly666.xyz"
echo -e "${GREEN}[管理信息]${NC}"
echo -e "  部署目录: ${RELAYX_DIR}"
echo -e "  Nginx配置: ${NGINX_CONF}"
echo -e "  Docker日志: docker-compose logs -f"
echo -e "${GREEN}[重要提示]${NC}"
echo -e "  1. 首次访问可能需要1-2分钟初始化"
echo -e "  2. 请确保域名已正确解析到当前服务器"
echo -e "  3. Telegram Bot Token需在.env中更新"
echo -e "${GREEN}==============================================${NC}"
echo -e "${YELLOW}[操作命令]${NC}"
echo -e "  重启Relayx: cd ${RELAYX_DIR} && docker-compose restart"
echo -e "  重启Nginx: systemctl restart nginx"
echo -e "  查看状态: systemctl status nginx && docker-compose ps"
echo -e "${GREEN}==============================================${NC}"
