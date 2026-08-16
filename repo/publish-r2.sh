#!/usr/bin/env bash
# Publish the FastCP APT repository to a Cloudflare R2 bucket (static hosting).
# An apt repo is just static files, so no repo server is needed: this signs the
# repo locally with GPG and syncs the published tree to R2 via rclone.
#
# Prereqs on the build/publish host:
#   - aptly, gpg, rclone
#   - an rclone remote for R2 (S3-compatible). Example ~/.config/rclone/rclone.conf:
#       [r2]
#       type = s3
#       provider = Cloudflare
#       access_key_id = <R2 Access Key ID>
#       secret_access_key = <R2 Secret Access Key>
#       endpoint = https://<accountid>.r2.cloudflarestorage.com
#       acl = private
#
# Env:
#   FCP_R2_REMOTE   rclone remote name (default r2)
#   FCP_R2_BUCKET   bucket name (default fastcp-repo)
#   FCP_DIST        codename (default noble)
#   FCP_COMPONENT   component (default main)
#   FCP_GPG_EMAIL   signing key identity (default ops@fastcp.io)
#   DIST            dir of *.deb (default dist/)
#
# After the first run, bind repo.fastcp.io to the bucket as an R2 custom domain
# in the Cloudflare dashboard.
set -euo pipefail

REMOTE="${FCP_R2_REMOTE:-r2}"
BUCKET="${FCP_R2_BUCKET:-fastcp-repo}"
REPO_NAME="${FCP_REPO_NAME:-fastcp}"
CODENAME="${FCP_DIST:-noble}"
COMPONENT="${FCP_COMPONENT:-main}"
KEY_EMAIL="${FCP_GPG_EMAIL:-ops@fastcp.io}"
DIST_DIR="${DIST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist}"

log() { printf '\033[1;35m[repo]\033[0m %s\n' "$*"; }

for tool in aptly gpg rclone; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing $tool" >&2; exit 1; }
done

# Signing key (idempotent).
if ! gpg --list-secret-keys "${KEY_EMAIL}" >/dev/null 2>&1; then
  log "generating repo signing key for ${KEY_EMAIL}"
  cat > /tmp/fcp-key.batch <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Name-Real: FastCP Repository Signing Key
Name-Email: ${KEY_EMAIL}
Expire-Date: 0
%commit
EOF
  gpg --batch --gen-key /tmp/fcp-key.batch
  rm -f /tmp/fcp-key.batch
fi
KEY_ID="$(gpg --list-secret-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^sec:/{print $5; exit}')"
log "signing key ${KEY_ID}"

# Publish with aptly to the local public tree.
if ! aptly repo show "${REPO_NAME}" >/dev/null 2>&1; then
  aptly repo create -distribution="${CODENAME}" -component="${COMPONENT}" "${REPO_NAME}"
fi
aptly repo add "${REPO_NAME}" "${DIST_DIR}"/*.deb || true
if aptly publish list 2>/dev/null | grep -q "${CODENAME}"; then
  aptly publish update -gpg-key="${KEY_ID}" "${CODENAME}"
else
  aptly publish repo -gpg-key="${KEY_ID}" "${REPO_NAME}"
fi

PUBLIC_ROOT="${HOME}/.aptly/public"
gpg --armor --export "${KEY_ID}" > "${PUBLIC_ROOT}/fastcp.gpg"
log "exported public key to ${PUBLIC_ROOT}/fastcp.gpg"

# Sync the static tree to R2. --checksum avoids re-uploading unchanged blobs.
log "syncing repo tree to ${REMOTE}:${BUCKET}"
rclone sync --checksum --transfers 16 "${PUBLIC_ROOT}/" "${REMOTE}:${BUCKET}/"

log "done."
log "In Cloudflare, bind repo.fastcp.io to bucket ${BUCKET} (R2 > Settings > Custom Domains)."
log "Clients then add:"
log "  deb [signed-by=/usr/share/keyrings/fastcp.gpg] https://repo.fastcp.io ${CODENAME} ${COMPONENT}"
log "  key: https://repo.fastcp.io/fastcp.gpg"
