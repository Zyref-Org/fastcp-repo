#!/usr/bin/env bash
# End-to-end smoke test for the built FastCP packages. Run as root on a fresh
# Ubuntu host after a build: installs dist/*.deb, checks services, branding
# and PHP extensions, then wires up a test app mirroring the agent's layout
# (FPM pool + Apache vhost + nginx vhost) and exercises the request path,
# .htaccess rewriting, real-IP restoration, HTTPS detection and gzip.
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
apt-get install -y --reinstall "${DIST}"/*.deb >/tmp/smoke-install.log 2>&1 \
  && ok "apt install of all packages (deps resolved)" \
  || { bad "apt install failed"; tail -20 /tmp/smoke-install.log; }

echo "== services =="
for svc in fcp-nginx fcp-apache; do
  check "service ${svc} active" systemctl is-active --quiet "${svc}"
done
for dir in /opt/fcp/php/*/; do
  v="$(basename "${dir}")"
  check "service fcp-php-fpm@${v} active" systemctl is-active --quiet "fcp-php-fpm@${v}"
done

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
cat > "${app}/public/index.php" <<'PHP'
<?php echo "OK:" . $_SERVER['REMOTE_ADDR'] . ":" . ($_SERVER['HTTPS'] ?? 'off') . ":" . PHP_VERSION;
PHP
cat > "${app}/public/.htaccess" <<'HT'
RewriteEngine On
RewriteRule ^ht-test$ index.php [L]
HT
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
chdir = ${app}/public
php_admin_value[open_basedir] = ${app}:/tmp
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
</VirtualHost>
APACHE

cat > /etc/nginx-fcp/vhosts.d/testuser.testapp.conf <<NGINX
server {
    listen 80;
    server_name test.local;
    root ${app}/public;
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

enc="$(curl -fsS -o /dev/null -w '%{header_json}' -H 'Host: test.local' -H 'Accept-Encoding: gzip' http://127.0.0.1/big.css 2>/dev/null | grep -o '"content-encoding":\["gzip"\]' || true)"
[ -n "${enc}" ] && ok "nginx gzips proxied responses" || bad "gzip on proxied response missing"

echo
echo "== result: ${pass} passed, ${fail} failed =="
exit "$((fail > 0 ? 1 : 0))"
