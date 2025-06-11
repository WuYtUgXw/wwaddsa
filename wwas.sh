#!/bin/bash

# ====================== 基础配置 ======================
DOMAIN="rtx.sly666.xyz"  # 替换为你的域名
EMAIL="admin@${DOMAIN}"  # 用于 Certbot 申请 SSL 证书

# Auth 环境变量（从你的问题中提取）
AUTH_VARS=(
  "NEXT_PUBLIC_STACK_PROJECT_ID=a9842990-fc88-4a3e-a0ed-ee7ec0c9dd27"
  "NEXT_PUBLIC_STACK_PUBLISHABLE_CLIENT_KEY=pck_24nn23tvpmne289pdz62xfy4b9tx1sqnmpkcww2n74rc8"
  "STACK_SECRET_SERVER_KEY=ssk_1gjt814kznam5hrybej005z3wxkn7tqwxcp4rf8xjj5tr"
)

# ====================== 1. 系统更新 & 依赖安装 ======================
echo "🔄 更新系统并安装依赖..."
apt update && apt upgrade -y
apt install -y git curl nginx python3 python3-pip nodejs npm certbot python3-certbot-nginx

# ====================== 2. 安装 Docker（如需数据库） ======================
echo "🐳 安装 Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# ====================== 3. 克隆项目代码 ======================
echo "📦 克隆 RelayX Deploy Dash..."
git clone https://github.com/relayx/deploy-dash.git
cd deploy-dash

# ====================== 4. 配置环境变量 ======================
echo "🔑 写入 Auth 环境变量到 .env 文件..."
for var in "${AUTH_VARS[@]}"; do
  echo "$var" >> .env
done

# ====================== 5. 前端构建 ======================
echo "🛠️ 构建前端 (Next.js)..."
cd frontend
npm install --legacy-peer-deps
npm run build
cd ..

# ====================== 6. 后端依赖安装 ======================
echo "🐍 安装 Python 依赖..."
cd backend
python3 -m pip install --upgrade pip
pip3 install -r requirements.txt
cd ..

# ====================== 7. 配置 Nginx 反代 ======================
echo "🔌 配置 Nginx 反代..."
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

ln -s /etc/nginx/sites-available/deploy-dash /etc/nginx/sites-enabled/
nginx -t && systemctl restart nginx

# ====================== 8. 申请 SSL 证书（HTTPS） ======================
echo "🔐 申请 SSL 证书..."
if [ -n "$(command -v certbot)" ]; then
  certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
  systemctl restart nginx
fi

# ====================== 9. 启动后端服务（Gunicorn） ======================
echo "🚀 启动后端 (Gunicorn)..."
cd backend
gunicorn -w 4 -b 127.0.0.1:8000 app:app --daemon
cd ..

# ====================== 10. 启动前端服务（Next.js） ======================
echo "🌐 启动前端 (Next.js)..."
cd frontend
npm run start -- --port 3000 --hostname 0.0.0.0 &> /var/log/deploy-dash-frontend.log &
cd ..

# ====================== 完成！ ======================
echo "✅ 部署完成！访问以下地址："
echo "   - HTTP:  http://$DOMAIN"
echo "   - HTTPS: https://$DOMAIN"
