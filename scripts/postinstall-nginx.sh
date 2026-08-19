#!/bin/sh
set -e
install -d -m 0755 /run/fcp /var/log/fcp /etc/nginx-fcp/vhosts.d
systemctl daemon-reload
systemctl enable fcp-nginx.service
/opt/fcp/nginx/sbin/nginx -t -c /etc/nginx-fcp/nginx.conf
if systemctl is-active --quiet fcp-nginx.service; then
  systemctl reload fcp-nginx.service
else
  systemctl start fcp-nginx.service
fi
