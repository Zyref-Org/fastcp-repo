#!/usr/bin/env bash
# Build a single PHP version with PHP-FPM into /opt/fcp/php/<PHP_VERSION>.
# Example: PHP_VERSION=8.3 PHP_FULL_VERSION=8.3.14 build/build-php.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

PHP_VERSION="${PHP_VERSION:?set PHP_VERSION, e.g. 8.3}"
PHP_FULL_VERSION="${PHP_FULL_VERSION:-${PHP_VERSION}.0}"
PHP_SHA256="${PHP_SHA256:-REPLACE_WITH_RELEASE_SHA256}"
prefix="/opt/fcp/php/${PHP_VERSION}"
src="${BUILD}/php-${PHP_FULL_VERSION}.tar.gz"

fetch "https://www.php.net/distributions/php-${PHP_FULL_VERSION}.tar.gz" "${PHP_SHA256}" "${src}" \
  || log "checksum not pinned: set PHP_SHA256 for a verified build"

# Always build from a pristine tree; stale half-built trees cause missing
# source errors from make.
rm -rf "${BUILD}/php-${PHP_FULL_VERSION}"
tar -C "${BUILD}" -xzf "${src}"
cd "${BUILD}/php-${PHP_FULL_VERSION}"

# Brand the build: shown as "Build Provider" in phpinfo() (PHP >= 8.0) and
# exposed as the PHP_BUILD_PROVIDER constant on PHP >= 8.5.
export PHP_BUILD_PROVIDER="FastCP (https://fastcp.io)"

configure_flags=(
  --prefix="${prefix}"
  --with-config-file-path="${prefix}/etc"
  --with-config-file-scan-dir="${prefix}/etc/conf.d"
  --enable-fpm
  --with-fpm-user=www-data
  --with-fpm-group=www-data
  # systemd readiness notification; the unit uses Type=notify.
  --with-fpm-systemd
  --enable-opcache

  # Core web extensions.
  --enable-mbstring
  --with-openssl
  --with-zlib
  --with-curl
  --with-pdo-mysql
  --with-mysqli
  --enable-intl
  --with-zip

  # Image handling (WordPress media requires gd; exif for image metadata).
  --enable-gd
  --with-jpeg
  --with-webp
  --with-freetype
  --enable-exif

  # Common application/library requirements (WooCommerce, SDKs, CMSes).
  --enable-bcmath
  --enable-soap
  --enable-sockets
  --with-xsl
  --with-gmp
  --with-sodium
  --with-gettext
  --enable-calendar
  --enable-ftp

  # CLI/worker support (wp-cli, queue workers) and SysV IPC parity with
  # Ubuntu's stock php-common set.
  --enable-pcntl
  --enable-shmop
  --enable-sysvsem
  --enable-sysvshm
  --enable-sysvmsg
)

./configure "${configure_flags[@]}"

make -j"${JOBS}"
make install INSTALL_ROOT="${STAGE}"

# Stage FPM master config; per-app pools are dropped into pool.d by the agent,
# extra extension/ini snippets go into conf.d (scanned at startup).
install -d "${STAGE}${prefix}/etc/pool.d" "${STAGE}${prefix}/etc/conf.d"
cat > "${STAGE}${prefix}/etc/php-fpm.conf" <<CONF
[global]
pid = /run/fcp/php-fpm-${PHP_VERSION}.pid
error_log = /var/log/fcp/php${PHP_VERSION}-fpm.log
daemonize = no
include = ${prefix}/etc/pool.d/*.conf
CONF

# A secure, tuned default php.ini. Per-app pools written by the agent override
# the parts that have to differ per app: session.save_path, upload_tmp_dir,
# sys_temp_dir and open_basedir all point inside the app, so nothing here sets a
# shared temp location that every customer on the server could read.
cat > "${STAGE}${prefix}/etc/php.ini" <<'CONF'
; FastCP PHP build (https://fastcp.io)
expose_php = Off
display_errors = Off
log_errors = On
allow_url_fopen = Off
allow_url_include = Off
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
; A runaway request holds a PHP-FPM worker, and enough of them take the site
; down. The pool's request_terminate_timeout is the backstop for what this cannot
; interrupt, such as a stalled network read.
max_execution_time = 60
; Stack traces of uncaught exceptions otherwise carry the arguments they were
; called with, which is how database passwords end up in a log file.
zend.exception_ignore_args = On
date.timezone = UTC
realpath_cache_size = 4096k
realpath_cache_ttl = 120

; Session hardening. use_strict_mode makes PHP reject a session id it never
; issued, without which an attacker can fix a victim's session id in advance and
; then use it once the victim logs in.
session.use_strict_mode = 1
session.cookie_httponly = 1
session.cookie_samesite = Lax
session.use_only_cookies = 1

; DB host "localhost" means the MySQL unix socket; point mysqlnd at Ubuntu's
; socket path (the compiled-in default is wrong for this layout).
mysqli.default_socket = /var/run/mysqld/mysqld.sock
pdo_mysql.default_socket = /var/run/mysqld/mysqld.sock
CONF

# A placeholder pool so PHP-FPM starts before any apps exist; real per-app
# pools are dropped into pool.d by the agent.
cat > "${STAGE}${prefix}/etc/pool.d/000-default.conf" <<CONF
[default]
user = www-data
group = www-data
listen = /run/fcp/php${PHP_VERSION}-default.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
CONF

# OPcache tuning via a conf.d drop-in (also shows users the pattern for their
# own extension/ini snippets). Older PHP branches build OPcache as a shared
# zend extension that must be loaded explicitly; newer ones link it statically.
opcache_load=""
if ls "${STAGE}${prefix}"/lib/php/extensions/*/opcache.so >/dev/null 2>&1; then
  opcache_load="zend_extension=opcache.so
"
fi
cat > "${STAGE}${prefix}/etc/conf.d/10-opcache.ini" <<CONF
; FastCP defaults for OPcache. Drop additional .ini files in this directory to
; load extra extensions (extension=/zend_extension=) or override settings.
${opcache_load}opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 192
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 20000
opcache.validate_timestamps = 1
opcache.revalidate_freq = 2
CONF

log "php ${PHP_FULL_VERSION} staged under ${STAGE}${prefix}"
log "package with: PHP_VERSION=${PHP_VERSION} PHP_FULL_VERSION=${PHP_FULL_VERSION} STAGE=${STAGE} REPO=${REPO} ${REPO}/build/package.sh fcp-php"
