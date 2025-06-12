#!/bin/bash

# 服务器环境一键修复脚本
# 适用于Nginx + Node.js/Next.js环境

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
FRONTEND_PATH="/var/www/relayx"  # 前端项目路径
NGINX_CONFIG="/etc/nginx/nginx.conf"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available/default"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled/default"
UPSTREAM_PORT=3000  # 上游服务端口
UPSTREAM_NAME="app_server"
BACKUP_DIR="/root/nginx_backup_$(date +%Y%m%d_%H%M%S)"

# 创建备份目录
mkdir -p $BACKUP_DIR
log_info "创建备份目录: $BACKUP_DIR"

# 备份现有配置
log_info "备份当前Nginx配置..."
cp $NGINX_CONFIG $BACKUP_DIR/nginx.conf.bak
if [ -f "$NGINX_SITES_AVAILABLE" ]; then
    cp $NGINX_SITES_AVAILABLE $BACKUP_DIR/sites_available_default.bak
fi
if [ -f "$NGINX_SITES_ENABLED" ]; then
    cp $NGINX_SITES_ENABLED $BACKUP_DIR/sites_enabled_default.bak
fi

# 检查并安装必要工具
log_info "检查必要工具..."
apt-get update -y
apt-get install -y nginx nodejs npm curl

# 检查前端项目目录
if [ ! -d "$FRONTEND_PATH" ]; then
    log_error "前端项目目录不存在: $FRONTEND_PATH"
    read -p "请输入正确的前端项目路径: " FRONTEND_PATH
    if [ ! -d "$FRONTEND_PATH" ]; then
        log_error "路径仍然无效，无法继续"
        exit 1
    fi
fi

# 构建前端项目
log_info "开始构建前端项目..."
cd $FRONTEND_PATH
if [ -f "package.json" ]; then
    log_info "安装项目依赖..."
    npm install || { log_error "npm安装依赖失败"; exit 1; }
    
    log_info "构建项目..."
    if grep -q "next" package.json; then
        npm run build || { log_error "Next.js项目构建失败"; exit 1; }
    else
        npm run build || { log_error "项目构建失败"; exit 1; }
    fi
else
    log_error "未找到package.json文件，无法构建项目"
    exit 1
fi

# 部署前端资源到Nginx目录
log_info "部署前端资源到Nginx目录..."
NGINX_HTML="/usr/share/nginx/html"
mkdir -p $NGINX_HTML
rm -rf $NGINX_HTML/*

if [ -d "$FRONTEND_PATH/.next" ]; then
    # Next.js项目部署
    log_info "检测到Next.js项目，配置相应的Nginx代理..."
    mkdir -p $NGINX_HTML/_next/static
    cp -r $FRONTEND_PATH/.next/static/* $NGINX_HTML/_next/static/
    cp -r $FRONTEND_PATH/public/* $NGINX_HTML/ 2>/dev/null
else
    # 普通静态项目部署
    cp -r $FRONTEND_PATH/dist/* $NGINX_HTML/ 2>/dev/null || \
    cp -r $FRONTEND_PATH/build/* $NGINX_HTML/ 2>/dev/null || \
    cp -r $FRONTEND_PATH/out/* $NGINX_HTML/ 2>/dev/null || \
    { log_error "未找到构建输出目录，请检查项目构建配置"; exit 1; }
fi

# 创建默认错误页面
mkdir -p $NGINX_HTML/error
cat > $NGINX_HTML/error/50x.html << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>500 Internal Server Error</title>
    <style>
        body { font-family: Arial, sans-serif; text-align: center; margin: 50px; }
        h1 { color: #ff3333; }
    </style>
</head>
<body>
    <h1>500 Internal Server Error</h1>
    <p>The server encountered an internal error and was unable to complete your request.</p>
</body>
</html>
EOF

# 配置Nginx
log_info "配置Nginx..."

# 创建基本的Nginx配置文件
cat > $NGINX_SITES_AVAILABLE << EOF
# 上游服务配置
upstream $UPSTREAM_NAME {
    server 127.0.0.1:$UPSTREAM_PORT;
    keepalive 64;
}

server {
    listen 80;
    server_name _;
    
    # 静态文件处理
    location /_next/static/ {
        alias $NGINX_HTML/_next/static/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
    
    location /static/ {
        alias $NGINX_HTML/static/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }
    
    # 错误页面
    error_page 500 502 503 504 /error/50x.html;
    location = /error/50x.html {
        root $NGINX_HTML;
        internal;
    }
    
    # 所有其他请求转发到上游服务
    location / {
        proxy_pass http://$UPSTREAM_NAME;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# 启用配置
ln -sf $NGINX_SITES_AVAILABLE $NGINX_SITES_ENABLED

# 启动/重启Nginx
log_info "重启Nginx服务..."
nginx -t || { log_error "Nginx配置测试失败，请检查配置文件"; exit 1; }
systemctl restart nginx
systemctl enable nginx

# 启动Node.js服务（假设使用PM2管理）
log_info "安装并配置PM2..."
npm install -g pm2

log_info "启动应用服务..."
cd $FRONTEND_PATH
if grep -q "next" package.json; then
    pm2 start "npm run start" --name "next-app" || { log_error "启动Next.js服务失败"; exit 1; }
else
    pm2 start "npm run start" --name "node-app" || { log_error "启动Node.js服务失败"; exit 1; }
fi

# 保存PM2进程列表
pm2 save

# 设置PM2开机自启
pm2 startup systemd

# 检查服务状态
log_info "检查服务状态..."
systemctl status nginx
pm2 list

log_info "修复完成！"
log_info "备份已保存到: $BACKUP_DIR"
log_info "前端项目路径: $FRONTEND_PATH"
log_info "Nginx配置: $NGINX_SITES_AVAILABLE"
