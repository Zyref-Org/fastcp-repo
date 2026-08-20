#!/usr/bin/env bash
# Install the toolchain and -dev libraries needed to build the FastCP stack
# (nginx, apache, PHP-FPM) from source on an Ubuntu build host / CI runner.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  build-essential autoconf automake libtool bison re2c pkg-config \
  ca-certificates curl wget git rsync file gettext-base jq \
  zlib1g-dev libpcre2-dev libssl-dev \
  libxml2-dev libsqlite3-dev libcurl4-openssl-dev libonig-dev libzip-dev \
  libapr1-dev libaprutil1-dev libicu-dev \
  libpng-dev libjpeg-dev libwebp-dev libfreetype-dev \
  libxslt1-dev libsodium-dev libgmp-dev libsystemd-dev \
  ccache

echo "build deps installed"
