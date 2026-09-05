#!/bin/bash
set -e
#input the new site domain 
echo "Enter the new site domain:"
read domain
#create dir
mkdir -p "/home/$domain"
#add nginx conf
sudo bash -c "cat > /etc/nginx/conf.d/$domain.conf" <<EOF
server {
    listen       80;
    listen       [::]:80;
    server_name  $domain www.$domain;

    root   /home/$domain;
    index  index.php index.html index.htm;
		
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
	
    location ~ \.php$ {
		include fastcgi.conf;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_buffering off;
        fastcgi_buffer_size 256k;
        fastcgi_buffers 4 256k;
    }

    location ~ /\.{
        deny  all;
    }
}
EOF

sudo chown -R nginx:nginx /home/
sudo chcon -R -t httpd_sys_rw_content_t /home/
sudo nginx -t
sudo systemctl restart nginx
echo "Added $domain"

# Optional: HTTPS via a Cloudflare Origin Certificate (for when this domain is
# proxied through Cloudflare - orange cloud). Not Let's Encrypt/certbot: with
# Cloudflare's proxy in front, the browser<->Cloudflare leg is already HTTPS,
# and Cloudflare only needs a certificate it trusts for the Cloudflare<->VPS
# leg - that's exactly what an Origin Certificate is for, and it's valid 15
# years (no renewal cron needed).
echo "Enable HTTPS for $domain using a Cloudflare Origin Certificate? (y/n):"
read -r ENABLE_SSL
if [[ "$ENABLE_SSL" =~ ^[Yy]$ ]]; then
    echo "In the Cloudflare dashboard: SSL/TLS -> Overview -> set mode to 'Full (strict)'."
    echo "Then SSL/TLS -> Origin Server -> Create Certificate (cover $domain and *.$domain)."
    echo "Save the certificate and private key as two files on this server (e.g. with nano), then enter their paths below."
    read -rp "Path to the certificate .pem file: " CERT_PATH
    read -rp "Path to the private key .pem file: " KEY_PATH

    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        echo "Cert or key file not found, skipping HTTPS setup." >&2
    else
        sudo mkdir -p "/etc/nginx/ssl/$domain"
        sudo cp "$CERT_PATH" "/etc/nginx/ssl/$domain/cert.pem"
        sudo cp "$KEY_PATH" "/etc/nginx/ssl/$domain/key.pem"
        sudo chmod 600 "/etc/nginx/ssl/$domain/key.pem"

        sudo bash -c "cat >> /etc/nginx/conf.d/$domain.conf" <<EOF

server {
    listen       443 ssl;
    listen       [::]:443 ssl;
    server_name  $domain www.$domain;

    ssl_certificate     /etc/nginx/ssl/$domain/cert.pem;
    ssl_certificate_key /etc/nginx/ssl/$domain/key.pem;

    root   /home/$domain;
    index  index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
		include fastcgi.conf;
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_buffering off;
        fastcgi_buffer_size 256k;
        fastcgi_buffers 4 256k;
    }

    location ~ /\.{
        deny  all;
    }
}
EOF
        sudo chcon -R -t httpd_sys_rw_content_t "/etc/nginx/ssl/$domain" 2>/dev/null || true
        sudo nginx -t && sudo systemctl restart nginx
        echo "HTTPS enabled for $domain on port 443. Make sure Cloudflare SSL/TLS mode is 'Full (strict)'."
    fi
fi

# Optional: git auto-deploy (push from PC straight to this VPS, no GitHub involved)
echo "Enable git auto-deploy for this site? (y/n):"
read -r ENABLE_GIT
if [[ "$ENABLE_GIT" =~ ^[Yy]$ ]]; then
    GIT_DIR="/home/git/$domain.git"
    WORK_TREE="/home/$domain"

    sudo mkdir -p "$GIT_DIR"
    sudo git init --bare -q "$GIT_DIR"

    sudo bash -c "cat > $GIT_DIR/hooks/post-receive" <<HOOK
#!/bin/bash
set -e
git --work-tree=$WORK_TREE --git-dir=$GIT_DIR checkout -f
chown -R nginx:nginx $WORK_TREE
chcon -R -t httpd_sys_rw_content_t $WORK_TREE 2>/dev/null || true
echo "Deployed \$(date) -> $WORK_TREE"
HOOK
    sudo chmod +x "$GIT_DIR/hooks/post-receive"

    SSH_PORT=$(sudo sed -n 's/^Port //p' /etc/ssh/sshd_config | head -1)
    SSH_PORT=${SSH_PORT:-22}
    SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

    echo "Git deploy ready. On your PC, inside the project repo, run:"
    echo "  git remote add production ssh://root@${SERVER_IP}:${SSH_PORT}${GIT_DIR}"
    echo "  git push production main"
    echo "Every push to 'production' will checkout straight into $WORK_TREE."
fi