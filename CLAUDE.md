# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A set of standalone, interactive Bash scripts that provision Rocky/AlmaLinux 9-style VPS boxes (dnf, firewalld, SELinux, systemd) for hosting PHP/WordPress/Laravel sites — either one all-in-one server or a web tier + DB tier split over a private network (e.g. Vultr VPC). There is no build system, package manager, or test suite; the "deployable unit" is each `.sh` file, run directly on a target VPS with `sudo`.

Read `README.md` before making changes — it is the authoritative, detailed spec for what each script does and why (SSH hardening order, PHP-FPM sizing formula, Redis cache-key collisions, Cloudflare Origin Cert flow, diagnostics commands). Keep it in sync with any script change; this file only covers things not already there.

## No build/lint/test commands

There is nothing to build or unit test. "Testing" a change means running the script against a real or throwaway VPS (or reading it very carefully). When editing a script, at minimum:
```bash
bash -n script.sh        # syntax check
shellcheck script.sh     # if shellcheck is available locally
```

## Script conventions (apply to every script here)

- **Interactive by default, scriptable via env vars.** Every prompted value (passwords, IPs, domains, tokens) is read only `if [ -z "${VAR:-}" ]`, so any script can be driven non-interactively by exporting the same-named var first (e.g. `ROOT_PASS='...' ./setup_db.sh`). When adding a new prompt, follow this exact pattern rather than inventing a new flag style.
- Passwords are prompted twice (`read -rsp`) and compared before proceeding; loop until they match. Unrelated secrets (e.g. MySQL root password vs. phpMyAdmin basic-auth password) are kept in separate variables/prompts so leaking one doesn't leak the other.
- Scripts assume Rocky/AlmaLinux 9 with `dnf`, `firewalld`, and SELinux enforcing — changes should keep using `dnf`, `firewall-cmd`, and `semanage`/`restorecon` rather than Debian/Ubuntu equivalents (`apt`, `ufw`).
- SELinux and firewalld are treated as first-class, not disabled: file changes under web-served paths need `restorecon`/`semanage fcontext`, and new listening ports need explicit `firewall-cmd` rules (scoped to a specific private IP where the traffic should only come from one other box, not the whole subnet).
- Scripts are meant to be safely re-run for the same site/domain: crontab entries are tagged with a `# <domain>` comment and guarded with `grep -qF` before appending, so re-running doesn't duplicate them; certificate/config generation checks for existing files (e.g. an existing wildcard cert dir) before regenerating.
- `set -e` plus `exec > >(tee -i /var/log/setup.log); exec 2>&1` near the top of the big setup scripts — output is both shown and logged. Preserve this if restructuring the top of a script.
- PHP-FPM pool sizing (`pm.max_children` etc., in `vps_setup.sh` and `setup_web.sh`) is derived from detected RAM (`/proc/meminfo`), not hardcoded — roughly 10 children per GB. If you touch this logic, keep it RAM-driven and keep the printed "Detected NMB RAM -> ..." line so the run stays self-documenting.
- Split-topology scripts (`setup_web.sh`, `setup_db.sh`, `add_db_client.sh`) bind services (MariaDB, Redis) to the private VPC IP only, never `0.0.0.0`, and firewalld rules restrict the DB ports to the specific peer IP(s) provided at prompt time — don't loosen this to a subnet-wide rule.

## Architecture: how the scripts relate

Two provisioning paths, both followed by per-domain setup:

- **Single VPS**: `vps_setup.sh` — installs everything (Nginx, PHP-FPM, MariaDB, Redis, phpMyAdmin, Composer, Supervisor, Git, SSH hardening, Fail2Ban) on one box.
- **Split web + DB**: `setup_db.sh` (run first, on the DB box: MariaDB + Redis + firewalld rules scoped to the web box's private IP + nightly per-database backups + slow query log + SSH hardening) and `setup_web.sh` (on the web box: Nginx + PHP-FPM + phpMyAdmin pointed at the DB box's private IP + Composer + Supervisor + SSH hardening). Order matters — DB first, since the web box needs the DB's private IP at prompt time.

Then, regardless of path, on the web box:

- `add_new_site.sh` — run once per domain. Creates `/home/<domain>`, an Nginx vhost, detects Laravel (webroot → `public/`) vs. plain/WordPress, wires the matching cron job into root's crontab (not `/etc/cron.d`), and offers two independent add-ons: Cloudflare Origin Certificate HTTPS (reuses a parent domain's wildcard cert for subdomains automatically) and git push-to-deploy (bare repo + `post-receive` hook).
- `add_git_deploy.sh` — same git push-to-deploy add-on as above, but for a site that already exists (no vhost recreation).
- `add_db_client.sh` — run on the DB box when adding a *new* web/app server against an *existing* DB server: whitelists the new server's private IP for MariaDB/Redis and grants a matching MySQL account, without touching existing sites or re-provisioning Redis. Redis intentionally stays single-instance on the DB box even as web servers scale out.
- `harden_pma_tailscale.sh` / `harden_pma_access.sh` — mutually-exclusive follow-ups to further lock down the phpMyAdmin port (9119) beyond basic-auth + Fail2Ban: either move it onto a Tailscale-only interface, or restrict the public port to whatever IP a DDNS hostname currently resolves to (re-checked every minute via cron).
- `chmod.sh` — utility to re-apply `nginx:nginx` ownership + SELinux context under `/home` and the PHP session dir; not part of the provisioning flow, just a repair tool.

## Things that need the README updated in lockstep

- Any change to prompted variables/env-var names (README documents each script's exact prompts).
- Any change to the SSH hardening behavior (port 2222, key-only) — README has a standalone warning about locking yourself out.
- Any change to where credentials end up (`/root/.my.cnf`, `/root/.redis_password`) — README's "Where are the credentials?" table.
- Any change to the diagnostics one-liners in the README's "Diagnostics" section if the underlying config they inspect changes (e.g. `long_query_time`, `innodb_buffer_pool_size` sizing, Redis key prefixing scheme).
