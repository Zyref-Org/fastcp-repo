#!/usr/bin/env bash
# CI publish: assemble a multi-distribution, multi-architecture FastCP APT repo
# from built .debs and sync it to Cloudflare R2. The GPG signing key must already
# be imported into the keyring (the workflow does this from a secret).
#
# Layout expected: ${ARTIFACTS_DIR} contains subdirectories whose names include
# the codename (e.g. debs-jammy-amd64, debs-noble-arm64), each holding *.deb.
#
# Env:
#   ARTIFACTS_DIR   dir of downloaded build artifacts (default ./artifacts)
#   CODENAMES       space-separated list (default "jammy noble resolute")
#   FCP_GPG_EMAIL   signing key identity (default ops@fastcp.io)
#   FCP_R2_REMOTE   rclone remote name (default r2)
#   FCP_R2_BUCKET   bucket name (required)
set -euo pipefail

ARTIFACTS_DIR="${ARTIFACTS_DIR:-./artifacts}"
CODENAMES="${CODENAMES:-jammy noble resolute}"
KEY_EMAIL="${FCP_GPG_EMAIL:-ops@fastcp.io}"
REMOTE="${FCP_R2_REMOTE:-r2}"
BUCKET="${FCP_R2_BUCKET:?set FCP_R2_BUCKET}"
COMPONENT="${FCP_COMPONENT:-main}"
ARCHES="${FCP_ARCHES:-amd64,arm64}"

log() { printf '\033[1;35m[publish-ci]\033[0m %s\n' "$*"; }

for tool in aptly gpg rclone; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing $tool" >&2; exit 1; }
done

KEY_ID="$(gpg --list-secret-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^sec:/{print $5; exit}')"
[ -n "${KEY_ID}" ] || { echo "no secret key for ${KEY_EMAIL}" >&2; exit 1; }
log "signing key ${KEY_ID}"

for cn in ${CODENAMES}; do
  debs=$(find "${ARTIFACTS_DIR}" -type d -name "*${cn}*" -exec find {} -name '*.deb' \; 2>/dev/null)
  if [ -z "${debs}" ]; then
    log "no packages for ${cn}, skipping"
    continue
  fi
  repo="fastcp-${cn}"
  aptly repo show "${repo}" >/dev/null 2>&1 || \
    aptly repo create -distribution="${cn}" -component="${COMPONENT}" "${repo}"
  # shellcheck disable=SC2086
  aptly repo add "${repo}" ${debs}
  if aptly publish list 2>/dev/null | grep -q "${cn}"; then
    aptly publish update -gpg-key="${KEY_ID}" "${cn}"
  else
    aptly publish repo -architectures="${ARCHES}" -component="${COMPONENT}" \
      -distribution="${cn}" -gpg-key="${KEY_ID}" "${repo}"
  fi
  log "published ${cn}"
done

PUBLIC_ROOT="${HOME}/.aptly/public"
gpg --armor --export "${KEY_ID}" > "${PUBLIC_ROOT}/fastcp.gpg"
log "exported public key"

log "syncing to ${REMOTE}:${BUCKET}"
rclone sync --checksum --transfers 24 "${PUBLIC_ROOT}/" "${REMOTE}:${BUCKET}/"
log "done. Repo served at https://repo.fastcp.io once the bucket custom domain is bound."
