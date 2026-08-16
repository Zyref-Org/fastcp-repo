#!/bin/sh
set -e
for dir in /opt/fcp/php/*/; do
  [ -d "$dir" ] || continue
  ver=$(basename "$dir")
  systemctl stop "fcp-php-fpm@${ver}.service" || true
  systemctl disable "fcp-php-fpm@${ver}.service" || true
  rm -f "/etc/systemd/system/fcp-php${ver}-fpm.service" || true
done
