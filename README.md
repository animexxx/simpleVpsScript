# VPS Setup Scripts

Bash scripts to provision a Rocky/AlmaLinux 9-style VPS (dnf, firewalld, SELinux, systemd) for hosting PHP/WordPress sites, either as a single all-in-one box or split into a web tier + DB tier connected over a private network (e.g. Vultr VPC).

All scripts are interactive: run them with no arguments and they prompt for whatever they need (passwords, IPs, domains). Every prompted value can also be passed as an environment variable to run non-interactively, e.g. `ROOT_PASS='...' ./setup_db.sh`.

## Which setup do I want?

| | Single VPS | Split web + DB |
|---|---|---|
| Script | `vps_setup.sh` | `setup_web.sh` + `setup_db.sh` |
| When | One small box, simplest to run | More RAM headroom per role, or planning to add more web servers later against the same DB |
| Extra requirement | None | Two VPS instances on the same private network (VPC), private IPs of each known before you start |

Both paths use `add_new_site.sh` afterwards to add each domain.

---

## Option A — Single VPS (`vps_setup.sh`)

Installs Nginx, PHP-FPM, MariaDB, Redis, phpMyAdmin, Composer, Supervisor, Git, SSH hardening and Fail2Ban all on one box.

```bash
chmod +x vps_setup.sh
sudo ./vps_setup.sh
```

You'll be prompted for the MariaDB root password, then a separate username/password for the basic-auth prompt in front of phpMyAdmin (each asked twice to confirm — the two are kept separate so leaking the basic-auth password doesn't leak the DB root password). It ends with phpMyAdmin reachable at `http://<server-ip>:9119/phpmyadmin`.

⚠️ **Before running:** SSH is hardened to key-only login (`PasswordAuthentication no`) partway through. Make sure your SSH public key is already in `/root/.ssh/authorized_keys` before you start, or you will lock yourself out (see the SSH section below).

---

## Option B — Split web + DB (`setup_web.sh` + `setup_db.sh`)

Two VPS instances on the same private VPC network. MariaDB and Redis live on the DB box only; the web box only runs Nginx/PHP-FPM/phpMyAdmin and talks to the DB box over its private IP.

**Order matters — DB first:**

1. **Create both VPS instances attached to the same Vultr Private Network** (pick it at creation, or attach + reboot after). Note each box's private IP (something like `10.x.x.x`).
2. Confirm they can see each other before installing anything:
   ```bash
   ping <the-other-box's-private-ip>
   ```
3. On the **DB VPS**:
   ```bash
   chmod +x setup_db.sh
   sudo ./setup_db.sh
   ```
   Prompts for: this server's own private IP, the web server's private IP (the only one allowed to connect), and the MariaDB root password. Sets up:
   - MariaDB, bound to the private IP only, `innodb_buffer_pool_size` auto-sized to ~60% of RAM
   - Redis, bound to the private IP only, password auto-generated and saved to `/root/.redis_password`
   - firewalld rules restricting 3306 and 6379 to the web server's private IP specifically (not the whole subnet)
   - nightly backup: one gzip'd `mysqldump --single-transaction --quick` per database (not one combined dump, so restoring a single site is just one file) kept 7 days in `/root/db_backups`
   - slow query log (`/var/log/mariadb/mariadb-slow.log`, queries over 2s) - with several sites sharing one DB server, this is how you find out later which site's queries are the heavy ones (check the `Schema:` field in the log)
   - SSH hardening + Fail2Ban (same as Option A)
4. On the **web VPS**:
   ```bash
   chmod +x setup_web.sh
   sudo ./setup_web.sh
   ```
   Prompts for: the DB server's private IP, and a username/password for the basic-auth prompt in front of phpMyAdmin. Sets up Nginx, PHP-FPM (pool size auto-sized from RAM, see below), phpMyAdmin (pre-configured to connect to the DB box), Composer, Supervisor, SSH hardening, Fail2Ban.

Same SSH warning as Option A applies to both boxes.

### PHP-FPM pool sizing

Both `vps_setup.sh` and `setup_web.sh` size `pm.max_children` (and the related `start/min_spare/max_spare` settings) from total RAM automatically: roughly 10 children per GB (1GB → 10, 2GB → 20, 4GB → 40...). No manual tuning needed; the detected values are printed during the run.

---

## Adding a site (`add_new_site.sh`)

Before running this, point the domain's DNS at the VPS: an A record to the server's public IP (or, if proxied through Cloudflare, an A record with the orange-cloud proxy on — see the HTTPS section below for that case).

Run this once per domain, on the web server (or the single all-in-one box):

```bash
chmod +x add_new_site.sh
sudo ./add_new_site.sh
```

