#!/bin/sh
set -e
# Expose `php` on the system PATH via /usr/local/bin (kept off Ubuntu's php).
ln -sf /opt/fcp/bin/php /usr/local/bin/php 2>/dev/null || true
