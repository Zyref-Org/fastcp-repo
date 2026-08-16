#!/bin/sh
set -e
install -d -m 0755 /run/fcp /etc/apache-fcp/vhosts.d
systemctl daemon-reload || true
systemctl enable fcp-apache.service || true
systemctl restart fcp-apache.service || true
