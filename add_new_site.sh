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
    server_name  $domain;

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