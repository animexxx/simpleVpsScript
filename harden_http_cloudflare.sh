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
# Cloudflare's ips-v4/ips-v6 responses don't end in a newline, and both
# `while read` and firewalld's own file parser silently drop a final line
# that isn't newline-terminated - so the last CIDR in each file would
# otherwise never make it into the ipset.
echo >> "$V4_FILE"
echo >> "$V6_FILE"

# ipsets are created once; if they already exist (re-running this script,
# or the cron resync below already ran), leave their entries alone here -
# the resync job is what keeps them current, so we don't want a plain
# re-run of this script to fight it.
#
# family is set via --option=family=..., not the documented --family= flag:
# firewalld has a long-standing bug where --family= on --new-ipset is
# silently ignored (https://github.com/firewalld/firewalld/issues/172),
# which would leave cloudflare6 created as an inet (v4) set.
if ! sudo firewall-cmd --permanent --get-ipsets | grep -qw cloudflare4; then
    sudo firewall-cmd --permanent --new-ipset=cloudflare4 --type=hash:net --option=family=inet
    while read -r cidr; do
        [ -n "$cidr" ] && sudo firewall-cmd --permanent --ipset=cloudflare4 --add-entry="$cidr"
    done < "$V4_FILE"
fi
if ! sudo firewall-cmd --permanent --get-ipsets | grep -qw cloudflare6; then
    sudo firewall-cmd --permanent --new-ipset=cloudflare6 --type=hash:net --option=family=inet6
    while read -r cidr; do
        [ -n "$cidr" ] && sudo firewall-cmd --permanent --ipset=cloudflare6 --add-entry="$cidr"
    done < "$V6_FILE"
fi

# The setup scripts open http/https zone-wide (--add-service); drop that
# and replace it with rich rules scoped to the Cloudflare ipsets, using the
# same service names so the allowed ports stay whatever http/https are
# defined as (rather than hardcoding 80/443 a second time).
for RULE in \
    'rule family="ipv4" source ipset="cloudflare4" service name="http" accept' \
    'rule family="ipv4" source ipset="cloudflare4" service name="https" accept' \
    'rule family="ipv6" source ipset="cloudflare6" service name="http" accept' \
    'rule family="ipv6" source ipset="cloudflare6" service name="https" accept'
do
    sudo firewall-cmd --permanent --zone=public --add-rich-rule="$RULE"
done
sudo firewall-cmd --permanent --zone=public --remove-service=http
sudo firewall-cmd --permanent --zone=public --remove-service=https

echo "Reloading firewalld - this flushes conntrack, so any open outbound"
echo "connections (monitoring agents, etc.) drop and reconnect within ~1"
echo "minute. That's expected, not a failure."
sudo firewall-cmd --reload

# Resync script: Cloudflare's ranges rarely change, but when they do, an
# out-of-date ipset either blocks Cloudflare itself or leaves a stale range
# open. Diffs against the live ipset weekly and only adds/removes entries
# (and reloads) when something actually changed.
sudo bash -c "cat > /usr/local/sbin/sync_cloudflare_ips.sh" <<'SCRIPT'
#!/bin/bash
set -e

sync_ipset() {
    local ipset=$1 url=$2 new old added removed changed=1
    new=$(mktemp)
    curl -fs "$url" -o "$new"
    [ -s "$new" ] || { rm -f "$new"; return 1; }
    echo >> "$new"

    old=$(mktemp)
    firewall-cmd --permanent --ipset="$ipset" --get-entries | grep -v '^$' | sort -u > "$old"
    grep -v '^$' "$new" | sort -u -o "$new"

    if cmp -s "$old" "$new"; then
        changed=0
    else
        removed=$(comm -23 "$old" "$new")
        added=$(comm -13 "$old" "$new")
        if [ -n "$removed" ]; then
            while read -r cidr; do
                [ -n "$cidr" ] && firewall-cmd --permanent --ipset="$ipset" --remove-entry="$cidr"
            done <<< "$removed"
        fi
        if [ -n "$added" ]; then
            while read -r cidr; do
                [ -n "$cidr" ] && firewall-cmd --permanent --ipset="$ipset" --add-entry="$cidr"
            done <<< "$added"
        fi
    fi
    rm -f "$new" "$old"
    return $((1 - changed))
}

CHANGED=0
if sync_ipset cloudflare4 https://www.cloudflare.com/ips-v4; then CHANGED=1; fi
if sync_ipset cloudflare6 https://www.cloudflare.com/ips-v6; then CHANGED=1; fi
if [ "$CHANGED" = 1 ]; then firewall-cmd --reload; fi
SCRIPT
sudo chmod +x /usr/local/sbin/sync_cloudflare_ips.sh

echo "17 4 * * 0 root /usr/local/sbin/sync_cloudflare_ips.sh >> /var/log/cloudflare_ips_sync.log 2>&1" | sudo tee /etc/cron.d/sync_cloudflare_ips > /dev/null

MY_IP=$(curl -fs https://ifconfig.me || echo "<VPS_PUBLIC_IP>")
echo "Done. Port 80/443 now only accept connections from Cloudflare's published IP ranges; re-checked weekly via cron."
echo ""
echo "Verify:"
echo "  curl -s -o /dev/null -w '%{http_code}\n' https://<domain>/            # through Cloudflare - should work"
echo "  curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 http://${MY_IP}/  # direct to VPS IP - should time out/fail"
echo ""
echo "If a site stops loading, check whether it's actually proxied through Cloudflare (orange cloud) - if not, either enable the proxy or revert with:"
echo "  sudo firewall-cmd --permanent --zone=public --add-service=http --add-service=https"
echo "  sudo firewall-cmd --permanent --zone=public --remove-rich-rule='rule family=\"ipv4\" source ipset=\"cloudflare4\" service name=\"http\" accept' (repeat for the other 3 rich rules)"
echo "  sudo firewall-cmd --reload"
echo "=========================================="
echo " ALL DONE!"
echo "=========================================="
