#!/bin/bash
# Set MariaDB root password and secure installation

# MariaDB (MySQL) root password.
# Set it non-interactively:  ROOT_PASS='real-pass' ./vps_setup.sh
# Otherwise you will be prompted for it below.
if [ -z "${ROOT_PASS:-}" ]; then
    while :; do
        read -rsp "Please enter your root password (MySQL root password to set): " ROOT_PASS; echo
        read -rsp "Please re-enter to confirm: " ROOT_PASS_CONFIRM; echo
        if [ -n "$ROOT_PASS" ] && [ "$ROOT_PASS" = "$ROOT_PASS_CONFIRM" ]; then
            break
        fi
        echo "Password is empty or does not match, please try again."
    done
    unset ROOT_PASS_CONFIRM
fi

# Basic-auth credentials that gate the phpMyAdmin URL - kept separate from the
# MySQL root password above, so leaking one doesn't leak the other.
if [ -z "${PMA_USER:-}" ]; then
    read -rp "Choose a username for the phpMyAdmin basic-auth prompt: " PMA_USER
fi
if [ -z "${PMA_PASS:-}" ]; then
    while :; do
        read -rsp "Choose a password for that basic-auth prompt: " PMA_PASS; echo
        read -rsp "Please re-enter to confirm: " PMA_PASS_CONFIRM; echo
        if [ -n "$PMA_PASS" ] && [ "$PMA_PASS" = "$PMA_PASS_CONFIRM" ]; then
            break
        fi
        echo "Password is empty or does not match, please try again."
    done
    unset PMA_PASS_CONFIRM
fi

# Exit immediately if a command exits with a non-zero status
set -e

# Logging setup
exec > >(tee -i /var/log/setup.log)
exec 2>&1

# Update system packages
sudo dnf update -y

# Install EPEL repository
sudo dnf install epel-release -y

sudo dnf install cronie
sudo systemctl enable crond
sudo systemctl start crond


sudo dnf install https://rpms.remirepo.net/enterprise/remi-release-9.rpm -y
sudo dnf config-manager --set-enabled remi -y
sudo dnf module enable php:remi-8.2 -y

# Install Git
sudo dnf install git -y

# Install Nginx
sudo dnf install nginx -y

# Enable and start Nginx
sudo systemctl enable nginx
sudo systemctl start nginx

# Install MySQL (MariaDB)
sudo dnf install mariadb-server mariadb -y

# Install Redis and PHP Redis module (object cache for WordPress)
sudo dnf install redis php-redis -y

# Limit Redis memory so cache growth doesn't starve MariaDB/PHP on small VPS
# 128mb for 1-2GB RAM, 256mb for >=4GB; allkeys-lru evicts old keys instead of erroring
REDIS_MAXMEM=128mb
[ "$(free -m | awk '/^Mem:/{print $2}')" -ge 3500 ] && REDIS_MAXMEM=256mb
sudo sed -i "s/^# maxmemory <bytes>/maxmemory ${REDIS_MAXMEM}/" /etc/redis/redis.conf
sudo sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf

# Enable and start Redis (defaults already bind 127.0.0.1 + protected-mode on)
sudo systemctl enable redis --now


# Enable and start MariaDB
sudo systemctl enable mariadb
sudo systemctl start mariadb

# Use mysqladmin to set the root password
sudo mysqladmin -u root password "$ROOT_PASS"

# Secure MariaDB installation
sudo mysql -u root -p"$ROOT_PASS" <<EOF
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
FLUSH PRIVILEGES;
EOF

# Install PHP and necessary PHP extensions
sudo dnf install php php-fpm php-zip php-sodium php-bz2 php-opcache php-cli php-mysqlnd php-json php-opcache php-xml php-gd php-mbstring php-mcrypt php-xml -y

# Configure PHP-FPM to work with Nginx
sudo sed -i 's/^user = apache/user = nginx/g' /etc/php-fpm.d/www.conf
sudo sed -i 's/^group = apache/group = nginx/g' /etc/php-fpm.d/www.conf
sudo sed -i 's/;listen.owner = nobody/listen.owner = nginx/g' /etc/php-fpm.d/www.conf
sudo sed -i 's/;listen.group = nobody/listen.group = nginx/g' /etc/php-fpm.d/www.conf
sudo sed -i 's|^listen = /run/php-fpm/www.sock|listen = 127.0.0.1:9000|' /etc/php-fpm.d/www.conf

