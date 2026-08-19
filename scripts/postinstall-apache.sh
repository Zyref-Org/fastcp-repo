#!/bin/sh
set -e
install -d -m 0755 /run/fcp /var/log/fcp /etc/apache-fcp/vhosts.d
systemctl daemon-reload
systemctl enable fcp-apache.service
/opt/fcp/apache/bin/httpd -t -f /etc/apache-fcp/httpd.conf
if systemctl is-active --quiet fcp-apache.service; then
  systemctl reload fcp-apache.service
else
  systemctl start fcp-apache.service
fi
