#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
: "${FASTCP_TEST_DATABASE_URL:=postgres://fastcp:fastcp@127.0.0.1:55433/fastcp_test?sslmode=disable}"
export FASTCP_TEST_DATABASE_URL
if command -v go >/dev/null 2>&1; then
  PATH="$(go env GOPATH)/bin:${PATH}"
  export PATH
fi

echo "== shared protocol contract =="
diff -u "${ROOT}/fastcp-agent/shared/actions/actions.go" "${ROOT}/fastcp-webapp/shared/actions/actions.go"
diff -u "${ROOT}/fastcp-agent/shared/actions/validation.go" "${ROOT}/fastcp-webapp/shared/actions/validation.go"
diff -u "${ROOT}/fastcp-agent/shared/signing/signing.go" "${ROOT}/fastcp-webapp/shared/signing/signing.go"
python3 "${ROOT}/repo-packaging/test/wire-contract.py" \
  "${ROOT}/fastcp-agent/shared/api/wire.go" \
  "${ROOT}/fastcp-webapp/shared/api/wire.go"
python3 "${ROOT}/repo-packaging/test/spa-api-contract.py" \
  "${ROOT}/fastcp-webapp" "${ROOT}/fastcp-spa"

echo "== agent =="
(cd "${ROOT}/fastcp-agent" && go vet ./... && go test -race -shuffle=on -count=1 ./...)
(cd "${ROOT}/fastcp-agent" && {
  coverage_file=$(mktemp)
  trap 'rm -f "${coverage_file}"' EXIT
  go test -coverprofile="${coverage_file}" ./... >/dev/null
  coverage=$(go tool cover -func="${coverage_file}" | awk '/^total:/{gsub("%","",$3); print $3}')
  awk -v coverage="${coverage}" 'BEGIN { exit !(coverage >= 50) }'
})

echo "== web API =="
(cd "${ROOT}/fastcp-webapp" && go vet ./... && go test -race -shuffle=on -count=1 ./...)
(cd "${ROOT}/fastcp-webapp" && {
  coverage_file=$(mktemp)
  trap 'rm -f "${coverage_file}"' EXIT
  go test -coverprofile="${coverage_file}" ./... >/dev/null
  coverage=$(go tool cover -func="${coverage_file}" | awk '/^total:/{gsub("%","",$3); print $3}')
  awk -v coverage="${coverage}" 'BEGIN { exit !(coverage >= 50) }'
})
(contract_tmp=$(mktemp)
 trap 'rm -f "${contract_tmp}"' EXIT
 cd "${ROOT}/fastcp-webapp"
 go run ./cmd/fastcp-openapi > "${contract_tmp}"
 cmp "${contract_tmp}" "${ROOT}/fastcp-spa/openapi.json")
(cd "${ROOT}/fastcp-webapp" && {
  trust_tmp=$(mktemp -d)
  trap 'rm -rf "${trust_tmp}"' EXIT
  go run ./cmd/fastcp-keygen -out "${trust_tmp}/v1" -version 1 >/dev/null
  go run ./cmd/fastcp-keygen -out "${trust_tmp}/v2" -version 2 \
    -root-private "${trust_tmp}/v1/root-private.json" \
    -previous-metadata "${trust_tmp}/v1/root-metadata.json" \
    -signer-key "${trust_tmp}/v1/signer.json" \
    -outbox-key "${trust_tmp}/v1/outbox.key" >/dev/null
  cmp "${trust_tmp}/v1/outbox.key" "${trust_tmp}/v2/outbox.key"
  cmp "${trust_tmp}/v1/signer.json" "${trust_tmp}/v2/signer.json"
  test ! -e "${trust_tmp}/v2/root-private.json"
})

echo "== SPA =="
(cd "${ROOT}/fastcp-spa" && npm ci && npm audit --audit-level=high \
  && npm run typecheck && npm run check:api && npm test \
  && VITE_API_BASE=https://api.fastcp.io npm run build && npm run test:e2e)

echo "== scripts and workflows =="
if command -v shellcheck >/dev/null 2>&1; then
  (cd "${ROOT}/installer" && shellcheck install.sh)
  (cd "${ROOT}/fastcp-agent" && shellcheck packaging/build-deb.sh packaging/scripts/*.sh)
  (cd "${ROOT}/fastcp-webapp" && shellcheck \
    deploy/setup.sh deploy/fastcp-backup.sh deploy/fastcp-restore-drill.sh)
  (cd "${ROOT}/repo-packaging" && shellcheck \
    build/build-all.sh build/package.sh repo/publish-ci.sh \
    test/smoke.sh test/smoke-from-repo.sh test/mysql-tune.sh test/mysql-package-docker.sh \
    test/package-reproducibility.sh \
    test/verify-production.sh scripts/*.sh mysql/mysql-tune)
fi
if command -v caddy >/dev/null 2>&1; then
  caddy_tmp=$(mktemp)
  trap 'rm -f "${caddy_tmp}"' EXIT
  sed 's/__FASTCP_DOMAIN__/api.fastcp.io/g' "${ROOT}/fastcp-webapp/deploy/Caddyfile" > "${caddy_tmp}"
  caddy validate --config "${caddy_tmp}" --adapter caddyfile >/dev/null
fi
if command -v actionlint >/dev/null 2>&1; then
  for repo in fastcp-agent fastcp-webapp fastcp-spa installer repo-packaging; do
    (cd "${ROOT}/${repo}" && actionlint)
  done
fi

(cd "${ROOT}/repo-packaging" && bash test/mysql-tune.sh)
if command -v nfpm >/dev/null 2>&1; then
  (cd "${ROOT}/repo-packaging" && CODENAME=noble MYSQL_CONFIG_VERSION=1.0.0 \
    bash build/package.sh fcp-mysql)
  (cd "${ROOT}/repo-packaging" && bash test/package-reproducibility.sh)
  if command -v docker >/dev/null 2>&1; then
    (cd "${ROOT}/repo-packaging" && bash test/mysql-package-docker.sh)
  fi
else
  echo "WARNING: nfpm unavailable; fcp-mysql package/VM gate skipped" >&2
fi

for tool in staticcheck govulncheck; do
  if command -v "${tool}" >/dev/null 2>&1; then
    (cd "${ROOT}/fastcp-agent" && "${tool}" ./...)
    (cd "${ROOT}/fastcp-webapp" && "${tool}" ./...)
  else
    echo "WARNING: ${tool} unavailable; install it before a release" >&2
  fi
done

echo "Production verification gates passed"
