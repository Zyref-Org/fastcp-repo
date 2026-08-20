#!/usr/bin/env bash
# Build and package the FastCP web stack (nginx, apache, PHP-FPM, composer,
# wp-cli, php-cli) into dist/. Run on an adequately sized Ubuntu build host
# (>= 4 GB RAM recommended for PHP builds) with build-essential and the -dev
# libraries installed (see install-build-deps.sh).
#
# Versions and SHA256 pins below track the latest upstream releases; when
# bumping a version, update its checksum from the upstream announcement.
# The fastcp-agent package is built and published by the agent's own repo.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PHP_VERSIONS="${PHP_VERSIONS:-8.2 8.3 8.4 8.5}"
declare -A PHP_FULL_DEFAULT=(
  [8.1]="8.1.34"
  [8.2]="8.2.33"
  [8.3]="8.3.33"
  [8.4]="8.4.24"
  [8.5]="8.5.9"
)
# SHA256 of php-<ver>.tar.gz from php.net for the default versions above.
declare -A PHP_SHA_DEFAULT=(
  [8.1]="3c5b060ec8e0d5dd1d8237823f3161cc8bc5342aab3c46893eba9857759c4bfa"
  [8.2]="9a525d4db1237ede408e454b46f5a93b9e45d83d71753592e3f921903d917e07"
  [8.3]="f43566da482abeb1614a512dabeda74967847ce8e176a977390d7a115e7812fd"
  [8.4]="d5fe6a1d7633e70645dc757461eeb7b764ff6a04d0487f076dd56f1f9d8059db"
  [8.5]="d735459c2cbaeb0673d416c33d372d9ff261d562f6b29da48f3e6aeaeca083af"
)
declare -A PHP_FULL=(
  [8.1]="${PHP_8_1:-${PHP_FULL_DEFAULT[8.1]}}"
  [8.2]="${PHP_8_2:-${PHP_FULL_DEFAULT[8.2]}}"
  [8.3]="${PHP_8_3:-${PHP_FULL_DEFAULT[8.3]}}"
  [8.4]="${PHP_8_4:-${PHP_FULL_DEFAULT[8.4]}}"
  [8.5]="${PHP_8_5:-${PHP_FULL_DEFAULT[8.5]}}"
)

command -v nfpm >/dev/null 2>&1 || { echo "nfpm missing; run bootstrap-tools.sh" >&2; exit 1; }

log "building nginx"
"${REPO}/build/build-nginx.sh"
"${REPO}/build/package.sh" fcp-nginx

log "building apache"
"${REPO}/build/build-apache.sh"
"${REPO}/build/package.sh" fcp-apache

log "packaging fcp-php-common"
PHPCOMMON_VERSION="${PHPCOMMON_VERSION:-1.0.0}" "${REPO}/build/package.sh" fcp-php-common

for v in ${PHP_VERSIONS}; do
  full="${PHP_FULL[$v]:-${v}.0}"
  # The pinned checksum only applies to the default version; overridden
  # versions build unpinned unless PHP_SHA256 is supplied by the caller.
  sha="${PHP_SHA256:-}"
  if [ -z "${sha}" ] && [ "${full}" = "${PHP_FULL_DEFAULT[$v]:-}" ]; then
    sha="${PHP_SHA_DEFAULT[$v]}"
  fi
  log "building php ${full}"
  PHP_VERSION="${v}" PHP_FULL_VERSION="${full}" PHP_SHA256="${sha}" \
    "${REPO}/build/build-php.sh"
  PHP_VERSION="${v}" PHP_FULL_VERSION="${full}" "${REPO}/build/package.sh" fcp-php
done

log "staging tools (composer, wp-cli)"
"${REPO}/build/build-tools.sh"
COMPOSER_VERSION="${COMPOSER_VERSION:-2.10.2}" "${REPO}/build/package.sh" fcp-composer
WPCLI_VERSION="${WPCLI_VERSION:-2.12.0}" "${REPO}/build/package.sh" fcp-wp-cli
PHPCLI_VERSION="${PHPCLI_VERSION:-1.0.0}" "${REPO}/build/package.sh" fcp-php-cli
MYSQL_CONFIG_VERSION="${MYSQL_CONFIG_VERSION:-1.0.1}" "${REPO}/build/package.sh" fcp-mysql

log "all packages built:"
ls -1 "${DIST}"/*.deb 2>/dev/null || true
