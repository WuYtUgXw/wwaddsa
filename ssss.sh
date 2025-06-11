#!/bin/bash
set -e  # 任何命令失败立即终止脚本

# ==================== 配置区 ====================
DOMAIN="rtx.sly666.xyz"
EMAIL="admin@example.com"  # 替换为你的邮箱
APP_DIR="/opt/deploy-dash"
LOG_DIR="/var/log/deploy-dash"

# Auth 密钥（从你的问题中提取）
cat > $APP_DIR/.env <<EOF
NEXT_PUBLIC_STACK_PROJECT_ID=a9842990-fc88-4a3e-a0ed-ee7ec0c9dd27
NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY=pck_24nn23tvpmne289pdz62xfy4b9tx1sqnmpkcww2n74rc8
STACK_SECRET_SERVER_KEY=ssk_1gjt814kznam5hrybej005z3wxkn7tqwxcp4rf8xjj5tr
EOF

# ==================== 初始化系统 ====================
echo "🛠️ 正在初始化系统..."
apt update && apt upgrade -y
apt install -y git curl nginx python3 python3-pip nodejs npm certbot python3-certbot-nginx

# 安装 Node.js 18（确保版本兼容）
curl -fsSL https://deb.nodesource.com/setup_18.x | bash -
apt install -y nodejs

# 安装 PM2 进程管理器
npm install -g pm2
pm2 startup systemd -u $(whoami) --hp /home/$(whoami)

# ==================== 部署应用 ====================
echo "🚀 正在部署应用..."
mkdir -p $APP_DIR $LOG_DIR
git clone https://github.com/relayx/deploy-dash.git $APP_DIR
cd $APP_DIR

# 安装前端依赖
cd frontend
npm install --legacy-peer-deps
npm run build

# 安装后端依赖
cd ../backend
python3 -m pip install virtualenv
virtualenv venv
source venv/bin/activate
pip install -r requirements.txt
deactivate

# ==================== 配置 Nginx ====================
echo "🔌 配置 Nginx..."
cat > /etc/nginx/sites-available/deploy-dash <<EOF
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

ln -sf /etc/nginx/sites-available/deploy-dash /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# ==================== HTTPS 配置 ====================
echo "🔐 配置 HTTPS..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
systemctl restart nginx

# ==================== 启动服务 ====================
echo "⚡ 启动服务..."

# 前端服务 (PM2)
cd $APP_DIR/frontend
pm2 start "npm run start -- -p 3000" --name deploy-dash-frontend \
    --log $LOG_DIR/frontend.log --time

# 后端服务 (Systemd)
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

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now deploy-dash-backend

# ==================== 完成 ====================
echo "✅ 部署完成！"
echo "访问地址: https://$DOMAIN"
echo "监控日志:"
echo "前端: pm2 logs deploy-dash-frontend"
echo "后端: journalctl -u deploy-dash-backend -f"
