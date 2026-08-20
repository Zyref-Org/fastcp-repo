#!/bin/sh
set -eu
[ "${1:-configure}" = "configure" ] || exit 0

install -d -m 0750 -o mysql -g adm /var/log/mysql
chmod 0755 /usr/lib/fastcp/mysql-tune
systemctl daemon-reload
systemctl enable fcp-mysql-tune.service
systemctl start fcp-mysql-tune.service

mysqld --validate-config
systemctl restart mysql.service
systemctl is-active --quiet mysql.service

# Equivalent safe subset of mysql_secure_installation when the existing server
# grants root socket administration. Upgrades may already use password/auth
# plugins managed outside FastCP; never fail package configuration or overwrite
# those credentials.
if mysql --protocol=socket --batch --skip-column-names -e 'SELECT 1' >/dev/null 2>&1; then
  mysql --protocol=socket <<'SQL'
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db LIKE 'test\_%';
FLUSH PRIVILEGES;
SQL
else
  echo "fcp-mysql: existing root authentication prevented optional account cleanup; configuration is installed" >&2
fi
