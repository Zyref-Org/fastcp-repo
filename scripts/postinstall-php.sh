#!/bin/sh
# Enable a versioned PHP-FPM instance (fcp-php-fpm@<ver>) for every installed
# /opt/fcp/php/<ver>. The agent reloads instances by that exact unit name.
set -e
install -d -m 0755 /run/fcp /var/log/fcp
systemctl daemon-reload || true
for dir in /opt/fcp/php/*/; do
  [ -d "$dir" ] || continue
  ver=$(basename "$dir")
  # pool.d holds agent-written per-app pools; conf.d holds extension/ini
  # drop-ins. Ensure both exist even if the package tree omitted empty dirs.
  install -d -m 0755 "${dir}etc/pool.d" "${dir}etc/conf.d"
  # Clean up the broken alias symlinks shipped by earlier releases (a
  # template unit cannot be loaded under a non-instance name).
  rm -f "/etc/systemd/system/fcp-php${ver}-fpm.service"
  systemctl enable "fcp-php-fpm@${ver}.service" || true
  systemctl restart "fcp-php-fpm@${ver}.service" || true
done
systemctl daemon-reload || true
