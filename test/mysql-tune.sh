#!/usr/bin/env bash
set -euo pipefail

ROOT=$(mktemp -d)
trap 'rm -rf "${ROOT}"' EXIT
mkdir -p "${ROOT}/bin" "${ROOT}/config"
cat > "${ROOT}/bin/mysqld" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${ROOT}/bin/mysqld"

run_profile() {
  memory_kb="$1"
  expected_pool="$2"
  printf 'MemTotal:       %s kB\n' "${memory_kb}" > "${ROOT}/meminfo"
  printf 'max\n' > "${ROOT}/memory.max"
  PATH="${ROOT}/bin:${PATH}" \
    FCP_MEMINFO="${ROOT}/meminfo" \
    FCP_CGROUP_MEMORY_MAX="${ROOT}/memory.max" \
    FCP_MYSQL_CONFIG_DIR="${ROOT}/config" \
    bash mysql/mysql-tune >/dev/null
  grep -q "innodb_buffer_pool_size = ${expected_pool}M" \
    "${ROOT}/config/91-fastcp-autotune.cnf"
}

run_profile 1048576 256
run_profile 4194304 1024
run_profile 67108864 8192

echo "FastCP MySQL tuning profiles passed"
