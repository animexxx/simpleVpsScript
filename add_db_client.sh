#!/bin/bash
# Run this ON THE DB SERVER (setup_db.sh) to let another VPS (a new app/web
# server on the same VPC) reach this MariaDB + Redis instance. It only opens
# the firewall to that one IP and grants root@<that-ip> - it does not touch
# any existing site/DB, and Redis stays a single shared instance rather than
# each web server running its own.
set -e

read -rp "Enter the new app/web server's private VPC IP to allow: " NEW_CLIENT_IP
if [ -z "$NEW_CLIENT_IP" ]; then
    echo "An IP is required. Aborting." >&2
    exit 1
fi

if ! sudo test -f /root/.my.cnf; then
    echo "/root/.my.cnf not found - this doesn't look like a box set up by setup_db.sh." >&2
    exit 1
fi

ROOT_PASS=$(sudo awk -F= '/^password=/{print $2; exit}' /root/.my.cnf | sed 's/^"//; s/"$//')
if [ -z "$ROOT_PASS" ]; then
    echo "Could not read the root password from /root/.my.cnf." >&2
    exit 1
fi

# Escape any literal single quotes so the password can't break out of the SQL string below
ROOT_PASS_SQL=${ROOT_PASS//\'/\'\'}
sudo mysql <<EOF
CREATE USER IF NOT EXISTS 'root'@'${NEW_CLIENT_IP}' IDENTIFIED BY '${ROOT_PASS_SQL}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'${NEW_CLIENT_IP}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

sudo firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${NEW_CLIENT_IP}' port protocol='tcp' port='3306' accept"
sudo firewall-cmd --permanent --add-rich-rule="rule family='ipv4' source address='${NEW_CLIENT_IP}' port protocol='tcp' port='6379' accept"
sudo firewall-cmd --reload

echo "Done. ${NEW_CLIENT_IP} can now reach this DB on 3306 (user 'root', same password as the other web server) and Redis on 6379."
if sudo test -f /root/.redis_password; then
    echo "Redis password: $(sudo cat /root/.redis_password)"
fi

echo "=========================================="
echo " ALL DONE!"
echo "=========================================="
