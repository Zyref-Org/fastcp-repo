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
  # fetch URL SHA256 DEST
  local url="$1" sha="$2" dest="$3"
  if [ ! -f "${dest}" ]; then
    log "downloading ${url}"
    curl --fail --location --silent --show-error --output "${dest}" "${url}"
  fi
  echo "${sha}  ${dest}" | sha256sum --check -
}
