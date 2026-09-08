#!/bin/bash
# Add git auto-deploy to a site that ALREADY exists on this server (one created
# before add_new_site.sh had the git option, or where you answered "n" then).
# Same mechanism as add_new_site.sh: a bare repo you push to over SSH, whose
# post-receive hook checks the code out straight into the site's directory.
set -e

echo "Enter the existing site's domain:"
read -r domain
if [ -z "$domain" ]; then
    echo "A domain is required. Aborting." >&2
    exit 1
fi

WORK_TREE="/home/$domain"
GIT_DIR="/home/git/$domain.git"

if [ ! -d "$WORK_TREE" ]; then
    echo "$WORK_TREE does not exist - this script is for sites already set up here." >&2
    echo "Use add_new_site.sh to create a brand new site." >&2
    exit 1
fi

if sudo test -d "$GIT_DIR"; then
    echo "$GIT_DIR already exists - git deploy looks set up already. Re-writing the hook, leaving the repo as is."
else
    sudo mkdir -p "$GIT_DIR"
    sudo git init --bare -q "$GIT_DIR"
    # Force HEAD to main regardless of this system's git default branch (still
    # "master" on plenty of distros) - otherwise the first push creates
    # refs/heads/main with real commits while HEAD still points at the empty
    # "master" that never gets pushed, and the hook's checkout below fails
    # with "yet to be born" trying to check out that empty branch.
    sudo git symbolic-ref HEAD refs/heads/main
fi

sudo bash -c "cat > $GIT_DIR/hooks/post-receive" <<HOOK
#!/bin/bash
set -e
git --work-tree=$WORK_TREE --git-dir=$GIT_DIR checkout -f main
chown -R nginx:nginx $WORK_TREE
chcon -R -t httpd_sys_rw_content_t $WORK_TREE 2>/dev/null || true
echo "Deployed \$(date) -> $WORK_TREE"
HOOK
sudo chmod +x "$GIT_DIR/hooks/post-receive"

SSH_PORT=$(sudo sed -n 's/^Port //p' /etc/ssh/sshd_config | head -1)
SSH_PORT=${SSH_PORT:-22}
SERVER_IP=$(curl -s ifconfig.me || hostname -I | awk '{print $1}')

echo
echo "Git deploy ready for $domain. On your PC, inside the project repo, run:"
echo "  git remote add production ssh://root@${SERVER_IP}:${SSH_PORT}${GIT_DIR}"
echo "  git push production main"
echo
echo "Note: the first push runs 'checkout -f' into $WORK_TREE - files tracked in"
echo "your repo overwrite what's there now; untracked files already on the server"
echo "(uploads, .env, wp-config.php, vendor/, etc.) are left alone."
echo
echo "=========================================="
echo " ALL DONE!"
echo "=========================================="
