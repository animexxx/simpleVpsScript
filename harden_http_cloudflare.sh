#!/bin/bash
# Restrict ports 80/443 to Cloudflare's published IP ranges only, so
# scan-bots hitting the VPS's public IP directly (bypassing Cloudflare's
# proxy) get connection refused at the firewall instead of reaching
# Nginx/PHP-FPM and burning CPU on port scans and vuln probes.
#
# ONLY run this if every site on the box is proxied through Cloudflare
# (orange cloud). Any site that is NOT proxied - grey-cloud DNS, or a
# domain not on Cloudflare at all - becomes unreachable over 80/443
# afterwards, since the firewall stops accepting connections from anywhere
# but Cloudflare's ranges.
#
# Run this ON THE WEB VPS (or the single all-in-one VPS from vps_setup.sh),
# after http/https have already been opened by that script.
set -e

echo "This will block ALL direct HTTP/HTTPS traffic to this VPS except from"
echo "Cloudflare's IP ranges. Only continue if every site here is proxied"
echo "through Cloudflare (orange cloud in the DNS tab)."
if [ -z "${CONFIRM:-}" ]; then
    read -rp "Continue? (y/n): " CONFIRM
fi
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

V4_FILE=$(mktemp)
V6_FILE=$(mktemp)
trap 'rm -f "$V4_FILE" "$V6_FILE"' EXIT

curl -fs https://www.cloudflare.com/ips-v4 -o "$V4_FILE"
curl -fs https://www.cloudflare.com/ips-v6 -o "$V6_FILE"
if [ ! -s "$V4_FILE" ] || [ ! -s "$V6_FILE" ]; then
    echo "Could not fetch Cloudflare's IP ranges. Check network access and try again." >&2
    exit 1
fi

# ipsets are created once; if they already exist (re-running this script,
# or the cron resync below already ran), leave their entries alone here -
# the resync job is what keeps them current, so we don't want a plain
# re-run of this script to fight it.
if ! sudo firewall-cmd --permanent --get-ipsets | grep -qw cloudflare4; then
    sudo firewall-cmd --permanent --new-ipset=cloudflare4 --type=hash:net --option=family=inet
    sudo firewall-cmd --permanent --ipset=cloudflare4 --add-entries-from-file="$V4_FILE"
fi
if ! sudo firewall-cmd --permanent --get-ipsets | grep -qw cloudflare6; then
    sudo firewall-cmd --permanent --new-ipset=cloudflare6 --type=hash:net --option=family=inet6
    sudo firewall-cmd --permanent --ipset=cloudflare6 --add-entries-from-file="$V6_FILE"
fi

# The setup scripts open http/https zone-wide (--add-service); drop that
# and replace it with rich rules scoped to the Cloudflare ipsets so 80/443
# only accept connections that already passed through Cloudflare's proxy.
sudo firewall-cmd --permanent --zone=public --remove-service=http
sudo firewall-cmd --permanent --zone=public --remove-service=https

for RULE in \
    'rule family="ipv4" source ipset="cloudflare4" port port="80" protocol="tcp" accept' \
    'rule family="ipv4" source ipset="cloudflare4" port port="443" protocol="tcp" accept' \
    'rule family="ipv6" source ipset="cloudflare6" port port="80" protocol="tcp" accept' \
    'rule family="ipv6" source ipset="cloudflare6" port port="443" protocol="tcp" accept'
do
    sudo firewall-cmd --permanent --zone=public --add-rich-rule="$RULE"
done

sudo firewall-cmd --reload

# Resync script: Cloudflare's ranges rarely change, but when they do, an
# out-of-date ipset either blocks Cloudflare itself or leaves a stale range
# open. Re-fetches daily and only touches the ipsets/reloads if something
# actually changed.
sudo bash -c "cat > /usr/local/sbin/sync_cloudflare_ips.sh" <<'SCRIPT'
#!/bin/bash
set -e

V4_NEW=$(mktemp); V6_NEW=$(mktemp)
V4_OLD=$(mktemp); V6_OLD=$(mktemp)
trap 'rm -f "$V4_NEW" "$V6_NEW" "$V4_OLD" "$V6_OLD"' EXIT

curl -fs https://www.cloudflare.com/ips-v4 -o "$V4_NEW"
curl -fs https://www.cloudflare.com/ips-v6 -o "$V6_NEW"
[ -s "$V4_NEW" ] && [ -s "$V6_NEW" ] || exit 0
sort -o "$V4_NEW" "$V4_NEW"
sort -o "$V6_NEW" "$V6_NEW"

firewall-cmd --permanent --ipset=cloudflare4 --get-entries | sort > "$V4_OLD"
firewall-cmd --permanent --ipset=cloudflare6 --get-entries | sort > "$V6_OLD"

if ! cmp -s "$V4_OLD" "$V4_NEW" || ! cmp -s "$V6_OLD" "$V6_NEW"; then
    [ -s "$V4_OLD" ] && firewall-cmd --permanent --ipset=cloudflare4 --remove-entries-from-file="$V4_OLD" >/dev/null
    [ -s "$V6_OLD" ] && firewall-cmd --permanent --ipset=cloudflare6 --remove-entries-from-file="$V6_OLD" >/dev/null
    firewall-cmd --permanent --ipset=cloudflare4 --add-entries-from-file="$V4_NEW" >/dev/null
    firewall-cmd --permanent --ipset=cloudflare6 --add-entries-from-file="$V6_NEW" >/dev/null
    firewall-cmd --reload >/dev/null
fi
SCRIPT
sudo chmod +x /usr/local/sbin/sync_cloudflare_ips.sh

echo "17 4 * * * root /usr/local/sbin/sync_cloudflare_ips.sh >> /var/log/cloudflare_ips_sync.log 2>&1" | sudo tee /etc/cron.d/sync_cloudflare_ips > /dev/null

echo "Done. Port 80/443 now only accept connections from Cloudflare's published IP ranges; refreshed daily via cron."
echo "If a site stops loading, check whether it's actually proxied through Cloudflare (orange cloud) - if not, either enable the proxy or revert with:"
echo "  sudo firewall-cmd --permanent --zone=public --add-service=http --add-service=https"
echo "  sudo firewall-cmd --permanent --zone=public --remove-rich-rule='rule family=\"ipv4\" source ipset=\"cloudflare4\" port port=\"80\" protocol=\"tcp\" accept' (repeat for the other 3 rich rules)"
echo "  sudo firewall-cmd --reload"
echo "=========================================="
echo " ALL DONE!"
echo "=========================================="
