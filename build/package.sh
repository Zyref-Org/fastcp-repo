#!/usr/bin/env bash
# Build a .deb from a staged tree using nfpm. Usage: package.sh <recipe-name>
# where recipe-name is one of: fcp-nginx fcp-apache fcp-php fcp-composer
# fcp-wp-cli fcp-php-cli.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

recipe="${1:?usage: package.sh <fcp-nginx|fcp-apache|fcp-php|fcp-composer|fcp-wp-cli|fcp-php-cli>}"
config="${REPO}/nfpm/${recipe}.yaml"
[ -f "${config}" ] || { echo "no recipe ${config}" >&2; exit 1; }

# Packages carry a per-codename release suffix (e.g. 1.30.4-1~noble) because
# each Ubuntu release gets its own binaries; identical filenames with
# different contents would collide in the shared aptly publish pool.
if [ -z "${CODENAME:-}" ]; then
  CODENAME="$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}")"
  CODENAME="${CODENAME:-local}"
fi
export CODENAME

# Version defaults so recipes resolve even for a quick lint/build. Keep in
# sync with build-all.sh and the build-*.sh scripts.
export NGINX_VERSION="${NGINX_VERSION:-1.30.4}"
export APACHE_VERSION="${APACHE_VERSION:-2.4.68}"
export PHP_VERSION="${PHP_VERSION:-8.3}"
export PHP_FULL_VERSION="${PHP_FULL_VERSION:-8.3.33}"
export COMPOSER_VERSION="${COMPOSER_VERSION:-2.10.2}"
export WPCLI_VERSION="${WPCLI_VERSION:-2.12.0}"
export PHPCLI_VERSION="${PHPCLI_VERSION:-1.0.0}"

if ! command -v nfpm >/dev/null 2>&1; then
  echo "nfpm not found; run build/bootstrap-tools.sh" >&2
  exit 1
fi
if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found (apt: gettext-base, brew: gettext)" >&2
  exit 1
fi

# nfpm does not expand env vars in its config, so render the ${VAR}
# placeholders first. Only the listed variables are substituted.
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT
envsubst '${ARCH} ${STAGE} ${REPO} ${CODENAME} ${PHP_VERSION} ${PHP_FULL_VERSION} ${NGINX_VERSION} ${APACHE_VERSION} ${COMPOSER_VERSION} ${WPCLI_VERSION} ${PHPCLI_VERSION}' \
  < "${config}" > "${rendered}"

log "packaging ${recipe} -> ${DIST}"
nfpm package --config "${rendered}" --packager deb --target "${DIST}/"
log "done: $(ls -1 "${DIST}"/*.deb 2>/dev/null | tail -n1)"