# Tune PHP-FPM pool size based on total RAM (~10 child processes per GB, min 10)
# 1GB -> 10, 2GB -> 20, 4GB -> 40, ... scales up with more RAM
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
RAM_GB=$(( (RAM_MB + 512) / 1024 ))
[ "$RAM_GB" -lt 1 ] && RAM_GB=1
MAX_CHILDREN=$(( RAM_GB * 10 ))
START_SERVERS=$(( MAX_CHILDREN / 4 ))
MIN_SPARE=$(( MAX_CHILDREN / 4 ))
MAX_SPARE=$(( MAX_CHILDREN / 2 ))
[ "$START_SERVERS" -lt 2 ] && START_SERVERS=2
[ "$MIN_SPARE" -lt 1 ] && MIN_SPARE=1
[ "$MAX_SPARE" -lt 3 ] && MAX_SPARE=3

echo "Detected ${RAM_MB}MB RAM (~${RAM_GB}GB) -> pm.max_children=${MAX_CHILDREN}, start=${START_SERVERS}, min_spare=${MIN_SPARE}, max_spare=${MAX_SPARE}"

sudo sed -i "s/^pm.max_children = .*/pm.max_children = ${MAX_CHILDREN}/" /etc/php-fpm.d/www.conf
sudo sed -i "s/^pm.start_servers = .*/pm.start_servers = ${START_SERVERS}/" /etc/php-fpm.d/www.conf
sudo sed -i "s/^pm.min_spare_servers = .*/pm.min_spare_servers = ${MIN_SPARE}/" /etc/php-fpm.d/www.conf
sudo sed -i "s/^pm.max_spare_servers = .*/pm.max_spare_servers = ${MAX_SPARE}/" /etc/php-fpm.d/www.conf

# Enable and start PHP-FPM
sudo systemctl enable --now php-fpm
sudo systemctl status php-fpm

# Update the upload_max_filesize value
sudo sed -i "s/^upload_max_filesize = .*/upload_max_filesize = 50M/" "/etc/php.ini"
sudo sed -i "s/^post_max_size = .*/post_max_size = 50M/" "/etc/php.ini"
sudo sed -i "s/^memory_limit = .*/memory_limit = 256M/" "/etc/php.ini"
sudo sed -i "s/^max_execution_time = .*/max_execution_time = 300/" "/etc/php.ini"

sudo systemctl restart php-fpm


# Set SELinux permissions (if SELinux is enabled)
sudo setsebool -P httpd_can_network_connect 1
sudo chcon -t httpd_sys_rw_content_t /usr/share/nginx/html -R

# Firewall configuration (if firewalld is active)
sudo firewall-cmd --permanent --zone=public --add-service=http
sudo firewall-cmd --permanent --zone=public --add-service=https
sudo firewall-cmd --permanent --add-port=2222/tcp
sudo firewall-cmd --permanent --add-port=9119/tcp
sudo firewall-cmd --reload

# Install Supervisor
sudo dnf install supervisor -y
# Enable and start Supervisor
sudo systemctl enable supervisord
sudo systemctl start supervisord

# Harden SSH: key-only login (no passwords), root allowed only via key, port 2222
# WARNING: make sure your SSH public key is already in /root/.ssh/authorized_keys
# (or your sudo user's) BEFORE running this - there is no password fallback after.
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config

# Allow SELinux to permit SSH on port 2222
sudo semanage port -a -t ssh_port_t -p tcp 2222

# Validate config, then restart (won't restart on a bad config, so we don't lock ourselves out)
sudo sshd -t && sudo systemctl restart sshd

# Install Fail2Ban
sudo dnf install fail2ban -y

# Basic Fail2Ban configuration for SSH
sudo bash -c 'cat > /etc/fail2ban/jail.local' <<EOF
[sshd]
enabled = true
port    = 2222
logpath = %(sshd_log)s
backend = %(sshd_backend)s
maxretry = 5
bantime = 1h
EOF

# Enable and start Fail2Ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Install Composer globally
echo "Installing Composer..."
php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
php composer-setup.php --install-dir=/usr/local/bin --filename=composer
php -r "unlink('composer-setup.php');"

# Verify Composer installation
composer --version

# Download and Install phpMyAdmin
sudo dnf install wget -y
sudo dnf install unzip -y
sudo mkdir -p /home/html
cd /home/html
composer create-project phpmyadmin/phpmyadmin

