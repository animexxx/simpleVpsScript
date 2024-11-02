**Simple VPS Setup Script**
A comprehensive setup script for deploying essential services on a fresh VPS, including:

- LEMP Stack: Nginx, MariaDB, and PHP
- phpMyAdmin (on port 9119)
- SSH hardening: Configures a non-standard SSH port and disables root login
- Fail2Ban: Protects against brute-force attacks
- Supervisor: Manages processes
- Git: Version control system

**Instructions to Run:**
1. Deploy a new VPS instance.
2. SSH into the VPS and download this script.
3. Run chmod +x on the script to make it executable.
4. IMPORTANT: Change ROOT_PASS at the top of the file to set a secure root password for MariaDB and phpMyAdmin.
5. Run the script as root.
6. Access phpMyAdmin at http://your-ip:9119 using root and the ROOT_PASS as credentials.
