#!/bin/bash

# Color definitions
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
plain='\033[0m'

# Check root
[[ $EUID -ne 0 ]] && echo -e "${red}Error:${plain} This script must be run as root!" && exit 1

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${red}Error:${plain} Cannot detect OS."
    exit 1
fi
echo -e "${blue}OS Detected: $OS${plain}"

# Helper functions
print_info() { echo -e "${blue}ℹ️  $1${plain}"; }
print_success() { echo -e "${green}✅ $1${plain}"; }
print_warning() { echo -e "${yellow}⚠️  $1${plain}"; }
print_error() { echo -e "${red}❌ $1${plain}"; }

# Update system
print_info "Updating system..."
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget sudo lsb-release gnupg tar tzdata
print_success "System updated."

# Install x-ui
print_info "Installing x-ui panel..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
if [[ $? -ne 0 ]]; then
    print_error "Failed to install x-ui."
    exit 1
fi
print_success "x-ui installed."

# Install Nginx, Certbot
print_info "Installing Nginx and Certbot..."
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get install -y nginx certbot python3-certbot-nginx
elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
    yum -y install epel-release
    yum -y install nginx certbot python3-certbot-nginx
else
    apt-get install -y nginx certbot
fi

# Configure firewall
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get install -y ufw
    ufw allow ssh && ufw allow http && ufw allow https && ufw --force enable
    print_success "UFW firewall enabled."
elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
    systemctl enable firewalld --now
    firewall-cmd --permanent --add-service={http,https,ssh}
    firewall-cmd --reload
    print_success "Firewalld configured."
fi

# User Input
print_info "Please provide your details:"
read -p "🌐 Domain or subdomain (e.g., xui.yourdomain.com): " domain
read -p "📧 Email for Let's Encrypt: " email
read -p "🔧 x-ui Panel Port (e.g., 2053): " panel_port
read -p "🔗 x-ui WebBasePath (e.g., panel): " web_path
read -p "🤖 Telegram Bot Token (e.g., 123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11): " tg_token
read -p "👤 Telegram Admin Chat ID (e.g., 123456789): " tg_chat_id

# Validate inputs
if [[ -z "$domain" || -z "$email" || -z "$panel_port" || -z "$web_path" || -z "$tg_token" || -z "$tg_chat_id" ]]; then
    print_error "All fields are required!"
    exit 1
fi

# Validate port
if ! [[ "$panel_port" =~ ^[0-9]+$ ]] || [[ "$panel_port" -lt 1024 || "$panel_port" -gt 65535 ]]; then
    print_error "Panel port must be between 1024 and 65535."
    exit 1
fi

