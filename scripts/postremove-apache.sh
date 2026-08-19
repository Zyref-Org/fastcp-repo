#!/bin/sh
set -e
if [ "${1:-}" = "purge" ]; then
  rm -rf /etc/apache-fcp
fi
systemctl daemon-reload >/dev/null 2>&1 || true
