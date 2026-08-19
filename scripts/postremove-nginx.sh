#!/bin/sh
set -e
if [ "${1:-}" = "purge" ]; then
  rm -rf /etc/nginx-fcp
fi
systemctl daemon-reload >/dev/null 2>&1 || true
