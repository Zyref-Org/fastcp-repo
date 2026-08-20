#!/usr/bin/env bash
# shellcheck disable=SC2015
# End-to-end smoke test for the built FastCP packages. Run as root on a fresh
# Ubuntu host after a build: installs dist/*.deb, checks services, branding
# and PHP extensions, then wires up a test app mirroring the agent's layout
# (FPM pool + Apache vhost + nginx vhost) and exercises the request path,
# .htaccess rewriting, real-IP restoration, HTTPS detection and gzip.
#
# The vhosts and pool below mirror pkg/render in the agent, so this is also where
# the isolation those files provide is checked against real nginx, Apache and
# PHP: temp paths inside the app, no reachable /tmp, dotfiles refused, and
# /.well-known still served so certificate renewals keep working.
set -u

DIST="${DIST:-/root/fastcp-packaging/dist}"
PHP_TEST_VERSION="${PHP_TEST_VERSION:-8.3}"
REQUIRED_EXTS="bcmath calendar curl exif ftp gd gettext gmp intl mbstring
mysqli pcntl pdo_mysql shmop soap sockets sodium sysvmsg sysvsem sysvshm
xsl zip"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf 'PASS: %s\n' "$*"; }
bad()  { fail=$((fail+1)); printf 'FAIL: %s\n' "$*"; }
check() { # check <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "${desc}"; else bad "${desc}"; fi
}

echo "== installing packages from ${DIST} =="
if apt-get install -y --reinstall "${DIST}"/*.deb >/tmp/smoke-install.log 2>&1; then
  ok "apt install of all packages (deps resolved)"
else
  bad "apt install failed"
  tail -100 /tmp/smoke-install.log
  systemctl status fcp-mysql-tune.service mysql.service --no-pager || true
  journalctl -u fcp-mysql-tune.service -u mysql.service -n 100 --no-pager || true
fi

echo "== services =="
for svc in fcp-nginx fcp-apache; do
  check "service ${svc} active" systemctl is-active --quiet "${svc}"
done
for dir in /opt/fcp/php/*/; do
  v="$(basename "${dir}")"
  check "service fcp-php-fpm@${v} active" systemctl is-active --quiet "fcp-php-fpm@${v}"
done
check "service mysql active" systemctl is-active --quiet mysql
check "FastCP MySQL config validates" mysqld --validate-config
grep -Eq '^[[:space:]]*bind-address[[:space:]]*=[[:space:]]*127\.0\.0\.1' \
  /etc/mysql/mysql.conf.d/90-fastcp.cnf \
  && grep -Eq '^[[:space:]]*local_infile[[:space:]]*=[[:space:]]*OFF' \
    /etc/mysql/mysql.conf.d/90-fastcp.cnf \
  && grep -Eq '^[[:space:]]*innodb_buffer_pool_size[[:space:]]*=' \
    /etc/mysql/mysql.conf.d/91-fastcp-autotune.cnf \
  && ok "MySQL FastCP profile is active" \
  || bad "MySQL FastCP profile is not active"

echo "== branding =="
/opt/fcp/nginx/sbin/nginx -v 2>&1 | grep -q FastCP \
  && ok "nginx -v reports FastCP" || bad "nginx -v missing FastCP"
/opt/fcp/apache/bin/httpd -v 2>&1 | grep -q FastCP \
  && ok "httpd -v reports FastCP" || bad "httpd -v missing FastCP"
"/opt/fcp/php/${PHP_TEST_VERSION}/bin/php" -i 2>/dev/null | grep -qi 'build provider.*FastCP' \
  && ok "phpinfo reports FastCP build provider" || bad "php build provider missing"

echo "== config sanity =="
check "nginx -t" /opt/fcp/nginx/sbin/nginx -t -c /etc/nginx-fcp/nginx.conf
check "httpd -t" /opt/fcp/apache/bin/httpd -t -f /etc/apache-fcp/httpd.conf
/opt/fcp/nginx/sbin/nginx -V 2>&1 | grep -q http_v3_module \
  && ok "nginx built with HTTP/3" || bad "nginx missing HTTP/3 module"

