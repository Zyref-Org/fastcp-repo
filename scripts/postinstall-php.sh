#!/bin/sh
# Enable a versioned PHP-FPM instance (fcp-php-fpm@<ver>) for every installed
# /opt/fcp/php/<ver>. The agent reloads instances by that exact unit name.
set -e
install -d -m 0755 /run/fcp /var/log/fcp
systemctl daemon-reload
pkg_ver="${DPKG_MAINTSCRIPT_PACKAGE#fcp-php}"
if [ -n "${pkg_ver}" ] && [ "${pkg_ver}" != "${DPKG_MAINTSCRIPT_PACKAGE:-}" ]; then
  dirs="/opt/fcp/php/${pkg_ver}/"
else
  dirs="/opt/fcp/php/*/"
fi
for dir in ${dirs}; do
  [ -d "$dir" ] || continue
  ver=$(basename "$dir")
  # pool.d holds agent-written per-app pools; conf.d holds extension/ini
  # drop-ins. Ensure both exist even if the package tree omitted empty dirs.
  install -d -m 0755 "${dir}etc/pool.d" "${dir}etc/conf.d"
  # Clean up the broken alias symlinks shipped by earlier releases (a
  # template unit cannot be loaded under a non-instance name).
  rm -f "/etc/systemd/system/fcp-php${ver}-fpm.service"
  "${dir}sbin/php-fpm" -t -y "${dir}etc/php-fpm.conf"
  systemctl enable "fcp-php-fpm@${ver}.service"
  systemctl reload-or-restart "fcp-php-fpm@${ver}.service"
done
systemctl daemon-reload
