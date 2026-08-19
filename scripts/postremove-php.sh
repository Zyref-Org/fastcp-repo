#!/bin/sh
set -e
if [ "${1:-}" = "purge" ]; then
  ver="${DPKG_MAINTSCRIPT_PACKAGE#fcp-php}"
  if [ -n "${ver}" ] && [ "${ver}" != "${DPKG_MAINTSCRIPT_PACKAGE}" ]; then
    rm -rf "/opt/fcp/php/${ver}"
  fi
fi
systemctl daemon-reload >/dev/null 2>&1 || true
