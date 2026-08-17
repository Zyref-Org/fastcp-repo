#!/usr/bin/env bash
# CI publish: assemble a multi-distribution, multi-architecture FastCP APT repo
# and sync it to Cloudflare R2. The GPG signing key must already be imported
# into the keyring (the workflow does this from a secret).
#
# Two source modes:
#   - Fresh builds: ${ARTIFACTS_DIR} contains subdirectories whose names
#     include the codename (e.g. debs-jammy-amd64), each holding *.deb.
#   - Publish-only (agent dispatch): no build artifacts present; the current
#     web-stack .debs are pulled back from the bucket's published pool/ and
#     grouped by the ~codename suffix in their version, so nothing is rebuilt.
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

# Publish-only mode: no freshly built artifacts, so reuse the web-stack debs
# already published in the bucket's pool (their versions carry ~codename).
POOL_DIR="${ARTIFACTS_DIR}/pool-mirror"
have_builds=$(find "${ARTIFACTS_DIR}" -path "${AGENT_DIR}" -prune -o -type d -name "debs-*" -print 2>/dev/null | head -1)
if [ -z "${have_builds}" ]; then
  log "no build artifacts; reusing published pool from ${REMOTE}:${BUCKET}/pool"
  mkdir -p "${POOL_DIR}"
  rclone copy --include "*.deb" "${REMOTE}:${BUCKET}/pool/" "${POOL_DIR}/"
  pool_count=$(find "${POOL_DIR}" -name '*.deb' | wc -l | tr -d ' ')
  [ "${pool_count}" -gt 0 ] || { echo "published pool is empty; run a full build first" >&2; exit 1; }
  log "reusing ${pool_count} published packages"
fi

for cn in ${CODENAMES}; do
  # Arch-independent packages (arch: all) are built by both per-arch runners
  # with identical content but differing metadata timestamps; keep only the
  # first file per name to avoid aptly pool conflicts.
  if [ -n "${have_builds}" ]; then
    debs=$(find "${ARTIFACTS_DIR}" -path "${AGENT_DIR}" -prune -o -type d -name "*${cn}*" -print 2>/dev/null \
      | xargs -I{} find {} -name '*.deb' 2>/dev/null | awk -F/ '!seen[$NF]++')
  else
    debs=$(find "${POOL_DIR}" -name "*~${cn}_*.deb" 2>/dev/null | awk -F/ '!seen[$NF]++')
  fi
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
# The bucket is fronted by Cloudflare (repo.fastcp.io), which edge-caches
# objects for hours by default, and rclone uploads in arbitrary order. Both
# broke installs on 2026-08-17: apt fetched a fresh Release next to an
# hours-stale cached Packages.bz2 ("File has unexpected size"). So:
#   1. pool/ additions first — a package must exist before an index cites it.
#      Pool filenames are version-unique, so long edge caching is safe.
#   2. dists/ indexes next, uploaded with Cache-Control: no-cache so CDN
#      edges revalidate metadata instead of serving stale copies. The
#      per-dist Release/InRelease files are held back...
#   3. ...and uploaded last: a client only sees a new Release once every
#      index it references is already in place.
#   4. Old pool files are pruned only after the new metadata is live.
# incoming/ (drop-box other repos upload into) and install.sh (published by
# the installer repo's CI) live outside pool/ and dists/ and are untouched.
rclone copy --checksum --transfers 24 \
  --header-upload "Cache-Control: public, max-age=86400" \
  "${PUBLIC_ROOT}/pool/" "${REMOTE}:${BUCKET}/pool/"
rclone sync --checksum --transfers 24 \
  --header-upload "Cache-Control: no-cache" \
  --exclude '/*/Release' --exclude '/*/Release.gpg' --exclude '/*/InRelease' \
  "${PUBLIC_ROOT}/dists/" "${REMOTE}:${BUCKET}/dists/"
rclone copy --checksum --transfers 24 \
  --header-upload "Cache-Control: no-cache" \
  --include '/*/Release' --include '/*/Release.gpg' --include '/*/InRelease' \
  "${PUBLIC_ROOT}/dists/" "${REMOTE}:${BUCKET}/dists/"
rclone copyto --checksum --header-upload "Cache-Control: no-cache" \
  "${PUBLIC_ROOT}/fastcp.gpg" "${REMOTE}:${BUCKET}/fastcp.gpg"
rclone sync --checksum --transfers 24 --delete-after \
  --header-upload "Cache-Control: public, max-age=86400" \
  "${PUBLIC_ROOT}/pool/" "${REMOTE}:${BUCKET}/pool/"
log "done. Repo served at https://repo.fastcp.io once the bucket custom domain is bound."
