#!/bin/sh
# FastCP default PHP CLI: dispatch to the highest installed fcp PHP version's
# php binary. Override with FCP_PHP_VERSION=8.3 php ...
set -e
if [ -n "${FCP_PHP_VERSION:-}" ] && [ -x "/opt/fcp/php/${FCP_PHP_VERSION}/bin/php" ]; then
  exec "/opt/fcp/php/${FCP_PHP_VERSION}/bin/php" "$@"
fi
latest=""
for d in /opt/fcp/php/*/; do
  [ -x "${d}bin/php" ] && latest="${d}bin/php"
done
[ -n "${latest}" ] || { echo "no fcp PHP installed" >&2; exit 1; }
exec "${latest}" "$@"
