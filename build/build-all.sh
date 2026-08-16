#!/usr/bin/env bash
# Build and package the FastCP web stack (nginx, apache, PHP-FPM, composer,
# wp-cli, php-cli) into dist/. Run on an adequately sized Ubuntu build host
# (>= 4 GB RAM recommended for PHP builds) with build-essential and the -dev
# libraries installed (see install-build-deps.sh). Set the *_SHA256 env vars in
# the individual build scripts to pin verified release hashes.
#
# The fastcp-agent package is built and published by the agent's own repo.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PHP_VERSIONS="${PHP_VERSIONS:-8.1 8.2 8.3 8.4 8.5}"
declare -A PHP_FULL=(
  [8.1]="${PHP_8_1:-8.1.31}"
  [8.2]="${PHP_8_2:-8.2.27}"
  [8.3]="${PHP_8_3:-8.3.15}"
  [8.4]="${PHP_8_4:-8.4.2}"
  [8.5]="${PHP_8_5:-8.5.0}"
)

command -v nfpm >/dev/null 2>&1 || { echo "nfpm missing; run bootstrap-tools.sh" >&2; exit 1; }

log "building nginx"
"${REPO}/build/build-nginx.sh"
"${REPO}/build/package.sh" fcp-nginx

log "building apache"
"${REPO}/build/build-apache.sh"
"${REPO}/build/package.sh" fcp-apache

for v in ${PHP_VERSIONS}; do
  full="${PHP_FULL[$v]:-${v}.0}"
  log "building php ${full}"
  PHP_VERSION="${v}" PHP_FULL_VERSION="${full}" "${REPO}/build/build-php.sh"
  PHP_VERSION="${v}" PHP_FULL_VERSION="${full}" "${REPO}/build/package.sh" fcp-php
done

log "staging tools (composer, wp-cli)"
"${REPO}/build/build-tools.sh"
COMPOSER_VERSION="${COMPOSER_VERSION:-2.8.0}" "${REPO}/build/package.sh" fcp-composer
WPCLI_VERSION="${WPCLI_VERSION:-2.11.0}" "${REPO}/build/package.sh" fcp-wp-cli
PHPCLI_VERSION="${PHPCLI_VERSION:-1.0.0}" "${REPO}/build/package.sh" fcp-php-cli

log "all packages built:"
ls -1 "${DIST}"/*.deb 2>/dev/null || true
