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

# Pull agent .debs uploaded by the fastcp-agent repo's CI into the bucket's
# incoming/agent/ prefix. The agent is a static binary: the same per-arch .deb
# is added to every codename (identical checksums, so the pool dedupes it).
AGENT_DIR="${ARTIFACTS_DIR}/agent-incoming"
mkdir -p "${AGENT_DIR}"
rclone copy "${REMOTE}:${BUCKET}/incoming/agent/" "${AGENT_DIR}/" 2>/dev/null \
  || log "no incoming agent packages"
agent_debs=$(find "${AGENT_DIR}" -name '*.deb' 2>/dev/null)
[ -n "${agent_debs}" ] && log "ingesting agent packages:" $(basename -a ${agent_debs})

for cn in ${CODENAMES}; do
  # Arch-independent packages (arch: all) are built by both per-arch runners
  # with identical content but differing metadata timestamps; keep only the
  # first file per name to avoid aptly pool conflicts.
  debs=$(find "${ARTIFACTS_DIR}" -path "${AGENT_DIR}" -prune -o -type d -name "*${cn}*" -print 2>/dev/null \
    | xargs -I{} find {} -name '*.deb' 2>/dev/null | awk -F/ '!seen[$NF]++')
  if [ -z "${debs}" ]; then
    log "no packages for ${cn}, skipping"
    continue
  fi
  repo="fastcp-${cn}"
  aptly repo show "${repo}" >/dev/null 2>&1 || \
    aptly repo create -distribution="${cn}" -component="${COMPONENT}" "${repo}"
  # shellcheck disable=SC2086
  aptly repo add "${repo}" ${debs} ${agent_debs}
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
# incoming/ is the drop-box other repos upload to and install.sh is published
# by the installer repo's CI; never delete either here.
rclone sync --checksum --transfers 24 \
  --exclude 'incoming/**' --exclude 'install.sh' \
  "${PUBLIC_ROOT}/" "${REMOTE}:${BUCKET}/"
log "done. Repo served at https://repo.fastcp.io once the bucket custom domain is bound."
