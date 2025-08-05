#!/bin/bash

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# Function to print colored output
print_info() {
    echo -e "${BLUE}ℹ️  $1${PLAIN}"
}

print_success() {
    echo -e "${GREEN}✅ $1${PLAIN}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${PLAIN}"
}

print_error() {
    echo -e "${RED}❌ $1${PLAIN}"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "Please run this script as root."
    exit 1
fi

# Step 1: System Update
print_info "Updating system packages..."
apt-get update -y && apt-get upgrade -y
if [[ $? -eq 0 ]]; then
    print_success "System updated successfully."
else
    print_error "Failed to update system."
    exit 1
fi

# Install curl
print_info "Installing curl..."
apt-get install -y curl
if [[ $? -eq 0 ]]; then
    print_success "Curl installed."
else
    print_error "Failed to install curl."
    exit 1
fi

# Step 2: Install 3x-ui
print_info "Installing 3x-ui panel..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
if [[ $? -eq 0 ]]; then
    print_success "3x-ui installed successfully."
else
    print_error "3x-ui installation failed."
    exit 1
fi

# Step 3: Install Certbot
print_info "Installing Certbot..."
apt-get install -y software-properties-common
add-apt-repository -y ppa:certbot/certbot
apt-get update -y
apt-get install -y certbot
if [[ $? -eq 0 ]]; then
    print_success "Certbot installed."
else
    print_error "Certbot installation failed."
    exit 1
fi

# Step 4: Prompt for user input
read -rp "Enter your email for Let's Encrypt: " EMAIL
if [[ -z "$EMAIL" ]]; then
    print_error "Email is required."
    exit 1
fi

read -rp "Enter your subdomain (e.g., xui.example.com): " SUBDOMAIN
if [[ -z "$SUBDOMAIN" ]]; then
    print_error "Subdomain is required."
    exit 1
fi

# Step 5: Obtain SSL Certificate
print_info "Obtaining SSL certificate for $SUBDOMAIN..."
certbot certonly --standalone --preferred-challenges http --agree-tos --email "$EMAIL" -d "$SUBDOMAIN" --non-interactive
if [[ $? -eq 0 ]]; then
    print_success "SSL certificate obtained successfully."
else
    print_error "Failed to obtain SSL certificate. Is port 80 accessible and domain pointing to this server?"
    exit 1
fi

# Test renewal
print_info "Testing certificate renewal..."
certbot renew --dry-run
if [[ $? -eq 0 ]]; then
    print_success "Certificate renewal test passed."
else
    print_warning "Certificate renewal test failed. Check configuration later."
fi

# Step 6: Install and Configure Nginx
print_info "Installing Nginx..."
apt-get install -y nginx
if [[ $? -eq 0 ]]; then
    print_success "Nginx installed."
else
    print_error "Nginx installation failed."
    exit 1
fi

# Get 3x-ui port (default is usually 2053 or read from config)
XUI_PORT=$(x-ui settings -show true 2>/dev/null | grep -oP 'port: \K[0-9]+')
if [[ -z "$XUI_PORT" ]]; then
    XUI_PORT=2053  # fallback
fi

# Create Nginx site configuration
NGINX_CONF="/etc/nginx/sites-available/xui"
cat > "$NGINX_CONF" << EOF
server {
    listen 80;
    server_name $SUBDOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $SUBDOMAIN;

    ssl_certificate /etc/letsencrypt/live/$SUBDOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SUBDOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:$XUI_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# Enable site
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test Nginx config
nginx -t
if [[ $? -eq 0 ]]; then
    systemctl reload nginx
    print_success "Nginx configured and reloaded."
else
    print_error "Nginx configuration test failed. Check syntax."
    exit 1
fi

# Step 7: Finalize x-ui service
print_info "Starting and enabling x-ui..."
x-ui start
x-ui enable
x-ui update
x-ui restart

systemctl daemon-reload

# Final URL
print_success "✅ Installation completed!"
echo
echo -e "${GREEN}🔐 Access your x-ui panel securely at:${PLAIN}"
echo -e "${BLUE}https://$SUBDOMAIN${PLAIN}"
echo
echo -e "${YELLOW}💡 Run 'x-ui' to manage the panel.${PLAIN}"
echo -e "${YELLOW}💡 SSL certificates auto-renew via Certbot (cron job).${PLAIN}"
