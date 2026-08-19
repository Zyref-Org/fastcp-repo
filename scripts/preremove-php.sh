#!/bin/sh
set -e
case "${1:-}" in
  remove|purge)
    ver="${DPKG_MAINTSCRIPT_PACKAGE#fcp-php}"
    [ -n "${ver}" ] && [ "${ver}" != "${DPKG_MAINTSCRIPT_PACKAGE}" ] || exit 0
    systemctl stop "fcp-php-fpm@${ver}.service" || true
    systemctl disable "fcp-php-fpm@${ver}.service" || true
    ;;
esac
