#!/bin/sh
set -e
systemctl daemon-reload || true
# Create /run/fcp now rather than at the next boot, so the services can start
# straight after install.
systemd-tmpfiles --create /usr/lib/tmpfiles.d/fcp.conf || true
