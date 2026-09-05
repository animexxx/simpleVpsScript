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
    echo "In the Cloudflare dashboard: SSL/TLS -> Overview -> set mode to 'Full (strict)' (do this once per domain)."

    SSL_DIR="/etc/nginx/ssl/$domain"
    sudo mkdir -p "$SSL_DIR"
    CERT_READY=0

    echo "Auto-create the certificate via the Cloudflare API instead of copy-pasting from the dashboard? (y/n):"
    read -r USE_CF_API
    if [[ "$USE_CF_API" =~ ^[Yy]$ ]]; then
        # Needs jq to parse the API response
        command -v jq >/dev/null 2>&1 || sudo dnf install jq -y

        # One-time per account, not per domain: dashboard -> My Profile -> API Tokens -> Origin CA Key
        if [ -z "${CF_ORIGIN_CA_KEY:-}" ]; then
            read -rsp "Enter your Cloudflare Origin CA Key (My Profile > API Tokens > Origin CA Key, same key works for every future domain): " CF_ORIGIN_CA_KEY
            echo
        fi

        CSR_PATH=$(mktemp)
        sudo openssl req -new -newkey rsa:2048 -nodes \
            -keyout "$SSL_DIR/key.pem" \
            -out "$CSR_PATH" \
            -subj "/CN=$domain" >/dev/null 2>&1

        CSR_JSON=$(sudo awk '{printf "%s\\n", $0}' "$CSR_PATH")
        RESPONSE=$(curl -s https://api.cloudflare.com/client/v4/certificates \
            -H "X-Auth-User-Service-Key: $CF_ORIGIN_CA_KEY" \
            -H "Content-Type: application/json" \
            --data "{\"hostnames\":[\"$domain\",\"*.$domain\"],\"requested_validity\":5475,\"request_type\":\"origin-rsa\",\"csr\":\"$CSR_JSON\"}")
        rm -f "$CSR_PATH"

        if [ "$(echo "$RESPONSE" | jq -r '.success')" = "true" ]; then
            echo "$RESPONSE" | jq -r '.result.certificate' | sudo tee "$SSL_DIR/cert.pem" >/dev/null
            sudo chmod 600 "$SSL_DIR/key.pem"
            CERT_READY=1
            echo "Certificate created via Cloudflare API (valid 15 years)."
        else
            echo "Cloudflare API call failed, falling back to manual: $(echo "$RESPONSE" | jq -c '.errors')" >&2
        fi
    fi

    if [ "$CERT_READY" -eq 0 ]; then
        echo "SSL/TLS -> Origin Server -> Create Certificate (cover $domain and *.$domain) in the dashboard."
        echo "Save the certificate and private key as two files on this server (e.g. with nano), then enter their paths below."
        read -rp "Path to the certificate .pem file: " CERT_PATH
        read -rp "Path to the private key .pem file: " KEY_PATH

        if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
            echo "Cert or key file not found, skipping HTTPS setup." >&2
        else
            sudo cp "$CERT_PATH" "$SSL_DIR/cert.pem"
            sudo cp "$KEY_PATH" "$SSL_DIR/key.pem"
            sudo chmod 600 "$SSL_DIR/key.pem"
            CERT_READY=1
        fi
    fi

    if [ "$CERT_READY" -eq 1 ]; then
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

echo "=========================================="
echo " ALL DONE!"
echo "=========================================="