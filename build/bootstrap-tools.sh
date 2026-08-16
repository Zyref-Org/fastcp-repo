#!/usr/bin/env bash
# Install the packaging toolchain (nfpm for .deb creation, aptly for repo
# publishing). Requires Go and, for aptly, apt.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if ! command -v nfpm >/dev/null 2>&1; then
  log "installing nfpm via go install"
  go install github.com/goreleaser/nfpm/v2/cmd/nfpm@latest
  log "ensure \$(go env GOPATH)/bin is on PATH"
fi

if ! command -v aptly >/dev/null 2>&1; then
  log "installing aptly (needs sudo/apt)"
  sudo apt-get update
  sudo apt-get install -y aptly
fi

log "toolchain ready: nfpm=$(command -v nfpm || echo MISSING) aptly=$(command -v aptly || echo MISSING)"
