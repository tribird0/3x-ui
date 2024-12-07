#!/bin/bash

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# Root privileges check
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}This script must be run as root.${NC}" 1>&2
  exit 1
fi

# Prompt for subdomain
echo -e "${GREEN}Enter the subdomain for 3x-ui (e.g., panel.example.com):${NC}"
read -rp "Subdomain: " SUBDOMAIN

# Validate input
if [[ -z "$SUBDOMAIN" ]]; then
  echo -e "${RED}Subdomain cannot be empty. Exiting.${NC}"
  exit 1
fi

# Update and install required packages
echo -e "${GREEN}Updating system and installing dependencies...${NC}"
apt update && apt upgrade -y
apt install -y curl wget tar nginx certbot python3-certbot-nginx

# Install 3x-ui
echo -e "${GREEN}Installing 3x-ui...${NC}"
bash <(curl -Ls https://raw.githubusercontent.com/5438/3x-ui/master/install.sh)

# Ensure Nginx is installed and running
echo -e "${GREEN}Configuring Nginx for reverse proxy...${NC}"
systemctl enable nginx
systemctl start nginx

# Configure Nginx reverse proxy
NGINX_CONF="/etc/nginx/sites-available/3x-ui"
cat <<EOF > $NGINX_CONF
server {
    server_name $SUBDOMAIN;

    location / {
        proxy_pass http://127.0.0.1:54321; # Default 3x-ui port
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    listen 80;
    listen [::]:80;
}
EOF

ln -s $NGINX_CONF /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# Obtain SSL certificate using Certbot
echo -e "${GREEN}Obtaining SSL certificate for $SUBDOMAIN...${NC}"
certbot --nginx -d "$SUBDOMAIN" --non-interactive --agree-tos -m admin@$SUBDOMAIN --redirect

# Finalize and restart services
echo -e "${GREEN}Finalizing installation...${NC}"
systemctl restart nginx
systemctl restart 3x-ui

# Display access information
echo -e "${GREEN}Installation completed!${NC}"
echo -e "${GREEN}3x-ui is accessible at: https://$SUBDOMAIN${NC}"
echo -e "${GREEN}Use '3x-ui' command to manage the panel.${NC}"
