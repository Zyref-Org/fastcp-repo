#!/bin/sh
set -e
case "${1:-}" in
  remove|purge)
    systemctl disable fcp-mysql-tune.service >/dev/null 2>&1 || true
    ;;
esac
if [ "${1:-}" = "purge" ]; then
  rm -f /etc/mysql/mysql.conf.d/91-fastcp-autotune.cnf \
    /etc/mysql/mysql.conf.d/91-fastcp-autotune.cnf.last-good
fi
systemctl daemon-reload >/dev/null 2>&1 || true
