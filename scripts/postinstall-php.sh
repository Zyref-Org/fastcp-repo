#!/bin/sh
# Enable a versioned PHP-FPM service for every installed /opt/fcp/php/<ver>.
# The agent reloads a specific version via `systemctl reload fcp-php<ver>-fpm`,
# so we create that alias symlink to the templated instance unit.
set -e
install -d -m 0755 /run/fcp
systemctl daemon-reload || true
for dir in /opt/fcp/php/*/; do
  [ -d "$dir" ] || continue
  ver=$(basename "$dir")
  # pool.d holds agent-written per-app pools; conf.d holds extension/ini
  # drop-ins. Ensure both exist even if the package tree omitted empty dirs.
  install -d -m 0755 "${dir}etc/pool.d" "${dir}etc/conf.d"
  ln -sf /etc/systemd/system/fcp-php-fpm@.service \
    "/etc/systemd/system/fcp-php${ver}-fpm.service" 2>/dev/null || true
  systemctl enable "fcp-php-fpm@${ver}.service" || true
  systemctl restart "fcp-php-fpm@${ver}.service" || true
done
systemctl daemon-reload || true
