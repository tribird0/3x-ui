#!/bin/bash

# Color definitions
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
blue='\033[0;34m'
plain='\033[0m'

# Check if running as root
[[ $EUID -ne 0 ]] && echo -e "${red}Error:${plain} This script must be run as root!" && exit 1

# Detect OS release
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
else
    echo -e "${red}Unsupported OS. This script supports Ubuntu/Debian/CentOS.${plain}"
    exit 1
fi

echo -e "${blue}Detected OS: ${OS}${plain}"

# Function to print status
print_info() {
    echo -e "${blue}ℹ️  $1${plain}"
}

print_success() {
    echo -e "${green}✅ $1${plain}"
}

print_warning() {
    echo -e "${yellow}⚠️  $1${plain}"
}

print_error() {
    echo -e "${red}❌ $1${plain}"
}

# Step 1: Update & Upgrade
print_info "Updating system packages..."
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget sudo gnupg lsb-release
print_success "System updated and basic tools installed."

# Step 2: Install x-ui
print_info "Installing x-ui panel..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
if [[ $? -ne 0 ]]; then
    print_error "Failed to install x-ui. Aborting."
    exit 1
fi
print_success "x-ui installed successfully."

# Step 3: Install Nginx, Certbot, UFW/firewalld
print_info "Installing Nginx, Certbot, and firewall..."
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get install -y nginx software-properties-common certbot python3-certbot-nginx ufw
elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
    yum -y install epel-release || dnf -y install epel-release
    yum -y install nginx certbot python3-certbot-nginx firewalld
    systemctl enable firewalld --now
else
    print_error "Unsupported OS for package installation."
    exit 1
fi

# Step 4: Configure Firewall
print_info "Configuring firewall..."
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    ufw allow ssh
    ufw allow http
    ufw allow https
    ufw --force enable
    print_success "UFW firewall enabled (ports 22, 80, 443)."
elif [[ "$OS" == "centos" || "$OS" == "almalinux" || "$OS" == "rocky" ]]; then
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload
    print_success "Firewalld configured (HTTP, HTTPS, SSH)."
fi

# Step 5: Prompt user for domain and email
print_info "Please enter your configuration:"
read -p "📧 Email for Let's Encrypt: " user_email
read -p "🌐 Subdomain (e.g., xui.yourdomain.com): " subdomain
read -p "🔧 x-ui Panel Port (e.g., 8443): " panel_port
read -p "🔗 Panel WebBasePath (e.g., secret-panel): " web_path

# Validate input
if [[ -z "$user_email" || -z "$subdomain" || -z "$panel_port" || -z "$web_path" ]]; then
    print_error "Email, domain, port, and path are required!"
    exit 1
fi

# Validate port
if ! [[ "$panel_port" =~ ^[0-9]+$ ]] || [[ "$panel_port" -lt 1024 || "$panel_port" -gt 65535 ]]; then
    print_error "Port must be between 1024 and 65535."
    exit 1
fi

# Check domain resolves
server_ip=$(curl -s https://api.ipify.org)
domain_ip=$(dig +short "$subdomain" | tail -n1)
if [[ -n "$domain_ip" && "$server_ip" != "$domain_ip" ]]; then
    print_warning "Domain $subdomain resolves to $domain_ip, not $server_ip"
    read -rp "Continue anyway? [y/N]: " confirm
    [[ ! "$confirm" =~ ^[Yy]$ ]] && exit 1
fi

# Step 6: Obtain SSL Certificate
print_info "Obtaining SSL certificate for $subdomain..."
certbot --nginx \
    --agree-tos \
    --email "$user_email" \
    -d "$subdomain" \
    --non-interactive \
    --redirect

if [[ $? -ne 0 ]]; then
    print_error "Failed to obtain SSL certificate. Check DNS."
    exit 1
fi
print_success "SSL certificate issued successfully."

# Test renewal
certbot renew --dry-run > /dev/null 2>&1 && \
    print_success "Certificate renewal test passed." || \
    print_warning "Renewal test failed. Will retry later."

# Step 7: Configure x-ui Port & WebBasePath
print_info "Configuring x-ui settings..."
/usr/local/x-ui/x-ui setting -port "$panel_port" -webBasePath "/$web_path"
systemctl restart x-ui
print_success "x-ui configured: Port=$panel_port, Path=/$web_path"

# Step 8: Nginx Reverse Proxy Config
nginx_config="/etc/nginx/sites-available/x-ui"
cat > "$nginx_config" << EOF
server {
    listen 80;
    server_name $subdomain;
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name $subdomain;

    ssl_certificate /etc/letsencrypt/live/$subdomain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$subdomain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384;

    location /$web_path {
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$panel_port;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Redirect root to prevent exposure
    location = / {
        return 301 https://\$server_name/$web_path;
    }
}
EOF

# Enable site
ln -sf "$nginx_config" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default >/dev/null 2>&1

# Test Nginx config
print_info "Testing Nginx configuration..."
nginx -t
if [[ $? -ne 0 ]]; then
    print_error "Nginx configuration test failed!"
    exit 1
fi

systemctl reload nginx
print_success "Nginx reverse proxy configured and reloaded."

# Step 9: Finalize x-ui
systemctl daemon-reload
systemctl enable x-ui
systemctl restart x-ui

# Step 10: Auto-renew SSL
(crontab -l 2>/dev/null | grep -v "certbot renew") | crontab -
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
print_success "SSL auto-renewal scheduled via cron."

# Final Output
echo
echo -e "${green}🎉 x-ui Installation Complete!${plain}"
echo
echo -e "🔐 ${blue}Access Panel:${plain} ${green}https://$subdomain/$web_path${plain}"
echo -e "👤 ${blue}Default Login:${plain} ${yellow}admin${plain} / ${yellow}admin${plain}"
echo -e "⚙️  ${blue}Local Port:${plain} $panel_port"
echo
echo -e "${yellow}💡 Next Steps:${plain}"
echo -e "   1. Open ${green}https://$subdomain/$web_path${plain} in your browser"
echo -e "   2. Log in and run ${yellow}x-ui${plain} to change username/password"
echo -e "   3. Set additional security (2FA, Fail2Ban)"
echo -e "   4. Monitor logs: ${yellow}x-ui log${plain}"
echo
print_info "Firewall status:"
if [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    ufw status | grep -E "22|80|443"
else
    firewall-cmd --list-services
fi