# Check domain resolves
server_ip=$(curl -s https://api.ipify.org)
domain_ip=$(dig +short "$domain" | tail -n1)
if [[ "$server_ip" != "$domain_ip" ]]; then
    print_warning "Domain $domain resolves to $domain_ip, not $server_ip"
    read -rp "Continue anyway? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
fi

# Set x-ui port and webBasePath
print_info "Configuring x-ui settings..."
/usr/local/x-ui/x-ui setting -port "$panel_port" -webBasePath "/$web_path"
systemctl restart x-ui
print_success "x-ui configured: Port=$panel_port, Path=/$web_path"

# Create webroot
mkdir -p /var/www/certbot

# Nginx config for x-ui
nginx_conf="/etc/nginx/sites-available/x-ui"
cat > "$nginx_conf" << EOF
server {
    listen 80;
    server_name $domain;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $domain;

    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;

    location /$web_path {
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$panel_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# Enable Nginx site
ln -sf "$nginx_conf" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default >/dev/null 2>&1

# Test Nginx
nginx -t > /dev/null 2>&1 || { print_error "Nginx config test failed."; exit 1; }
systemctl reload nginx
print_success "Nginx configured."

# Obtain SSL certificate
print_info "Obtaining SSL certificate for $domain..."
certbot certonly --webroot -w /var/www/certbot \
    --email "$email" \
    --agree-tos \
    --no-eff-email \
    -d "$domain" \
    --non-interactive

if [[ $? -ne 0 ]]; then
    print_error "Failed to obtain SSL certificate. Check DNS."
    exit 1
fi
print_success "SSL certificate issued."

# Reload Nginx again after cert
systemctl reload nginx

# Wait for x-ui to be ready
sleep 5

# === PRE-ADD INBOUNDS ===

# 1. VLESS (port 443, TLS, uses domain)
print_info "Adding VLESS inbound on port 443..."
response=$(curl -s -X POST http://127.0.0.1:$panel_port/$web_path/panel/inbound/add \
-H "Content-Type: application/json" \
-d '{
  "up": 0,
  "down": 0,
  "total": 0,
  "remark": "VLESS-TLS-443",
  "enable": true,
  "expiryTime": 0,
  "listen": "",
  "port": 443,
  "protocol": "vless",
  "settings": "{\"clients\":[],\"decryption\":\"none\",\"fallbacks\":[]}",
  "streamSettings": "{\"network\":\"tcp\",\"security\":\"tls\",\"tlsSettings\":{\"certificates\":[{\"certificateFile\":\"/etc/letsencrypt/live/'$domain'/fullchain.pem\",\"keyFile\":\"/etc/letsencrypt/live/'$domain'/privkey.pem\"}]}}",
  "sniffing": {"enabled": true, "destOverride": ["http", "tls"]}
}')

if echo "$response" | grep -q "success"; then
    print_success "VLESS inbound added on port 443 (TLS)."
else
    print_warning "Failed to add VLESS inbound (response: $response)"
fi

# 2. Shadowsocks (port 3308, CHACHA20_IETF_POLY1305)
print_info "Adding Shadowsocks inbound on port 3308..."
ss_password=$(openssl rand -base64 12 | tr -d "=+/" | cut -c1-12)
response=$(curl -s -X POST http://127.0.0.1:$panel_port/$web_path/panel/inbound/add \
-H "Content-Type: application/json" \
-d '{
  "up": 0,
  "down": 0,
  "total": 0,
  "remark": "SS-CHACHA20-3308",
  "enable": true,
  "expiryTime": 0,
  "listen": "",
  "port": 3308,
  "protocol": "shadowsocks",
  "settings": "{\"clients\":[{\"password\":\"'$ss_password'\"}],\"method\":\"chacha20-ietf-poly1305\"}",
  "streamSettings": "{\"network\":\"tcp\"}",
  "sniffing": {"enabled": false}
}')

if echo "$response" | grep -q "success"; then
    print_success "Shadowsocks inbound added on port 3308."
    print_info "Shadowsocks Password: $ss_password"
    print_info "Use with method: CHACHA20-IETF-POLY1305"
else
    print_warning "Failed to add Shadowsocks inbound (response: $response)"
fi

# === ENABLE TELEGRAM BOT ===
print_info "Enabling Telegram Bot..."
bot_response=$(curl -s -X POST http://127.0.0.1:$panel_port/$web_path/panel/setting/telegram \
-H "Content-Type: application/json" \
-d '{
  "enable": true,
  "token": "'$tg_token'",
  "chat_id": "'$tg_chat_id'"
}')

if echo "$bot_response" | grep -q "success"; then
    print_success "Telegram Bot enabled."
else
    print_warning "Failed to enable Telegram Bot (response: $bot_response)"
fi

# Auto-renew SSL
(crontab -l 2>/dev/null | grep -v "certbot renew") || echo "" | crontab -
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
print_success "Certbot auto-renewal configured."

# Final message
echo
echo -e "${green}🎉 x-ui Installation Complete!${plain}"
echo
echo -e "🔐 ${blue}Panel URL:${plain} ${green}https://$domain/$web_path${plain}"
echo -e "👤 ${blue}Default Login:${plain} ${yellow}admin${plain} / ${yellow}admin${plain}"
echo
echo -e "🔌 ${blue}Pre-Added Inbounds:${plain}"
echo -e "   🌐 VLESS: port 443 (TLS, uses domain cert)"
echo -e "   🔐 Shadowsocks: port 3308, password: ${yellow}$ss_password${plain}"
echo
echo -e "🤖 ${blue}Telegram Bot:${plain} Enabled (Chat ID: $tg_chat_id)"
echo -e "💡 Use /help in bot to see commands"
echo
echo -e "${yellow}💡 Next Steps:${plain}"
echo -e "   1. Change panel login: run ${yellow}x-ui${plain}"
echo -e "   2. Create users in 'Inbounds' tab"
echo -e "   3. Monitor: ${yellow}x-ui log${plain}"
echo
print_info "Firewall status:"
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    ufw status | grep -E "22|80|443|3308"
else
    firewall-cmd --list-ports | grep -E "443|3308" || firewall-cmd --list-services | grep https
fi
