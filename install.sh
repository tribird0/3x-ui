#!/bin/bash

# Color definitions
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
plain='\033[0m'

# Check if running as root
[[ $EUID -ne 0 ]] && echo -e "${red}Error:${plain} This script must be run as root!" && exit 1

# Update & Upgrade System
echo -e "${green}Updating system packages...${plain}"
apt-get update -y
apt-get upgrade -y

# Install curl
echo -e "${green}Installing curl...${plain}"
apt-get install -y curl

# Install x-ui
echo -e "${green}Installing x-ui panel...${plain}"
bash <(curl -Ls https://raw.githubusercontent.com/vaxilu/x-ui/master/install.sh)

# Install required tools
echo -e "${green}Installing Nginx, Certbot, and UFW...${plain}"
apt-get install -y nginx software-properties-common certbot python3-certbot-nginx ufw

# Configure Firewall (UFW)
echo -e "${green}Configuring UFW firewall...${plain}"
ufw allow ssh
ufw allow http
ufw allow https
ufw allow 8081    # Default x-ui port – change if you use another
# If you want to allow a custom port, replace 8081 or add another:
# ufw allow <your-custom-port>

# Enable UFW only if not already active
echo -e "${yellow}Enabling UFW firewall...${plain}"
ufw --force enable
echo -e "${green}Firewall (UFW) enabled: Allowed SSH, HTTP, HTTPS, and port 8081${plain}"

# Prompt user for email and subdomain
echo -e "${yellow}Please enter your details:${plain}"
read -p "Email address (for Let's Encrypt): " user_email
read -p "Domain or subdomain (e.g., panel.yourdomain.com): " subdomain

# Validate input
if [[ -z "$user_email" || -z "$subdomain" ]]; then
  echo -e "${red}Error: Email or domain cannot be empty!${plain}"
  exit 1
fi

# Obtain SSL certificate using Certbot with Nginx plugin
echo -e "${green}Obtaining SSL certificate for $subdomain...${plain}"
certbot --nginx \
  --agree-tos \
  --email "$user_email" \
  -d "$subdomain" \
  --non-interactive \
  --redirect

if [[ $? -ne 0 ]]; then
  echo -e "${red}Failed to obtain SSL certificate. Check domain DNS and try again.${plain}"
  exit 1
fi

echo -e "${green}SSL certificate obtained successfully!${plain}"

# Test certificate renewal
echo -e "${green}Testing certificate renewal...${plain}"
certbot renew --dry-run
if [[ $? -eq 0 ]]; then
  echo -e "${green}Certificate renewal test passed${plain}"
else
  echo -e "${yellow}Renewal test failed, but may work later${plain}"
fi

# Configure x-ui to run on port 8081 (or change if needed)
echo -e "${green}Configuring x-ui to run on port 8081...${plain}"
/usr/local/x-ui/x-ui setting -port 8081 > /dev/null 2>&1 || {
  echo -e "${red}Failed to set x-ui port. You may need to configure it manually via 'x-ui' command.${plain}"
}

# Setup Nginx reverse proxy manually (in case certbot auto-config isn't enough)
nginx_config="/etc/nginx/sites-available/x-ui"
cat > "$nginx_config" << EOF
server {
    listen 80;
    server_name $subdomain;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $subdomain;

    ssl_certificate /etc/letsencrypt/live/$subdomain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$subdomain/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Range \$http_range;
        proxy_set_header If-Range \$http_if_range;
        proxy_redirect off;
        proxy_pass http://127.0.0.1:8081;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF

# Enable Nginx site
ln -sf "$nginx_config" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default >/dev/null 2>&1

# Test Nginx config
echo -e "${green}Testing Nginx configuration...${plain}"
nginx -t
if [[ $? -ne 0 ]]; then
  echo -e "${red}Nginx configuration test failed!${plain}"
  exit 1
fi

# Reload Nginx
systemctl reload nginx
echo -e "${green}Nginx reverse proxy configured and reloaded${plain}"

# Finalize x-ui service
echo -e "${green}Starting and enabling x-ui...${plain}"
systemctl daemon-reload
systemctl enable x-ui
systemctl restart x-ui

# Auto-renew SSL certificates
(crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
echo -e "${green}SSL auto-renewal scheduled via cron${plain}"

# Final message
echo -e ""
echo -e "${green}✅ Installation completed!${plain}"
echo -e ""
echo -e "🔗 Access your x-ui admin panel: https://${subdomain}"
echo -e "🔐 Default login: ${yellow}admin / admin${plain}"
echo -e "📌 Port: ${yellow}8081${plain} (behind HTTPS reverse proxy)"
echo -e ""
echo -e "${yellow}💡 IMPORTANT:${plain}"
echo -e "   Run ${yellow}x-ui${plain} to change username, password, and secure your panel!"
echo -e "   Ensure your domain points to this server's IP before running."
echo -e ""
echo -e "${green}Firewall (UFW) Status:${plain}"
ufw status | grep -E "22|80|443|8081"