# Create a basic password-protected .htpasswd file
sudo dnf install httpd-tools -y
# Create a basic password-protected .htpasswd file with a password directly
sudo htpasswd -cb /etc/nginx/.htpasswd "$PMA_USER" "$PMA_PASS"

> /etc/nginx/nginx.conf
> /etc/nginx/conf.d/default.conf

sudo bash -c 'cat > /etc/nginx/nginx.conf' <<EOF
user nginx;
worker_processes auto;
worker_rlimit_nofile 260000;

error_log  /var/log/nginx/error.log;
pid        /run/nginx.pid;
include /usr/share/nginx/modules/*.conf;

events {
        worker_connections  2048;
        accept_mutex off;
        accept_mutex_delay 200ms;
        use epoll;
        #multi_accept on;
}

http {
        include       /etc/nginx/mime.types;
        default_type  application/octet-stream;

        log_format  main  '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                      '\$status \$body_bytes_sent "\$http_referer" '
                      '\"$http_user_agent" "\$http_x_forwarded_for"';

        #Disable IFRAME
        add_header X-Frame-Options SAMEORIGIN;

        #Prevent Cross-site scripting (XSS) attacks
        add_header X-XSS-Protection "1; mode=block";

        #Prevent MIME-sniffing
        add_header X-Content-Type-Options nosniff;

        access_log  off;
        sendfile on;
        tcp_nopush on;
        tcp_nodelay off;
        types_hash_max_size 2048;
        server_tokens off;
        server_names_hash_bucket_size 128;
        client_max_body_size 0;
        client_body_buffer_size 256k;
        client_body_in_file_only off;
        client_body_timeout 60s;
        client_header_buffer_size 256k;
        client_header_timeout  20s;
        large_client_header_buffers 8 256k;
        keepalive_timeout 10;
        keepalive_disable msie6;
        reset_timedout_connection on;
        send_timeout 60s;

        gzip on;
        gzip_static on;
        gzip_disable "msie6";
        gzip_vary on;
        gzip_proxied any;
        gzip_comp_level 6;
        gzip_buffers 16 8k;
        gzip_http_version 1.1;
        gzip_types text/plain text/css application/json text/javascript application/javascript text/xml application/xml application/xml+rss;

        fastcgi_connect_timeout 300;
        fastcgi_send_timeout    300;
        fastcgi_read_timeout    300;

        include /etc/nginx/conf.d/*.conf;
}

EOF

# Configure Nginx to use PHP processor
sudo bash -c 'cat > /etc/nginx/conf.d/default.conf' <<EOF
server {
    listen       9119;
    server_name  localhost;

    root   /home/html;
    index  index.php index.html index.htm;
	auth_basic "Restricted Access";
	auth_basic_user_file /etc/nginx/.htpasswd;
		
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

sudo chmod 600 /etc/nginx/.htpasswd

# Output PHP info to test
echo "<?php phpinfo(); ?>" | sudo tee /home/html/index.php

#permission 
sudo chown -R nginx:nginx /home/
sudo chcon -R -t httpd_sys_rw_content_t /home/
sudo chown -R nginx:nginx /var/lib/php/session/
sudo chown -R nginx:nginx /etc/nginx/.htpasswd
sudo chcon -R -t httpd_sys_rw_content_t /etc/nginx/.htpasswd
sudo semanage port -a -t http_port_t  -p tcp 9119

# Set SELinux permissions (if SELinux is enabled)
sudo setsebool -P httpd_can_network_connect 1
sudo chcon -t httpd_sys_rw_content_t /home/html -R

# Set /home as the default directory for SSH and SFTP
# Change root's home directory to /home so SFTP clients land in /home by default
sudo usermod -d /home root
# Ensure SSH sessions also start in /home
echo 'cd /home' | sudo tee -a /root/.bashrc > /dev/null

# Test Nginx configuration and restart Nginx
sudo nginx -t
sudo systemctl restart nginx
echo "LEMP, Supervisor, SSH, Fail2Ban, phpMyAdmin, and Git installation completed. You can test the setup by accessing http://server_ip_address:9119/ and http://server_ip_address:9119/phpmyadmin"
echo "phpMyAdmin basic-auth user: $PMA_USER (then log in with MySQL user root and the MariaDB root password you set)."

