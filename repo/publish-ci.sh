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

while IFS= read -r manifest; do
  [ -n "${manifest}" ] || continue
  (cd "$(dirname "${manifest}")" && sha256sum -c "$(basename "${manifest}")")
done < <(find "${ARTIFACTS_DIR}" -mindepth 2 -name SHA256SUMS -type f 2>/dev/null)

KEY_ID="$(gpg --list-secret-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^sec:/{print $5; exit}')"
[ -n "${KEY_ID}" ] || { echo "no secret key for ${KEY_EMAIL}" >&2; exit 1; }
log "signing key ${KEY_ID}"

# Pull agent .debs uploaded by the fastcp-agent repo's CI into the bucket's
# incoming/agent/ prefix. The agent is a static binary: the same per-arch .deb
# is added to every codename (identical checksums, so the pool dedupes it).
AGENT_DIR="${ARTIFACTS_DIR}/agent-incoming"
mkdir -p "${AGENT_DIR}"
if [ -n "${EXPECTED_AGENT_MANIFEST_SHA:-}" ]; then
  command -v gh >/dev/null 2>&1 || { echo "missing gh for provenance verification" >&2; exit 1; }
  [ -n "${EXPECTED_AGENT_REPOSITORY:-}" ] &&
    [ "${DISPATCH_AGENT_REPOSITORY:-}" = "${EXPECTED_AGENT_REPOSITORY}" ] || {
      echo "agent dispatch came from an untrusted repository" >&2; exit 1;
    }
  case "${DISPATCH_AGENT_REF:-}" in refs/tags/v*) ;; *)
    echo "agent dispatch is not from a version tag" >&2; exit 1 ;;
  esac
  case "${EXPECTED_AGENT_MANIFEST_SHA}" in *[!a-f0-9]*|"")
    echo "invalid expected agent manifest digest" >&2; exit 1 ;;
  esac
  [ "${#EXPECTED_AGENT_MANIFEST_SHA}" -eq 64 ] || {
    echo "invalid expected agent manifest digest length" >&2; exit 1;
  }
  rclone copy "${REMOTE}:${BUCKET}/incoming/agent/" "${AGENT_DIR}/"
  actual_manifest_sha=$(sha256sum "${AGENT_DIR}/SHA256SUMS" | awk '{print $1}')
  [ "${actual_manifest_sha}" = "${EXPECTED_AGENT_MANIFEST_SHA}" ] || {
    echo "incoming agent manifest does not match authenticated dispatch" >&2; exit 1;
  }
else
  log "no authenticated agent dispatch; ignoring incoming/agent"
fi
agent_debs=$(find "${AGENT_DIR}" -name '*.deb' 2>/dev/null)
if [ -n "${agent_debs}" ]; then
  [ -f "${AGENT_DIR}/SHA256SUMS" ] || { echo "agent SHA256SUMS missing" >&2; exit 1; }
  (cd "${AGENT_DIR}" && sha256sum -c SHA256SUMS)
  while IFS= read -r deb; do
    [ "$(dpkg-deb -f "${deb}" Package)" = "fastcp-agent" ] || {
      echo "unexpected incoming package: ${deb}" >&2; exit 1;
    }
    expected_version="${DISPATCH_AGENT_REF#refs/tags/v}-1"
    [ "$(dpkg-deb -f "${deb}" Version)" = "${expected_version}" ] || {
      echo "agent package version does not match dispatch tag: ${deb}" >&2; exit 1;
    }
    case "$(dpkg-deb -f "${deb}" Architecture)" in amd64|arm64) ;; *)
      echo "unexpected agent architecture: ${deb}" >&2; exit 1 ;;
    esac
    gh attestation verify "${deb}" \
      --repo "${EXPECTED_AGENT_REPOSITORY}" \
      --signer-workflow "${EXPECTED_AGENT_REPOSITORY}/.github/workflows/agent.yml" \
      --source-ref "${DISPATCH_AGENT_REF}" \
      --deny-self-hosted-runners >/dev/null
  done <<EOF
