#!/usr/bin/env bash
# Stage Composer and WP-CLI (single PHARs) into the FastCP layout.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

install -d "${STAGE}/opt/fcp/bin"

log "fetching composer"
curl -fsSL https://getcomposer.org/download/latest-stable/composer.phar \
  -o "${STAGE}/opt/fcp/bin/composer"
chmod 0755 "${STAGE}/opt/fcp/bin/composer"

log "fetching wp-cli"
curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
  -o "${STAGE}/opt/fcp/bin/wp"
chmod 0755 "${STAGE}/opt/fcp/bin/wp"

log "tools staged under ${STAGE}/opt/fcp/bin"
