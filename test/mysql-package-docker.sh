#!/usr/bin/env bash
set -euo pipefail
DEB="${1:-dist/fcp-mysql_1.0.1-1~noble_all.deb}"
[ -f "${DEB}" ] || { echo "missing ${DEB}" >&2; exit 1; }

for ubuntu in 22.04 24.04; do
  name="fastcp-mysql-${ubuntu//./}-$$"
  image="${name}:test"
  cleanup() {
    docker rm -f "${name}" >/dev/null 2>&1 || true
    docker image rm -f "${image}" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  docker build -q -t "${image}" - <<EOF
FROM ubuntu:${ubuntu}
ENV container=docker DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv && apt-get clean
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
EOF
  docker run --privileged --cgroupns=host -d --name "${name}" "${image}" >/dev/null
  docker cp "${DEB}" "${name}:/tmp/fcp-mysql.deb"
  docker exec "${name}" bash -lc '
    dpkg -i /tmp/fcp-mysql.deb >/dev/null 2>&1 || apt-get install -f -y -qq
    dpkg --configure -a >/dev/null
    for _ in $(seq 1 20); do systemctl is-active --quiet mysql && break; sleep 1; done
    systemctl is-active --quiet mysql
    mysqld --validate-config
    mysql -NBe "SELECT @@bind_address, @@local_infile" | grep -q "^127.0.0.1[[:space:]]0$"
    apt-get purge -y -qq fcp-mysql
    test ! -e /etc/mysql/mysql.conf.d/91-fastcp-autotune.cnf
    systemctl is-active --quiet mysql
    mysql -NBe "ALTER USER '\''root'\''@'\''localhost'\'' IDENTIFIED WITH caching_sha2_password BY '\''fastcp-ci-root-password'\''"
    dpkg -i /tmp/fcp-mysql.deb
    dpkg-query -W -f="\${Status}" fcp-mysql | grep -q "install ok installed"
    MYSQL_PWD=fastcp-ci-root-password mysqladmin --protocol=socket -uroot ping >/dev/null
  '
  cleanup
  trap - EXIT
  echo "fcp-mysql passed on Ubuntu ${ubuntu}"
done
