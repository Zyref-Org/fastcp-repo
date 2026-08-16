#!/usr/bin/env bash
# Shared setup for FastCP package build scripts. Source this at the top of each.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STAGE="${STAGE:-${REPO}/stage}"
BUILD="${BUILD:-${REPO}/build/work}"
DIST="${DIST:-${REPO}/dist}"
ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

export REPO STAGE BUILD DIST ARCH JOBS

mkdir -p "${STAGE}" "${BUILD}" "${DIST}"

log() { printf '\033[1;34m[build]\033[0m %s\n' "$*"; }

fetch() {
  # fetch URL SHA256 DEST [FALLBACK_URL]
  # A failed download is always fatal (exits the build). Returns 1 only when
  # no checksum is pinned, so callers can log-and-continue; a checksum
  # mismatch on a pinned hash is fatal.
  local url="$1" sha="$2" dest="$3" fallback="${4:-}"
  if [ ! -f "${dest}" ]; then
    log "downloading ${url}"
    if ! curl --fail --location --silent --show-error --output "${dest}" "${url}"; then
      rm -f "${dest}"
      [ -n "${fallback}" ] || { echo "download failed: ${url}" >&2; exit 1; }
      log "primary download failed, trying ${fallback}"
      if ! curl --fail --location --silent --show-error --output "${dest}" "${fallback}"; then
        rm -f "${dest}"
        echo "download failed: ${url} (fallback ${fallback} also failed)" >&2
        exit 1
      fi
    fi
  fi
  case "${sha}" in
    ""|REPLACE_WITH_RELEASE_SHA256) return 1 ;;
  esac
  echo "${sha}  ${dest}" | sha256sum --check --status - \
    || { echo "SHA256 mismatch for ${dest}" >&2; exit 1; }
}
