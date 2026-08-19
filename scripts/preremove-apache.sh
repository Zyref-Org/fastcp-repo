#!/bin/sh
set -e
case "${1:-}" in
  remove|purge)
    systemctl stop fcp-apache.service || true
    systemctl disable fcp-apache.service || true
    ;;
esac