It creates `/home/<domain>`, an Nginx vhost (`server_name <domain> www.<domain>`, so both apex and `www` work), asks whether the site is a **Laravel app** (if yes, the vhost's `root` points to `/home/<domain>/public` instead of `/home/<domain>` — Laravel's own `app/`, `vendor/`, `.env` etc. then stay outside the webroot automatically, since they're not under `public/`), and then offers two optional add-ons:

### HTTPS via a Cloudflare Origin Certificate

Only relevant if the domain is **proxied through Cloudflare** (orange cloud). Not certbot/Let's Encrypt — with Cloudflare in front, the browser↔Cloudflare leg is already HTTPS; what the origin needs is a certificate Cloudflare trusts for the Cloudflare↔VPS leg, which is exactly what an Origin Certificate is for (15-year validity, no renewal cron).

**Adding a subdomain of a site already set up here?** The script always requests both `<domain>` and `*.<domain>` when it creates a certificate, so a subdomain (e.g. `blog.example.com` when `example.com` already has HTTPS enabled) is already covered by the parent's existing wildcard cert. It checks for that automatically — if `/etc/nginx/ssl/<parent-domain>/` already has a cert, it reuses it and skips straight to writing the vhost, with no prompts and no new Cloudflare API call.

Otherwise, two ways the script can get one:
- **Automatic (recommended)**: generates a key + CSR locally and calls the Cloudflare API. Needs a one-time **API Token** from your Cloudflare account: dashboard → *My Profile → API Tokens → Create Token* → custom token with permission **Zone / SSL and Certificates / Edit**, zone resource **All zones** (or a specific zone). The same token is reused for every future domain (export `CF_ORIGIN_CA_KEY` to skip the prompt entirely on future runs). Note: Cloudflare's older "Origin CA Key" is deprecated (removed 2026-09-30) — don't use that, a regular API Token is what this script sends now.
- **Manual fallback**: if you skip the API or it fails, the script asks for the paths to a cert/key you already created via *SSL/TLS → Origin Server → Create Certificate* in the dashboard and saved to the server yourself.

Either way, set Cloudflare's SSL/TLS mode to **Full (strict)** in the dashboard (not Flexible — Flexible leaves the Cloudflare↔VPS leg unencrypted and can cause WordPress redirect loops; if you use it anyway, skip this HTTPS prompt entirely since Cloudflare never talks to the origin over 443 in that mode).

### Git auto-deploy

Push straight from your PC to this VPS — no GitHub involved. Creates a bare repo at `/home/git/<domain>.git` with a `post-receive` hook that checks the code out into `/home/<domain>` and fixes ownership/SELinux context. The script prints the exact `git remote add` command to run on your PC. Requires your PC's SSH key to already be authorized on the VPS (SSH is key-only, see below).

If instead you push to GitHub and want the VPS to pull automatically from there, use a GitHub Actions workflow that SSHes in and runs `git pull` — no extra package needed on the VPS, just a deploy key added to `authorized_keys` and two repo secrets. (Not scripted here since it lives in the app repo, not this one.)

---

## Scaling out: adding another web/app server (`add_db_client.sh`)

If you later add a second web or app VPS that should use the **existing** DB server (same MariaDB + Redis), don't re-run `setup_db.sh`. Instead:

1. Attach the new VPS to the same VPC network, confirm connectivity (`ping`).
2. On the **DB server**:
   ```bash
   chmod +x add_db_client.sh
   sudo ./add_db_client.sh
   ```
   Enter the new server's private IP. It opens firewalld for 3306 + 6379 from that IP and grants a `root@<new-ip>` MySQL account with the same password already in use — it does not touch existing sites/databases, and does not re-create Redis.
3. On the **new VPS**: run `setup_web.sh` if it's another PHP/WordPress box (enter the *existing* DB server's private IP when asked), or just point whatever app you're running at `<DB_PRIVATE_IP>:3306` / `:6379` with the existing credentials if it's not a PHP/Nginx box.

Redis intentionally lives only on the DB server (not per web box) so a growing fleet of web servers still shares one cache instead of each maintaining its own — one instance to monitor, one hit rate to look at, no per-box drift.

### WordPress + shared Redis: avoid cache collisions between sites