${agent_debs}
EOF
  log "verified incoming agent packages"
fi

# Always retain the published pool so a new release never removes rollback
# versions. Fresh files with the same filename are deduplicated below.
POOL_DIR="${ARTIFACTS_DIR}/pool-mirror"
have_builds=$(find "${ARTIFACTS_DIR}" -path "${AGENT_DIR}" -prune -o -type d -name "debs-*" -print 2>/dev/null | head -1)
log "mirroring published rollback pool from ${REMOTE}:${BUCKET}/pool"
mkdir -p "${POOL_DIR}"
rclone copy --include "*.deb" "${REMOTE}:${BUCKET}/pool/" "${POOL_DIR}/" || true
pool_count=$(find "${POOL_DIR}" -name '*.deb' | wc -l | tr -d ' ')
published_agent_debs=$(find "${POOL_DIR}" -name 'fastcp-agent_*.deb' 2>/dev/null)
if [ -z "${have_builds}" ]; then
  [ "${pool_count}" -gt 0 ] || { echo "published pool is empty; run a full build first" >&2; exit 1; }
  log "reusing ${pool_count} published packages"
fi

for cn in ${CODENAMES}; do
  # Arch-independent packages (arch: all) are built by both per-arch runners
  # with identical content but differing metadata timestamps; keep only the
  # first file per name to avoid aptly pool conflicts.
  if [ -n "${have_builds}" ]; then
    # shellcheck disable=SC2038 # CI artifact paths are generated safe names.
    debs=$({ find "${ARTIFACTS_DIR}" -path "${AGENT_DIR}" -prune -o -path "${POOL_DIR}" -prune \
      -o -type d -name "*${cn}*" -print 2>/dev/null | xargs -r -I{} find {} -name '*.deb' 2>/dev/null
      find "${POOL_DIR}" -name "*~${cn}_*.deb" 2>/dev/null; } | awk -F/ '!seen[$NF]++')
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
  aptly repo add "${repo}" ${debs} ${published_agent_debs} ${agent_debs}
  if aptly publish list 2>/dev/null | grep -q "${cn}"; then
    aptly publish update -gpg-key="${KEY_ID}" "${cn}"
  else
    aptly publish repo -acquire-by-hash -architectures="${ARCHES}" -component="${COMPONENT}" \
      -distribution="${cn}" -gpg-key="${KEY_ID}" "${repo}"
  fi
  log "published ${cn}"
done

PUBLIC_ROOT="${HOME}/.aptly/public"
gpg --armor --export "${KEY_ID}" > "${PUBLIC_ROOT}/fastcp.gpg"
log "exported public key"

SNAPSHOT_ID="${FCP_SNAPSHOT_ID:-$(date -u +%Y%m%dT%H%M%SZ)-${GITHUB_SHA:-local}}"
SNAPSHOT_ID="${SNAPSHOT_ID:0:64}"
case "${SNAPSHOT_ID}" in *[!A-Za-z0-9._-]*|"")
  echo "invalid snapshot id" >&2; exit 1 ;;
esac
(cd "${PUBLIC_ROOT}" && {
  find dists pool -type f -print0 | sort -z | xargs -0 sha256sum
  sha256sum fastcp.gpg
} > RELEASE.SHA256)
log "archiving immutable snapshot ${SNAPSHOT_ID}"
rclone copy --checksum --transfers 24 \
  --header-upload "Cache-Control: public, max-age=31536000, immutable" \
  "${PUBLIC_ROOT}/" "${REMOTE}:${BUCKET}/snapshots/${SNAPSHOT_ID}/"

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
printf '%s\n' "${SNAPSHOT_ID}" > "${PUBLIC_ROOT}/current-snapshot"
rclone copyto --checksum --header-upload "Cache-Control: no-cache" \
  "${PUBLIC_ROOT}/current-snapshot" "${REMOTE}:${BUCKET}/current-snapshot"
log "done. Repo served at https://repo.fastcp.io once the bucket custom domain is bound."
