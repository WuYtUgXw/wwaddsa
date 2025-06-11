#!/bin/bash
set -e

# ==================== 配置区 ====================
DOMAIN="rtx.sly666.xyz"
EMAIL="admin@example.com"  # 替换为真实邮箱
APP_DIR="/opt/deploy-dash"
LOG_DIR="/var/log/deploy-dash"

# ==================== 环境检查 ====================
echo "🔍 检查系统环境..."

# 只安装缺失的依赖
declare -A REQUIRED_PKGS=(
    ["git"]="git"
    ["curl"]="curl"
    ["nginx"]="nginx"
    ["python3"]="python3"
    ["pip3"]="python3-pip"
    ["node"]="nodejs"
    ["npm"]="npm"
    ["certbot"]="certbot python3-certbot-nginx"
)

for cmd in "${!REQUIRED_PKGS[@]}"; do
    if ! command -v $cmd &> /dev/null; then
        echo "⏳ 安装缺失依赖: ${REQUIRED_PKGS[$cmd]}"
        apt install -y ${REQUIRED_PKGS[$cmd]}
    fi
done

# 检查Node.js版本 (仅当版本<18时升级)
NODE_VERSION=$(node -v | cut -d'.' -f1 | tr -d 'v')
if [ $NODE_VERSION -lt 18 ]; then
    echo "⏳ 升级Node.js到18.x..."
    curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
    apt install -y nodejs
fi

# ==================== 应用部署 ====================
echo "🚀 高效部署应用..."

# 清理旧代码但保留环境
if [ -d "$APP_DIR" ]; then
    echo "♻️ 复用现有目录..."
    cd $APP_DIR
    git reset --hard
    git pull origin main
else
    git clone https://github.com/relayx/deploy-dash.git $APP_DIR
    cd $APP_DIR
fi

# 写入/更新环境变量
cat > $APP_DIR/.env <<EOF
NEXT_PUBLIC_STACK_PROJECT_ID=a9842990-fc88-4a3e-a0ed-ee7ec0c9dd27
NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY=pck_24nn23tvpmne289pdz62xfy4b9tx1sqnmpkcww2n74rc8
STACK_SECRET_SERVER_KEY=ssk_1gjt814kznam5hrybej005z3wxkn7tqwxcp4rf8xjj5tr
EOF

# 前端智能安装 (仅当package.json变化时)
cd frontend
if [ ! -d "node_modules" ] || [ package.json -nt node_modules ]; then
    npm ci --legacy-peer-deps  # 比npm install更快且确定
fi
npm run build

# 后端虚拟环境复用
cd ../backend
if [ ! -d "venv" ]; then
    python3 -m venv venv
fi
source venv/bin/activate
pip install -q -U pip
pip install -q -r requirements.txt
deactivate

# ==================== 服务配置 ====================
echo "⚡ 优化服务配置..."

# 仅当Nginx配置变化时更新
NGINX_CONF="/etc/nginx/sites-available/deploy-dash"
if ! cmp -s <<EOF "$NGINX_CONF"
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
then
    echo "🔄 更新Nginx配置..."
    cat > $NGINX_CONF <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF
    ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
    nginx -t && systemctl reload nginx
fi

# 智能HTTPS证书申请
if [ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
    certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
    systemctl reload nginx
fi

# ==================== 进程管理 ====================
# PM2智能重启
cd $APP_DIR/frontend
pm2 delete deploy-dash-frontend 2>/dev/null || true
pm2 start "npm run start -- -p 3000" --name deploy-dash-frontend --log $LOG_DIR/frontend.log --time
pm2 save --force

# Systemd服务更新
cat > /etc/systemd/system/deploy-dash-backend.service <<EOF
[Unit]
Description=Deploy Dash Backend
After=network.target

[Service]
User=$(whoami)
WorkingDirectory=$APP_DIR/backend
EnvironmentFile=$APP_DIR/.env
ExecStart=$APP_DIR/backend/venv/bin/gunicorn -w 4 -b 127.0.0.1:8000 app:app
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now deploy-dash-backend

echo "✅ 高效部署完成！耗时: $SECONDS秒"
echo "访问: https://$DOMAIN"