If more than one WordPress install shares the same Redis instance (common once you're past one site), each site's `wp-config.php` needs a distinct cache namespace or they will silently read/write each other's cached data:

```php
define( 'WP_REDIS_HOST', '<DB_PRIVATE_IP>' );
define( 'WP_REDIS_PORT', 6379 );
define( 'WP_REDIS_PASSWORD', '<from /root/.redis_password on the DB server>' );
define( 'WP_CACHE_KEY_SALT', 'sitename_' ); // unique per site
```

Check it's actually taking effect: `redis-cli -n 0 --scan | sed 's/:.*//' | sort -u` should show one distinct prefix per site.

---

## Diagnostics — quick reference

Run these on the DB server unless noted otherwise.

**Is the DB server overloaded / close to its connection limit?**
```bash
sudo mysql -e "SHOW GLOBAL STATUS LIKE 'Threads_connected';"
```
Compare against `max_connections` (`sudo mysql -e "SHOW VARIABLES LIKE 'max_connections';"`). Climbing steadily toward it under normal traffic is an early warning sign, not just a spike.

**Is `innodb_buffer_pool_size` actually big enough for the combined working set of every DB on this box?**
```bash
sudo mysql -e "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%';"
```
`Innodb_buffer_pool_reads` (disk reads) staying high relative to `Innodb_buffer_pool_read_requests` (total reads) means the buffer pool is too small and MariaDB is hitting disk a lot — time to add RAM before adding another VPS.

**Which site's queries are the slow ones?**
```bash
sudo mysqldumpslow -s t /var/log/mariadb/mariadb-slow.log   # sorted by total time, worst first
sudo tail -100 /var/log/mariadb/mariadb-slow.log             # raw log; check the "Schema:" field for the DB name
```
Logged once a query takes longer than 2s (`long_query_time` in `setup_db.sh`).

**Is MariaDB/Redis accidentally listening on the public interface?**
```bash
sudo ss -tlnp | grep -E ':(3306|6379)'
```
Should only show the DB server's private VPC IP (and `127.0.0.1` for Redis), never `0.0.0.0` or `*`. `setup_db.sh` checks this automatically right after install and prints a warning if not.

**Are two WordPress sites' Redis caches colliding?** (Run on the web server, or anywhere that can reach Redis)
```bash
redis-cli -h <DB_PRIVATE_IP> -a '<password from /root/.redis_password>' --scan | sed 's/:.*//' | sort | uniq -c | sort -rn
```
Should show one distinct prefix per site with a nonzero count each. A prefix you don't recognize, or two sites sharing one, means `WP_CACHE_KEY_SALT` isn't unique between them (see above).

**Where are the credentials?**
| What | Where |
|---|---|
| MariaDB root password (for scripts/cron, no prompt needed) | `/root/.my.cnf` on the DB server |
| Redis password | `/root/.redis_password` on the DB server |
| Nightly DB backups | `/root/db_backups` on the DB server, one `.sql.gz` per database, 7 days |

---

## Locking down phpMyAdmin further

Basic auth + Fail2Ban stops casual scanners, but Fail2Ban bans by source IP — it does nothing against a botnet/rotating-proxy brute force where every attempt comes from a different address. Two options to close port 9119 to everyone except you, regardless of that:

| Script | Approach | Best when |
|---|---|---|
| `harden_pma_tailscale.sh` | Installs Tailscale, binds the phpMyAdmin vhost to the VPS's Tailscale IP only, removes 9119 from the public firewall entirely | You're OK installing Tailscale on your devices. Simpler, and the port isn't reachable from the public internet at all — recommended if you can. |
| `harden_pma_access.sh` | Restricts port 9119 (still public) to whatever IP a dynamic-DNS hostname you provide currently resolves to, re-checked every minute via cron | You'd rather not install Tailscale, and already have (or are OK setting up) a DDNS hostname (e.g. DuckDNS) tracking your home/mobile IP. |

Run either one on the web VPS after `setup_web.sh`/`vps_setup.sh` has already configured phpMyAdmin.

---

## SSH hardening (all setup scripts)

`vps_setup.sh`, `setup_web.sh`, and `setup_db.sh` all harden SSH the same way: move it to port 2222, `PermitRootLogin prohibit-password` (key-only), `PasswordAuthentication no`.

⚠️ **This has no password fallback.** Before running any of these scripts, make sure your SSH public key is already in `/root/.ssh/authorized_keys` on that VPS (e.g. via `ssh-copy-id`, or however your VPS provider lets you inject a key at creation). If you're SSHed in with a password to run the script, add your key first — otherwise you'll be locked out and need your provider's rescue/console access to recover.

---

## Utility scripts

- **`chmod.sh`** — re-applies `nginx:nginx` ownership and SELinux context to `/home` and the PHP session directory. Handy if permissions get out of sync (e.g. after editing files as a different user over SFTP).

---

## File reference

| File | Run on | Purpose |
|---|---|---|
| `vps_setup.sh` | Single VPS | Full LEMP + Redis + phpMyAdmin + hardening, all-in-one |
| `setup_web.sh` | Web VPS | Nginx + PHP-FPM + phpMyAdmin + hardening, no DB |
| `setup_db.sh` | DB VPS | MariaDB + Redis + hardening, no web server |
| `add_new_site.sh` | Web VPS | Add a domain's vhost, optional Cloudflare HTTPS, optional git deploy |
| `add_db_client.sh` | DB VPS | Whitelist another web/app VPS against the existing DB + Redis |
| `harden_pma_tailscale.sh` | Web VPS | Restrict phpMyAdmin to your Tailscale network |
| `harden_pma_access.sh` | Web VPS | Restrict phpMyAdmin to a DDNS hostname's current IP |
| `chmod.sh` | Any | Reset `/home` ownership/SELinux context |