echo "== PHP extensions =="
for dir in /opt/fcp/php/*/; do
  v="$(basename "${dir}")"
  mods="$("${dir}bin/php" -m 2>/dev/null)"
  missing=""
  for ext in ${REQUIRED_EXTS}; do
    echo "${mods}" | grep -qix "${ext}" || missing="${missing} ${ext}"
  done
  echo "${mods}" | grep -qi 'zend opcache' || missing="${missing} opcache"
  if [ -z "${missing}" ]; then ok "php ${v} extensions complete"
  else bad "php ${v} missing:${missing}"; fi
done

echo "== test app (agent-layout vhost) =="
app=/srv/users/testuser/apps/testapp
id testuser >/dev/null 2>&1 || useradd --system --home /srv/users/testuser --shell /usr/sbin/nologin testuser
install -d -m 0755 "${app}/public" /srv/users/testuser/log
# Private scratch space, exactly as the agent creates it: PHP sessions and
# uploads must never share /tmp with other customers.
install -d -m 0700 -o testuser -g testuser "${app}/tmp" "${app}/tmp/sessions" "${app}/tmp/uploads"
cat > "${app}/public/index.php" <<'PHP'
<?php echo "OK:" . $_SERVER['REMOTE_ADDR'] . ":" . ($_SERVER['HTTPS'] ?? 'off') . ":" . PHP_VERSION;
PHP
cat > "${app}/public/probe.php" <<'PHP'
<?php
header('Content-Type: text/plain');
session_start();
$savePath = ini_get('session.save_path');
printf("save_path=%s\n", $savePath);
printf("sys_temp=%s\n", sys_get_temp_dir());
printf("upload_tmp=%s\n", ini_get('upload_tmp_dir'));
printf("basedir=%s\n", ini_get('open_basedir'));
printf("session_in_app=%s\n", is_file($savePath . '/sess_' . session_id()) ? 'yes' : 'no');
printf("tmp_write=%s\n", @file_put_contents('/tmp/fcp-smoke', 'x') === false ? 'blocked' : 'ALLOWED');
PHP
cat > "${app}/public/.htaccess" <<'HT'
RewriteEngine On
RewriteRule ^ht-test$ index.php [L]
HT
# A secret of the kind that gets left in a webroot, plus an ACME challenge that
# has to stay reachable while the secret does not.
echo 'DB_PASSWORD=hunter2' > "${app}/public/.env"
install -d -m 0755 "${app}/public/.well-known/acme-challenge"
echo 'acme-token-body' > "${app}/public/.well-known/acme-challenge/testtoken"
# ~20KB of compressible static content for the gzip check.
head -c 20000 /dev/zero | tr '\0' 'a' > "${app}/public/big.css"
chown -R testuser:testuser /srv/users/testuser

sock="/run/fcp/testuser.testapp.sock"
cat > "/opt/fcp/php/${PHP_TEST_VERSION}/etc/pool.d/testuser.testapp.conf" <<POOL
[testuser.testapp]
user = testuser
group = testuser
listen = ${sock}
listen.owner = testuser
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 5
request_terminate_timeout = 300s
chdir = ${app}/public
clear_env = yes
security.limit_extensions = .php
php_admin_value[session.save_path] = ${app}/tmp/sessions
php_admin_value[upload_tmp_dir] = ${app}/tmp/uploads
php_admin_value[sys_temp_dir] = ${app}/tmp
php_admin_value[open_basedir] = ${app}
php_admin_value[error_log] = /srv/users/testuser/log/testapp_php.error.log
POOL

cat > /etc/apache-fcp/vhosts.d/testuser.testapp.conf <<APACHE
<VirtualHost 127.0.0.1:81>
    ServerName test.local
    DocumentRoot ${app}/public
    <Directory ${app}/public>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    <FilesMatch \\.php\$>
        SetHandler "proxy:unix:${sock}|fcgi://localhost"
    </FilesMatch>
    <FilesMatch "^\\.">
        Require all denied
    </FilesMatch>
    <DirectoryMatch "/\\.(?!well-known)">
        Require all denied
    </DirectoryMatch>
</VirtualHost>
APACHE

cat > /etc/nginx-fcp/vhosts.d/testuser.testapp.conf <<NGINX
server {
    listen 80;
    server_name test.local;
    root ${app}/public;
    location ~ /\\.(?!well-known/) {
        deny all;
    }
    location / {
        proxy_pass http://127.0.0.1:81;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX

systemctl restart "fcp-php-fpm@${PHP_TEST_VERSION}" fcp-apache
systemctl reload fcp-nginx || systemctl restart fcp-nginx
sleep 2

body="$(curl -fsS -H 'Host: test.local' http://127.0.0.1/ 2>/dev/null || true)"
case "${body}" in
  OK:*) ok "PHP app served through nginx -> apache -> fpm (${body})" ;;
  *)    bad "request path broken (got: ${body})" ;;
esac

body="$(curl -fsS -H 'Host: test.local' http://127.0.0.1/ht-test 2>/dev/null || true)"
case "${body}" in
  OK:*) ok ".htaccess rewrite works" ;;
  *)    bad ".htaccess rewrite broken (got: ${body})" ;;
esac

body="$(curl -fsS -H 'Host: test.local' -H 'X-Real-IP: 203.0.113.9' http://127.0.0.1:81/ 2>/dev/null || true)"
case "${body}" in
  OK:203.0.113.9:*) ok "mod_remoteip restores client IP" ;;
  *)                bad "remoteip not applied (got: ${body})" ;;
esac

body="$(curl -fsS -H 'Host: test.local' -H 'X-Forwarded-Proto: https' http://127.0.0.1:81/ 2>/dev/null || true)"
case "${body}" in
  OK:*:on:*) ok "HTTPS detection via X-Forwarded-Proto" ;;
  *)         bad "HTTPS detection broken (got: ${body})" ;;
esac

# -D- dumps response headers (portable; %{header_json} needs curl >= 7.83).
curl -fsS -D- -o /dev/null -H 'Host: test.local' -H 'Accept-Encoding: gzip' http://127.0.0.1/big.css 2>/dev/null \
  | grep -qi '^content-encoding: gzip' \
  && ok "nginx gzips proxied responses" || bad "gzip on proxied response missing"

echo "== isolation =="
probe="$(curl -fsS -H 'Host: test.local' http://127.0.0.1/probe.php 2>/dev/null || true)"
probe_has() { echo "${probe}" | grep -qx "$1"; }
# Sessions in a shared /tmp are readable by every other customer on the server,
# and a stolen session id is a logged-in account on their site.
probe_has "save_path=${app}/tmp/sessions" \
  && ok "sessions are written inside the app" \
  || bad "session.save_path is not the app's own directory (probe: ${probe})"
probe_has "session_in_app=yes" \
  && ok "a started session really lands there" \
  || bad "session file was not created in the app (probe: ${probe})"
probe_has "sys_temp=${app}/tmp" \
  && ok "sys_get_temp_dir() is inside the app" \
  || bad "sys_temp_dir not applied (probe: ${probe})"
probe_has "upload_tmp=${app}/tmp/uploads" \
  && ok "uploads are buffered inside the app" \
  || bad "upload_tmp_dir not applied (probe: ${probe})"
probe_has "tmp_write=blocked" \
  && ok "the shared /tmp is unreachable from PHP" \
  || bad "PHP can still write to the shared /tmp (probe: ${probe})"

code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: test.local' http://127.0.0.1/.env)"
[ "${code}" = "403" ] \
  && ok "nginx refuses .env (${code})" \
  || bad "nginx served .env with ${code}"
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: test.local' http://127.0.0.1:81/.env)"
[ "${code}" = "403" ] \
  && ok "apache refuses .env at the origin (${code})" \
  || bad "apache served .env with ${code}"
# A dotfile rule that catches this too silently breaks every certificate renewal.
body="$(curl -fsS -H 'Host: test.local' http://127.0.0.1/.well-known/acme-challenge/testtoken 2>/dev/null || true)"
[ "${body}" = "acme-token-body" ] \
  && ok "ACME challenges are still served" \
  || bad "ACME challenge path is blocked (got: ${body})"

echo "== service sandboxing =="
for unit in fcp-nginx fcp-apache "fcp-php-fpm@${PHP_TEST_VERSION}"; do
  for prop in PrivateTmp=yes ProtectHome=yes; do
    systemctl show -p "${prop%%=*}" "${unit}" 2>/dev/null | grep -qi "${prop}" \
      && ok "${unit} has ${prop}" || bad "${unit} missing ${prop}"
  done
done
# mail() delivers through a setgid sendmail, which NoNewPrivileges would break.
systemctl show -p NoNewPrivileges "fcp-php-fpm@${PHP_TEST_VERSION}" 2>/dev/null \
  | grep -qi 'NoNewPrivileges=no' \
  && ok "php-fpm leaves NoNewPrivileges off so mail() keeps working" \
  || bad "php-fpm has NoNewPrivileges set"
check "/run/fcp exists" test -d /run/fcp

echo
echo "== result: ${pass} passed, ${fail} failed =="
exit "$((fail > 0 ? 1 : 0))"
