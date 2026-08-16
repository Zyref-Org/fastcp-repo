#!/usr/bin/env bash
# Build nginx from source into the FastCP layout (/opt/fcp/nginx) and stage a
# tuned default configuration under /etc/nginx-fcp. Run on an Ubuntu build host
# with build-essential, libpcre2-dev, zlib1g-dev, libssl-dev installed.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

NGINX_VERSION="${NGINX_VERSION:-1.30.4}"
NGINX_SHA256="${NGINX_SHA256:-4261dc90e9e47c1c4041276e9aaa3d48ebe2e664f728e14fa95ae6c67d57a08b}"
src="${BUILD}/nginx-${NGINX_VERSION}.tar.gz"

fetch "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz" "${NGINX_SHA256}" "${src}" \
  || log "checksum not pinned: set NGINX_SHA256 for a verified build"

rm -rf "${BUILD}/nginx-${NGINX_VERSION}"
tar -C "${BUILD}" -xzf "${src}"
cd "${BUILD}/nginx-${NGINX_VERSION}"

# --build brands the binary: `nginx -v` reports nginx/x.y.z (FastCP).
# http_v3 is required because agent-rendered vhosts can emit `listen 443 quic`.
./configure \
  --prefix=/opt/fcp/nginx \
  --conf-path=/etc/nginx-fcp/nginx.conf \
  --pid-path=/run/fcp/nginx.pid \
  --error-log-path=/var/log/fcp/nginx-error.log \
  --http-log-path=/var/log/fcp/nginx-access.log \
  --build="FastCP" \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_v3_module \
  --with-http_realip_module \
  --with-http_gzip_static_module \
  --with-http_gunzip_module \
  --with-http_stub_status_module \
  --with-file-aio \
  --with-pcre-jit \
  --with-threads

make -j"${JOBS}"
make install DESTDIR="${STAGE}"

# Stage a tuned nginx.conf that includes per-app vhosts from vhosts.d.
# worker_processes/rlimits scale automatically, so the same config performs
# well on a 1 GB VPS and a 64-core dedicated server.
install -d "${STAGE}/etc/nginx-fcp/vhosts.d"
cat > "${STAGE}/etc/nginx-fcp/nginx.conf" <<'CONF'
# FastCP nginx main configuration — customized build by FastCP
# https://fastcp.io
# Per-app vhosts are managed by the FastCP agent in /etc/nginx-fcp/vhosts.d.

user  www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/fcp/nginx.pid;
error_log /var/log/fcp/nginx-error.log warn;

events {
    worker_connections 16384;
    multi_accept on;
}

http {
    include       /opt/fcp/nginx/conf/mime.types;
    default_type  application/octet-stream;

    # -- Core performance --
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 30s;
    keepalive_requests 1000;
    reset_timedout_connection on;

    # -- Client limits and timeouts --
    client_max_body_size 128m;
    client_body_buffer_size 128k;
    client_header_timeout 15s;
    client_body_timeout 30s;
    send_timeout 30s;

    # -- Hash sizes (roomy enough for hundreds of vhosts/domains) --
    server_names_hash_max_size 4096;
    server_names_hash_bucket_size 128;
    types_hash_max_size 2048;

    # -- File descriptor cache (static assets served via Apache proxy miss
    #    this, but it accelerates ssl certs, config and any local roots) --
    open_file_cache max=10000 inactive=30s;
    open_file_cache_valid 60s;
    open_file_cache_min_uses 2;
    open_file_cache_errors on;

    # -- Compression (gzip_proxied is required: app responses arrive from the
    #    Apache upstream and would otherwise never be compressed) --
    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types
        text/plain
        text/css
        text/xml
        text/javascript
        application/javascript
        application/json
        application/xml
        application/rss+xml
        application/atom+xml
        image/svg+xml
        application/wasm
        font/ttf;
    gzip_static on;

    # -- Reverse-proxy defaults for the Apache backend on 127.0.0.1:81 --
    proxy_http_version 1.1;
    proxy_connect_timeout 5s;
    proxy_send_timeout 60s;
    proxy_read_timeout 60s;
    proxy_buffer_size 16k;
    proxy_buffers 16 16k;
    proxy_busy_buffers_size 32k;

    # -- Security --
    server_tokens off;

    # -- Logging --
    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" $request_time';
    access_log /var/log/fcp/nginx-access.log main;

    include /etc/nginx-fcp/vhosts.d/*.conf;
}
CONF

log "nginx ${NGINX_VERSION} staged under ${STAGE}/opt/fcp/nginx"
log "package with: NGINX_VERSION=${NGINX_VERSION} STAGE=${STAGE} REPO=${REPO} ${REPO}/build/package.sh fcp-nginx"
