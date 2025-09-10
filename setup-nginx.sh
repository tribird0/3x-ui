#!/bin/bash

# Ask for user input
read -p "Enter your subdomain (e.g., m.ivanmab.online): " DOMAIN
read -p "Enter your email for SSL certificate: " EMAIL
read -p "Enter 3x-ui panel port (default 8081): " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-8081}
read -p "Enter 3x-ui panel path (default /x0x/): " PANEL_PATH
PANEL_PATH=${PANEL_PATH:-/x0x/}
read -p "Enter V2Ray WS inbound port 1 (default 8443): " WS8443
WS8443=${WS8443:-8443}
read -p "Enter V2Ray WS inbound port 2 (default 8444): " WS8444
WS8444=${WS8444:-8444}

echo "Stopping Nginx..."
systemctl stop nginx

# Backup old configs
echo "Backing up old Nginx configs and SSL..."
mkdir -p ~/nginx-backup
cp -r /etc/nginx/sites-available ~/nginx-backup/sites-available 2>/dev/null
cp -r /etc/nginx/sites-enabled ~/nginx-backup/sites-enabled 2>/dev/null
cp -r /etc/letsencrypt ~/nginx-backup/letsencrypt 2>/dev/null

# Remove old configs
echo "Cleaning old Nginx configs and SSL..."
rm -f /etc/nginx/sites-enabled/* /etc/nginx/sites-available/* /etc/nginx/conf.d/default.conf
rm -rf /etc/letsencrypt/live/$DOMAIN /etc/letsencrypt/archive/$DOMAIN /etc/letsencrypt/renewal/$DOMAIN.conf

# Create new Nginx config
echo "Creating new Nginx reverse proxy config..."
cat > /etc/nginx/sites-available/3x-ui.conf <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # 3x-ui Admin Panel
    location $PANEL_PATH {
        proxy_pass http://127.0.0.1:$PANEL_PORT$PANEL_PATH;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # V2Ray WS inbound $WS8443
    location /ws$WS8443 {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$WS8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    # V2Ray WS inbound $WS8444
    location /ws$WS8444 {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$WS8444;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

# Enable the site
ln -s /etc/nginx/sites-available/3x-ui.conf /etc/nginx/sites-enabled/

# Install Certbot if not installed
echo "Installing Certbot..."
apt update
apt install -y certbot python3-certbot-nginx

# Issue SSL certificate
echo "Issuing SSL certificate..."
certbot --nginx -d $DOMAIN --redirect --agree-tos --no-eff-email -m $EMAIL

# Test and restart Nginx
echo "Testing Nginx config..."
nginx -t

echo "Restarting Nginx..."
systemctl restart nginx

echo "✅ Setup completed!"
echo "Admin Panel: https://$DOMAIN$PANEL_PATH"
echo "V2Ray WS$WS8443: wss://$DOMAIN/ws$WS8443"
echo "V2Ray WS$WS8444: wss://$DOMAIN/ws$WS8444"
echo "TCP/TLS VLESS 443 and Shadowsocks remain unchanged."
