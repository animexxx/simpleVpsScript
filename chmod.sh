#!/bin/bash
set -e
chown -R nginx:nginx /home/
chcon -R -t httpd_sys_rw_content_t /home/
chown -R nginx:nginx /var/lib/php/session/