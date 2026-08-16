#!/bin/sh
set -e
systemctl stop fcp-nginx.service || true
systemctl disable fcp-nginx.service || true
