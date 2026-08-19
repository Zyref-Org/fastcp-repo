#!/usr/bin/env bash
# Run the FastCP smoke test against the *published* APT repository, exactly as
# a customer server would install it. Run as root on a fresh Ubuntu host.
#
# Env:
#   FCP_REPO_URL   default https://repo.fastcp.io
set -euo pipefail

REPO_URL="${FCP_REPO_URL:-https://repo.fastcp.io}"
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq >/dev/null 2>&1 || apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl gnupg >/dev/null

curl -fsSL "${REPO_URL}/fastcp.gpg" | gpg --dearmor --yes -o /usr/share/keyrings/fastcp.gpg
# shellcheck disable=SC1091
echo "deb [signed-by=/usr/share/keyrings/fastcp.gpg] ${REPO_URL} $(. /etc/os-release && echo "${VERSION_CODENAME}") main" \
  > /etc/apt/sources.list.d/fastcp.list
apt-get update -y >/dev/null

# Download the published debs so smoke.sh installs exactly what the repo serves.
DIST_DIR=/root/fastcp-smoke-debs
rm -rf "${DIST_DIR}" && mkdir -p "${DIST_DIR}"
cd "${DIST_DIR}"
apt-get download fcp-nginx fcp-apache fcp-php-common \
  fcp-php8.2 fcp-php8.3 fcp-php8.4 fcp-php8.5 \
  fcp-composer fcp-wp-cli fcp-php-cli fcp-mysql
ls -1 "${DIST_DIR}"

DIST="${DIST_DIR}" exec bash "$(dirname "$0")/smoke.sh"
