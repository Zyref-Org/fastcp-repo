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
export PHPCOMMON_VERSION="${PHPCOMMON_VERSION:-1.0.0}"

if ! command -v nfpm >/dev/null 2>&1; then
  echo "nfpm not found; run build/bootstrap-tools.sh" >&2
  exit 1
fi
if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found (apt: gettext-base, brew: gettext)" >&2
  exit 1
fi

# auto_deps computes the exact runtime package dependencies of the staged
# binaries by resolving their linked shared libraries to dpkg package names.
# Builds run on the target codename, so the names are correct per release —
# no more hand-maintained (and codename-fragile) dependency lists.
auto_deps() {
  if ! command -v ldd >/dev/null 2>&1 || ! command -v dpkg >/dev/null 2>&1; then
    echo "libc6" # local lint builds on non-Debian hosts
    return
  fi
  local links missing out
  links=$(find "$@" -type f \( -perm -u+x -o -name '*.so*' \) 2>/dev/null \
    | while read -r bin; do ldd "${bin}" 2>/dev/null || true; done)
  # A library the linker cannot resolve would ship a package that is broken
  # at runtime (fcp-php 0.1.3 shipped without a libzip dependency this way).
  missing=$(printf '%s\n' "${links}" | grep 'not found' | sort -u || true)
  if [ -n "${missing}" ]; then
    printf 'auto_deps: unresolved shared libraries on the build host:\n%s\n' "${missing}" >&2
    exit 1
  fi
  # ldd reports usr-merge alias paths (/lib/...) and ldconfig-created .so.N
  # symlinks; dpkg's file database records /usr/lib/... real files, so a raw
  # `dpkg -S` on ldd output matches nothing. realpath resolves both. Libraries
  # staged under /opt/fcp ship inside our own packages and need no dependency.
  out=$(printf '%s\n' "${links}" | awk '/=> \//{print $3}' | sort -u \
    | while read -r lib; do realpath "${lib}" 2>/dev/null || true; done \
    | sort -u | grep -v '^/opt/fcp/' \
    | xargs -r dpkg -S 2>/dev/null \
    | cut -d: -f1 | sort -u | paste -sd, - | sed 's/,/, /g')
  echo "${out:-libc6}"
}

case "${recipe}" in
  fcp-nginx)  FCP_AUTO_DEPS="$(auto_deps "${STAGE}/opt/fcp/nginx/sbin")" ;;
  fcp-apache) FCP_AUTO_DEPS="$(auto_deps "${STAGE}/opt/fcp/apache/bin" "${STAGE}/opt/fcp/apache/modules")" ;;
  fcp-php)    FCP_AUTO_DEPS="$(auto_deps "${STAGE}/opt/fcp/php/${PHP_VERSION}/bin" "${STAGE}/opt/fcp/php/${PHP_VERSION}/sbin")" ;;
  *)          FCP_AUTO_DEPS="libc6" ;;
esac
export FCP_AUTO_DEPS
log "computed deps for ${recipe}: ${FCP_AUTO_DEPS}"

# Compiled servers link against far more than libc; a near-empty result means
# dependency resolution regressed (see auto_deps), which previously shipped
# packages whose services could not start. Refuse to package.
case "${recipe}" in
  fcp-nginx|fcp-apache|fcp-php)
    dep_count=$(printf '%s' "${FCP_AUTO_DEPS}" | tr ',' '\n' | wc -l | tr -d ' ')
    if [ "${dep_count}" -lt 3 ]; then
      echo "auto_deps computed implausibly few dependencies for ${recipe}: ${FCP_AUTO_DEPS}" >&2
      exit 1
    fi
    ;;
esac

# nfpm does not expand env vars in its config, so render the ${VAR}
# placeholders first. Only the listed variables are substituted.
rendered="$(mktemp)"
trap 'rm -f "${rendered}"' EXIT
envsubst '${ARCH} ${STAGE} ${REPO} ${CODENAME} ${FCP_AUTO_DEPS} ${PHP_VERSION} ${PHP_FULL_VERSION} ${NGINX_VERSION} ${APACHE_VERSION} ${COMPOSER_VERSION} ${WPCLI_VERSION} ${PHPCLI_VERSION} ${PHPCOMMON_VERSION}' \
  < "${config}" > "${rendered}"

log "packaging ${recipe} -> ${DIST}"
nfpm package --config "${rendered}" --packager deb --target "${DIST}/"
log "done: $(ls -1 "${DIST}"/*.deb 2>/dev/null | tail -n1)"
