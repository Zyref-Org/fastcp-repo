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

# Equivalent safe subset of mysql_secure_installation. Ubuntu's root account
# remains socket-authenticated; no shared root password is introduced.
mysql --protocol=socket <<'SQL'
DROP USER IF EXISTS ''@'localhost';
DROP USER IF EXISTS ''@'%';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db LIKE 'test\_%';
FLUSH PRIVILEGES;
SQL
