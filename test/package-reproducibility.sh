#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "${tmp}"' EXIT
for run in first second; do
  DIST="${tmp}/${run}" \
  CODENAME=noble \
  MYSQL_CONFIG_VERSION=1.0.0 \
  SOURCE_DATE_EPOCH=1704067200 \
    bash "${ROOT}/build/package.sh" fcp-mysql >/dev/null
done
cmp "${tmp}/first/fcp-mysql_1.0.0-1~noble_all.deb" \
  "${tmp}/second/fcp-mysql_1.0.0-1~noble_all.deb"
echo "fcp-mysql reproducibility gate passed"
