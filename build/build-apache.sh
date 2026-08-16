#!/usr/bin/env bash
# Build Apache httpd from source into /opt/fcp/apache, configured as the internal
# application server on 127.0.0.1:81 that proxies PHP to per-app FPM sockets and
# fully supports .htaccess behind the FastCP nginx reverse proxy.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

APACHE_VERSION="${APACHE_VERSION:-2.4.68}"
APACHE_SHA256="${APACHE_SHA256:-ed9a9d4500fb48bb28eaffb3ba71d06ccf86d498fa13ab9f781da010cc488498}"
src="${BUILD}/httpd-${APACHE_VERSION}.tar.gz"

# dlcdn.apache.org only hosts the current release; superseded releases move
# to archive.apache.org, hence the fallback URL.
fetch "https://dlcdn.apache.org/httpd/httpd-${APACHE_VERSION}.tar.gz" "${APACHE_SHA256}" "${src}" \
  "https://archive.apache.org/dist/httpd/httpd-${APACHE_VERSION}.tar.gz" \
  || log "checksum not pinned: set APACHE_SHA256 for a verified build"

rm -rf "${BUILD}/httpd-${APACHE_VERSION}"
tar -C "${BUILD}" -xzf "${src}"
cd "${BUILD}/httpd-${APACHE_VERSION}"

# Brand the build: the platform token becomes FastCP, so `httpd -v` and the
# server signature read "Apache/x.y.z (FastCP)" instead of "(Unix)".
sed -i 's/#define PLATFORM "Unix"/#define PLATFORM "FastCP"/' os/unix/os.h

./configure \
  --prefix=/opt/fcp/apache \
  --sysconfdir=/etc/apache-fcp \
  --enable-so \
  --enable-rewrite \
  --enable-proxy \
  --enable-proxy-fcgi \
  --enable-proxy-http \
  --enable-headers \
  --enable-remoteip \
  --enable-expires \
  --enable-deflate \
  --enable-filter \
  --with-mpm=event

make -j"${JOBS}"
make install DESTDIR="${STAGE}"

install -d "${STAGE}/etc/apache-fcp/vhosts.d"
cat > "${STAGE}/etc/apache-fcp/httpd.conf" <<'CONF'
# FastCP Apache internal application server — customized build by FastCP
# https://fastcp.io
# Runs behind the FastCP nginx reverse proxy on 127.0.0.1:81. Per-app vhosts
# are managed by the FastCP agent in /etc/apache-fcp/vhosts.d (AllowOverride
# All in each vhost enables full .htaccess support).

ServerRoot "/opt/fcp/apache"
Listen 127.0.0.1:81
ServerName localhost
PidFile /run/fcp/apache.pid

# --- Modules ---
LoadModule mpm_event_module modules/mod_mpm_event.so
LoadModule unixd_module modules/mod_unixd.so
LoadModule authn_core_module modules/mod_authn_core.so
LoadModule authn_file_module modules/mod_authn_file.so
LoadModule auth_basic_module modules/mod_auth_basic.so
LoadModule authz_core_module modules/mod_authz_core.so
LoadModule authz_host_module modules/mod_authz_host.so
LoadModule authz_user_module modules/mod_authz_user.so
LoadModule access_compat_module modules/mod_access_compat.so
LoadModule dir_module modules/mod_dir.so
LoadModule mime_module modules/mod_mime.so
LoadModule log_config_module modules/mod_log_config.so
LoadModule env_module modules/mod_env.so
LoadModule setenvif_module modules/mod_setenvif.so
LoadModule alias_module modules/mod_alias.so
LoadModule rewrite_module modules/mod_rewrite.so
LoadModule headers_module modules/mod_headers.so
LoadModule expires_module modules/mod_expires.so
LoadModule filter_module modules/mod_filter.so
LoadModule deflate_module modules/mod_deflate.so
LoadModule remoteip_module modules/mod_remoteip.so
LoadModule status_module modules/mod_status.so
LoadModule proxy_module modules/mod_proxy.so
LoadModule proxy_fcgi_module modules/mod_proxy_fcgi.so
LoadModule proxy_http_module modules/mod_proxy_http.so

User www-data
Group www-data

# --- MPM (event) tuning ---
# Scales from small VPSes to large dedicated servers: threads are cheap and
# spare-thread bounds keep the footprint low when idle. PHP concurrency is
# governed by each app's PHP-FPM pool, so Apache mostly shuttles requests
# and serves static files.
StartServers            2
ServerLimit             16
ThreadsPerChild         64
MaxRequestWorkers       1024
MinSpareThreads         64
MaxSpareThreads         256
MaxConnectionsPerChild  10000

# --- Timeouts / keep-alive (loopback connections from nginx) ---
Timeout 60
KeepAlive On
KeepAliveTimeout 5
MaxKeepAliveRequests 1000

# --- Reverse-proxy integration ---
# Restore the real client IP from the header set by the FastCP nginx vhosts,
# and mark TLS-terminated requests so PHP applications detect HTTPS.
RemoteIPHeader X-Real-IP
RemoteIPInternalProxy 127.0.0.1 ::1
SetEnvIf X-Forwarded-Proto "^https$" HTTPS=on

# --- Security ---
ServerTokens Prod
ServerSignature Off
TraceEnable Off
HostnameLookups Off
<Directory />
    AllowOverride None
    Require all denied
</Directory>
<Files ".ht*">
    Require all denied
</Files>

# --- Defaults ---
DirectoryIndex index.php index.html
TypesConfig conf/mime.types
EnableSendfile On

ErrorLog /var/log/fcp/apache-error.log
LogLevel warn
LogFormat "%a %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%a %l %u %t \"%r\" %>s %b" common

# Local status endpoint for diagnostics (apachectl status, monitoring).
ExtendedStatus On
<Location "/fcp-server-status">
    SetHandler server-status
    Require local
</Location>

# Default document root until the agent writes per-app vhosts.
DocumentRoot "/opt/fcp/apache/htdocs"
<Directory "/opt/fcp/apache/htdocs">
    Options -Indexes +FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>

# Per-app vhosts written by the FastCP agent.
IncludeOptional /etc/apache-fcp/vhosts.d/*.conf
CONF

log "apache ${APACHE_VERSION} staged under ${STAGE}/opt/fcp/apache"
log "package with: APACHE_VERSION=${APACHE_VERSION} STAGE=${STAGE} REPO=${REPO} ${REPO}/build/package.sh fcp-apache"
