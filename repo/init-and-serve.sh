#!/usr/bin/env bash
# Initialize and serve the FastCP APT repository on a repo host.
#   1. Generates (once) a repo GPG signing key.
#   2. Publishes dist/*.deb into an aptly repo.
#   3. Exports the public key and serves the repo over HTTPS via Caddy at
#      ${FCP_REPO_DOMAIN} (automatic Let's Encrypt).
#
# Run on the repo host. Requires: aptly, gpg, caddy (script installs Caddy's
# static binary if missing). DNS for ${FCP_REPO_DOMAIN} must point here.
set -euo pipefail

REPO_DOMAIN="${FCP_REPO_DOMAIN:-repo.fastcp.io}"
REPO_NAME="${FCP_REPO_NAME:-fastcp}"
CODENAME="${FCP_DIST:-noble}"
COMPONENT="${FCP_COMPONENT:-main}"
DIST_DIR="${DIST:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dist}"
KEY_NAME="${FCP_GPG_NAME:-FastCP Repository Signing Key}"
KEY_EMAIL="${FCP_GPG_EMAIL:-ops@fastcp.io}"

log() { printf '\033[1;35m[repo]\033[0m %s\n' "$*"; }

command -v aptly >/dev/null 2>&1 || { echo "aptly missing (apt-get install -y aptly)" >&2; exit 1; }
command -v gpg >/dev/null 2>&1 || { echo "gpg missing" >&2; exit 1; }

# 1. Signing key (idempotent).
if ! gpg --list-secret-keys "${KEY_EMAIL}" >/dev/null 2>&1; then
  log "generating repo signing key for ${KEY_EMAIL}"
  cat > /tmp/fcp-key.batch <<EOF
%no-protection
Key-Type: eddsa
Key-Curve: ed25519
Name-Real: ${KEY_NAME}
Name-Email: ${KEY_EMAIL}
Expire-Date: 0
%commit
EOF
  gpg --batch --gen-key /tmp/fcp-key.batch
  rm -f /tmp/fcp-key.batch
fi
KEY_ID="$(gpg --list-secret-keys --with-colons "${KEY_EMAIL}" | awk -F: '/^sec:/{print $5; exit}')"
log "repo key id ${KEY_ID}"

# 2. Publish with aptly.
if ! aptly repo show "${REPO_NAME}" >/dev/null 2>&1; then
  aptly repo create -distribution="${CODENAME}" -component="${COMPONENT}" "${REPO_NAME}"
fi
log "adding $(ls -1 "${DIST_DIR}"/*.deb 2>/dev/null | wc -l | tr -d ' ') packages"
aptly repo add "${REPO_NAME}" "${DIST_DIR}"/*.deb || true
if aptly publish list 2>/dev/null | grep -q "${CODENAME}"; then
  aptly publish update -gpg-key="${KEY_ID}" "${CODENAME}"
else
  aptly publish repo -gpg-key="${KEY_ID}" "${REPO_NAME}"
fi

# 3. Export public key into the published tree so clients can fetch it.
PUBLIC_ROOT="${HOME}/.aptly/public"
gpg --armor --export "${KEY_ID}" > "${PUBLIC_ROOT}/fastcp.gpg"
log "exported public key to ${PUBLIC_ROOT}/fastcp.gpg"

# 4. Serve via Caddy static file server (automatic HTTPS).
if ! command -v caddy >/dev/null 2>&1 && [ ! -x /usr/local/bin/caddy ]; then
  log "installing Caddy static binary"
  curl -fsSL -o /usr/local/bin/caddy "https://caddyserver.com/api/download?os=linux&arch=amd64"
  chmod 0755 /usr/local/bin/caddy
fi
id -u caddy >/dev/null 2>&1 || useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy
install -d -m 0755 /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
${REPO_DOMAIN} {
    root * ${PUBLIC_ROOT}
    file_server browse
}
EOF
chmod 0644 /etc/caddy/Caddyfile
# Caddy must read the published tree.
chmod -R a+rX "${PUBLIC_ROOT}"
if [ ! -f /etc/systemd/system/caddy.service ]; then
  cat > /etc/systemd/system/caddy.service <<'UNIT'
[Unit]
Description=Caddy
After=network-online.target
Wants=network-online.target
[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
Restart=on-failure
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
UNIT
fi
systemctl daemon-reload
systemctl enable caddy || true
systemctl restart caddy

log "repo live at https://${REPO_DOMAIN}"
log "clients add:"
log "  deb [signed-by=/usr/share/keyrings/fastcp.gpg] https://${REPO_DOMAIN} ${CODENAME} ${COMPONENT}"
log "  key: https://${REPO_DOMAIN}/fastcp.gpg"
