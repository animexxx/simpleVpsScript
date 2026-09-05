#!/bin/bash
# Restrict phpMyAdmin (port 9119) to a dynamic-DNS hostname's current IP,
# re-checked every 5 minutes - so brute-force from anywhere else gets
# connection refused before it even reaches the basic-auth prompt.
#
# Requirement: you already have a dynamic DNS hostname pointing at your
# home/mobile IP (DuckDNS, No-IP, Cloudflare DDNS, or your router's
# built-in DDNS client - free, a couple minutes to set up if you don't
# have one yet).
#
# Run this ON THE WEB VPS, after setup_web.sh has already run there.
set -e

read -rp "Enter your dynamic DNS hostname (e.g. myhome.duckdns.org): " DDNS_HOSTNAME
if [ -z "$DDNS_HOSTNAME" ]; then
    echo "A hostname is required. Aborting." >&2
    exit 1
fi

CURRENT_IP=$(getent hosts "$DDNS_HOSTNAME" | awk '{print $1}' | head -1)
if [ -z "$CURRENT_IP" ]; then
    echo "Could not resolve $DDNS_HOSTNAME. Check the hostname and try again." >&2
    exit 1
fi
echo "Resolved $DDNS_HOSTNAME -> $CURRENT_IP"

sudo bash -c "cat > /etc/nginx/pma_allow.conf" <<EOF
allow ${CURRENT_IP};
deny all;
EOF

# Wire it into the phpMyAdmin vhost, same scope as the existing basic auth
if ! grep -q "include /etc/nginx/pma_allow.conf;" /etc/nginx/conf.d/default.conf; then
    sudo sed -i '/auth_basic_user_file/a\    include /etc/nginx/pma_allow.conf;' /etc/nginx/conf.d/default.conf
fi

sudo nginx -t && sudo systemctl reload nginx

# Sync script: re-resolves the hostname every 5 min, rewrites the allow-list
# and reloads nginx only when the IP actually changed.
sudo bash -c "cat > /usr/local/sbin/sync_pma_allow.sh" <<'SCRIPT'
#!/bin/bash
HOSTNAME="__DDNS_HOSTNAME__"
ALLOW_FILE=/etc/nginx/pma_allow.conf
CURRENT_IP=$(getent hosts "$HOSTNAME" | awk '{print $1}' | head -1)
[ -z "$CURRENT_IP" ] && exit 0
if ! grep -q "allow ${CURRENT_IP};" "$ALLOW_FILE" 2>/dev/null; then
    { echo "allow ${CURRENT_IP};"; echo "deny all;"; } > "$ALLOW_FILE"
    nginx -t && systemctl reload nginx
fi
SCRIPT
sudo sed -i "s/__DDNS_HOSTNAME__/${DDNS_HOSTNAME}/" /usr/local/sbin/sync_pma_allow.sh
sudo chmod +x /usr/local/sbin/sync_pma_allow.sh

echo "* * * * * root /usr/local/sbin/sync_pma_allow.sh >> /var/log/pma_allow_sync.log 2>&1" | sudo tee /etc/cron.d/sync_pma_allow > /dev/null

echo "Done. Only ${DDNS_HOSTNAME} (currently ${CURRENT_IP}) can reach port 9119; rechecked every minute."
echo "If you ever get locked out (IP changed and hasn't synced yet), edit /etc/nginx/pma_allow.conf over SSH and reload nginx manually."
echo "=========================================="
echo " ALL DONE!"
echo "=========================================="
