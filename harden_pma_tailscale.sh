#!/bin/bash
# Restrict phpMyAdmin (port 9119) to your Tailscale network: nginx binds that
# vhost to the VPS's Tailscale IP instead of the public interface, so it's
# unreachable from the public internet at all - no client IP to track, no
# cron sync needed. Requires Tailscale on this VPS and on whatever device
# you'll browse phpMyAdmin from (same tailnet).
set -e

# Install Tailscale if not already present
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
fi

# Bring this VPS onto your tailnet. If not already logged in, this prints a
# URL - open it in a browser and approve the device, then it returns.
sudo tailscale up

TS_IP=$(tailscale ip -4)
if [ -z "$TS_IP" ]; then
    echo "Could not get a Tailscale IP - check 'tailscale status'." >&2
    exit 1
fi
echo "This VPS's Tailscale IP: $TS_IP"

# Bind the phpMyAdmin vhost to the Tailscale interface only
sudo sed -i "s/^    listen       9119;/    listen       ${TS_IP}:9119;/" /etc/nginx/conf.d/default.conf

sudo nginx -t && sudo systemctl reload nginx

# No longer reachable publicly - drop the public firewall rule for it
sudo firewall-cmd --permanent --remove-port=9119/tcp 2>/dev/null || true
sudo firewall-cmd --reload

echo "Done. phpMyAdmin now only listens on ${TS_IP}:9119 (your tailnet)."
echo "From any device on the same tailnet: http://${TS_IP}:9119/phpmyadmin"
echo "Basic auth (.htpasswd) still applies as a second layer."
