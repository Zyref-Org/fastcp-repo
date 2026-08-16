#!/usr/bin/env bash
# Publish the built .deb packages to a signed FastCP APT repository using aptly.
# The repo is served over HTTPS; clients trust it via the exported GPG key.
#
# Env:
#   FCP_REPO_NAME   aptly repo name (default fastcp)
#   FCP_DIST        distribution/codename (default noble)
#   FCP_GPG_KEY     GPG key id used to sign the repo (required for signing)
#   DIST            directory containing *.deb (default dist/)
source "$(dirname "${BASH_SOURCE[0]}")/../build/common.sh"

REPO_NAME="${FCP_REPO_NAME:-fastcp}"
CODENAME="${FCP_DIST:-noble}"
COMPONENT="${FCP_COMPONENT:-main}"

command -v aptly >/dev/null 2>&1 || { echo "aptly missing; run bootstrap-tools.sh" >&2; exit 1; }

if ! aptly repo show "${REPO_NAME}" >/dev/null 2>&1; then
  log "creating aptly repo ${REPO_NAME} (${CODENAME}/${COMPONENT})"
  aptly repo create -distribution="${CODENAME}" -component="${COMPONENT}" "${REPO_NAME}"
fi

log "adding packages from ${DIST}"
aptly repo add "${REPO_NAME}" "${DIST}"/*.deb

sign_args=(-skip-signing)
if [ -n "${FCP_GPG_KEY:-}" ]; then
  sign_args=(-gpg-key="${FCP_GPG_KEY}")
fi

if aptly publish list 2>/dev/null | grep -q "${CODENAME}"; then
  log "updating published repo"
  aptly publish update "${sign_args[@]}" "${CODENAME}"
else
  log "publishing repo"
  aptly publish repo "${sign_args[@]}" "${REPO_NAME}"
fi

log "publish complete. Serve ~/.aptly/public over HTTPS as https://repo.fastcp.io"
log "clients add: deb [signed-by=/usr/share/keyrings/fastcp.gpg] https://repo.fastcp.io ${CODENAME} ${COMPONENT}"
