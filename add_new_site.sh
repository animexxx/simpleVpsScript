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