#!/bin/sh
set -e
case "${1:-}" in
  remove|purge)
    systemctl stop fcp-nginx.service || true
    systemctl disable fcp-nginx.service || true
    ;;
esac
