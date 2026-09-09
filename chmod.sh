#!/bin/bash
set -e
chown -R nginx:nginx /home/
chcon -R -t httpd_sys_rw_content_t /home/
# Bare git repos under /home/git are pushed to as root over SSH and must stay
# root-owned - the recursive chown above just swept them to nginx, undo that
# or the next `git push` fails with "detected dubious ownership in repository".
[ -d /home/git ] && chown -R root:root /home/git
chown -R nginx:nginx /var/lib/php/session/