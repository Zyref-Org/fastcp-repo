#!/usr/bin/env bash
# Stage Composer and WP-CLI (single PHARs) into the FastCP layout, pinned to
# exact versions with SHA256 verification so the package version labels match
# the shipped binaries.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

COMPOSER_VERSION="${COMPOSER_VERSION:-2.10.2}"
COMPOSER_SHA256="${COMPOSER_SHA256:-5ee7125f8a30a34d246cefdc0bc85b8a783b28f2aec968994118512350d28027}"
WPCLI_VERSION="${WPCLI_VERSION:-2.12.0}"
WPCLI_SHA256="${WPCLI_SHA256:-ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c}"

install -d "${STAGE}/opt/fcp/bin"
# The phar targets are not version-named, so drop any stale staged copies to
# make sure the pinned versions are actually what gets fetched and verified.
rm -f "${STAGE}/opt/fcp/bin/composer" "${STAGE}/opt/fcp/bin/wp"

log "fetching composer ${COMPOSER_VERSION}"
fetch "https://getcomposer.org/download/${COMPOSER_VERSION}/composer.phar" \
  "${COMPOSER_SHA256}" "${STAGE}/opt/fcp/bin/composer" \
  "https://github.com/composer/composer/releases/download/${COMPOSER_VERSION}/composer.phar" \
  || log "checksum not pinned: set COMPOSER_SHA256 for a verified build"
chmod 0755 "${STAGE}/opt/fcp/bin/composer"

log "fetching wp-cli ${WPCLI_VERSION}"
fetch "https://github.com/wp-cli/wp-cli/releases/download/v${WPCLI_VERSION}/wp-cli-${WPCLI_VERSION}.phar" \
  "${WPCLI_SHA256}" "${STAGE}/opt/fcp/bin/wp" \
  || log "checksum not pinned: set WPCLI_SHA256 for a verified build"
chmod 0755 "${STAGE}/opt/fcp/bin/wp"

log "tools staged under ${STAGE}/opt/fcp/bin"
