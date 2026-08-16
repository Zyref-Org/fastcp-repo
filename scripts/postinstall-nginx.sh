#!/bin/sh
set -e
install -d -m 0755 /run/fcp /var/log/fcp /etc/nginx-fcp/vhosts.d
systemctl daemon-reload || true
systemctl enable fcp-nginx.service || true
systemctl restart fcp-nginx.service || true
