#!/bin/bash
# DB tier only: MariaDB + Redis, both reachable exclusively over Vultr's
# private VPC network. Redis lives here (not on the web tier) so that if you
# add more web/app servers later (see add_db_client.sh) they all share ONE
# Redis instead of each running its own - one cache to manage, one place to
# check hit rate, no per-box config drift.
# Run this first, then setup_web.sh on the other VPS pointing at this box's private IP.

# --- This server's own private VPC IP (what MariaDB will bind/listen on) ---
if [ -z "${DB_PRIVATE_IP:-}" ]; then
    read -rp "Enter THIS server's private VPC IP (e.g. 10.1.0.2): " DB_PRIVATE_IP
fi
if [ -z "$DB_PRIVATE_IP" ]; then
    echo "DB_PRIVATE_IP is required. Aborting." >&2
    exit 1
fi

# --- The web server's private VPC IP (only source firewalld/MariaDB will trust) ---
if [ -z "${WEB_PRIVATE_IP:-}" ]; then
    read -rp "Enter the web server's private VPC IP that is allowed to connect (e.g. 10.1.0.3): " WEB_PRIVATE_IP
fi
if [ -z "$WEB_PRIVATE_IP" ]; then
    echo "WEB_PRIVATE_IP is required. Aborting." >&2
    exit 1
fi

# --- MariaDB root password ---
if [ -z "${ROOT_PASS:-}" ]; then
    while :; do
        read -rsp "Please enter the MariaDB root password to set: " ROOT_PASS; echo
        read -rsp "Please re-enter to confirm: " ROOT_PASS_CONFIRM; echo
        if [ -n "$ROOT_PASS" ] && [ "$ROOT_PASS" = "$ROOT_PASS_CONFIRM" ]; then
            break
        fi
        echo "Password is empty or does not match, please try again."
    done
    unset ROOT_PASS_CONFIRM
fi

# Exit immediately if a command exits with a non-zero status
set -e

# Logging setup
exec > >(tee -i /var/log/setup_db.log)
exec 2>&1

# Update system packages
sudo dnf update -y

# Install EPEL repository (fail2ban lives here)
sudo dnf install epel-release -y

sudo dnf install cronie -y
sudo systemctl enable crond
sudo systemctl start crond

# Install MariaDB
sudo dnf install mariadb-server mariadb -y

# Enable and start MariaDB
sudo systemctl enable mariadb
sudo systemctl start mariadb

# Use mysqladmin to set the root password
sudo mysqladmin -u root password "$ROOT_PASS"

# Secure MariaDB installation, and add a root@<web-private-ip> account so the
# web tier can connect over the VPC network (root@localhost still works locally).
sudo mysql -u root -p"$ROOT_PASS" <<EOF
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
CREATE USER IF NOT EXISTS 'root'@'${WEB_PRIVATE_IP}' IDENTIFIED BY '${ROOT_PASS}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'${WEB_PRIVATE_IP}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

# Save root credentials for cron/mysqldump so scripts never need the password on
# the command line (which would otherwise leak into `ps aux` output).
sudo bash -c "cat > /root/.my.cnf" <<EOF
[client]
user=root
password=${ROOT_PASS}
EOF
sudo chmod 600 /root/.my.cnf

# Bind MariaDB to the private VPC IP only - never listen on the public interface,
# firewalld below is the second layer of defense, not the only one.
# (The stock config usually has no bind-address line at all, so check rather
# than assume the sed below would otherwise match nothing and silently no-op.)
if grep -q "^bind-address" /etc/my.cnf.d/mariadb-server.cnf; then
    sudo sed -i "s/^bind-address.*/bind-address = ${DB_PRIVATE_IP}/" /etc/my.cnf.d/mariadb-server.cnf
else
    sudo sed -i "/^\[mysqld\]/a bind-address = ${DB_PRIVATE_IP}" /etc/my.cnf.d/mariadb-server.cnf
fi

# Size innodb_buffer_pool_size from total RAM (~60%, min 128M) - this box has no
# Nginx/PHP competing for RAM anymore, so InnoDB can use most of it.
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
INNODB_MB=$(( RAM_MB * 60 / 100 ))
[ "$INNODB_MB" -lt 128 ] && INNODB_MB=128
echo "Detected ${RAM_MB}MB RAM -> innodb_buffer_pool_size=${INNODB_MB}M"
if grep -q "^innodb_buffer_pool_size" /etc/my.cnf.d/mariadb-server.cnf; then
    sudo sed -i "s/^innodb_buffer_pool_size.*/innodb_buffer_pool_size = ${INNODB_MB}M/" /etc/my.cnf.d/mariadb-server.cnf
else
    sudo sed -i "/^\[mysqld\]/a innodb_buffer_pool_size = ${INNODB_MB}M" /etc/my.cnf.d/mariadb-server.cnf
fi

sudo systemctl restart mariadb

# Install Redis (object cache backend for WordPress on the web tier)
sudo dnf install redis -y

# Limit Redis memory so cache growth doesn't starve MariaDB
# 128mb for 1-2GB RAM, 256mb for >=4GB; allkeys-lru evicts old keys instead of erroring
REDIS_MAXMEM=128mb
[ "$RAM_MB" -ge 3500 ] && REDIS_MAXMEM=256mb
sudo sed -i "s/^# maxmemory <bytes>/maxmemory ${REDIS_MAXMEM}/" /etc/redis/redis.conf
sudo sed -i 's/^# maxmemory-policy noeviction/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf

# Bind to the private VPC IP (plus localhost) and require a password - same
# defense-in-depth approach as MariaDB: network-restricted AND authenticated.
# Checked rather than assumed to match, same reasoning as the MariaDB bind fix above.
if grep -q "^bind " /etc/redis/redis.conf; then
    sudo sed -i "s/^bind .*/bind 127.0.0.1 ${DB_PRIVATE_IP}/" /etc/redis/redis.conf
else
    echo "bind 127.0.0.1 ${DB_PRIVATE_IP}" | sudo tee -a /etc/redis/redis.conf > /dev/null
fi

REDIS_PASS=$(openssl rand -base64 24)
if grep -q "^# requirepass" /etc/redis/redis.conf; then
    sudo sed -i "s/^# requirepass.*/requirepass ${REDIS_PASS}/" /etc/redis/redis.conf
else
    echo "requirepass ${REDIS_PASS}" | sudo tee -a /etc/redis/redis.conf > /dev/null
fi
echo "$REDIS_PASS" | sudo tee /root/.redis_password > /dev/null
sudo chmod 600 /root/.redis_password

sudo systemctl enable redis --now

# Verify neither service ended up listening on all interfaces (0.0.0.0) - a
# config-file mismatch on a different distro/version would otherwise fail
# silently and leave firewalld as the only thing standing between the DB and
# the public internet.
sleep 1
if sudo ss -tlnp | grep -E ':(3306|6379)\b' | grep -qE '0\.0\.0\.0|\*:'; then
    echo "WARNING: MariaDB and/or Redis appear to be listening on ALL interfaces, not just ${DB_PRIVATE_IP}." >&2
    echo "Check bind-address in /etc/my.cnf.d/mariadb-server.cnf and 'bind' in /etc/redis/redis.conf." >&2
    sudo ss -tlnp | grep -E ':(3306|6379)\b' >&2
fi

# Firewall: only the web server's private IP may reach 3306/6379, and only ssh besides that.
# No http/https/9119 here - this box has no web server on it.
sudo firewall-cmd --permanent --add-port=2222/tcp
sudo firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${WEB_PRIVATE_IP}' port protocol='tcp' port='3306' accept"
sudo firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${WEB_PRIVATE_IP}' port protocol='tcp' port='6379' accept"
sudo firewall-cmd --reload

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

# Nightly mysqldump of every database, gzip'd, kept 7 days
sudo mkdir -p /root/db_backups
sudo bash -c 'cat > /etc/cron.daily/mysql_backup' <<'CRON'
#!/bin/bash
set -e
BACKUP_DIR=/root/db_backups
DATE=$(date +%F)
mysqldump --all-databases | gzip > "$BACKUP_DIR/all-$DATE.sql.gz"
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete
CRON
sudo chmod 700 /etc/cron.daily/mysql_backup

echo "MariaDB + Redis installation completed."
echo "MariaDB: ${DB_PRIVATE_IP}:3306, reachable only from ${WEB_PRIVATE_IP} (firewalld) and only 'root'@'${WEB_PRIVATE_IP}' plus 'root'@'localhost' can authenticate."
echo "Redis: ${DB_PRIVATE_IP}:6379, reachable only from ${WEB_PRIVATE_IP} (firewalld). Password: ${REDIS_PASS} (also saved in /root/.redis_password)."
echo "Nightly backups: /root/db_backups (kept 7 days). Copy them off-box periodically - this server is a single point of failure for all data."
