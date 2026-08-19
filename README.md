# FastCP packaging

From-source, hardened, FastCP-branded builds of the FastCP web stack (nginx,
Apache, PHP-FPM 8.2–8.5, composer, wp-cli, and `fcp-mysql`), published to our own signed APT
repository. No ServerPilot binaries are used or redistributed.

The `fastcp-agent` package is built and published by the agent's own repository;
this repo owns only the web stack and the APT repo publishing pipeline.

## Layout produced

- `/opt/fcp/nginx` — public web server (ports 80/443), reverse-proxies to Apache
- `/opt/fcp/apache` — internal app server on `127.0.0.1:81`, PHP via FPM sockets,
  full `.htaccess` support behind the nginx proxy
- `/opt/fcp/php/<ver>` — co-installable PHP-FPM builds (8.2–8.5 by default) with
  the common extension set (gd, intl, bcmath, soap, exif, sodium, …) compiled in
  and an `etc/conf.d/` drop-in dir for extra extension/ini snippets
- `/etc/nginx-fcp`, `/etc/apache-fcp` — configs; per-app vhosts under `vhosts.d/`
  (no sites-available/sites-enabled)
- `/run/fcp` — runtime sockets/pids (per-app FPM sockets `<user>.<app>.sock`)
- `/etc/mysql/mysql.conf.d/90-fastcp.cnf` — local-only, durable MySQL defaults;
  `91-fastcp-autotune.cnf` is generated from host/cgroup memory

These paths and the service names (`fcp-nginx`, `fcp-apache`, `fcp-php<ver>-fpm`)
are what the agent's executor writes to and reloads.

All builds carry FastCP branding: `nginx -v` reports `(FastCP)`, Apache's server
token is `Apache/2.4.x (FastCP)`, and `phpinfo()` shows
`Build Provider => FastCP (https://fastcp.io)`.

## Build and publish

On an adequately sized Ubuntu build host (>= 4 GB RAM recommended for the PHP
builds):

```bash
build/install-build-deps.sh   # toolchain + -dev libraries
build/bootstrap-tools.sh      # nfpm + aptly

# Build and package the whole stack (nginx, apache, PHP 8.2-8.5, composer,
# wp-cli, php-cli, MySQL profile) into dist/:
build/build-all.sh

# Or build individual components:
build/build-nginx.sh  && build/package.sh fcp-nginx
build/build-apache.sh && build/package.sh fcp-apache
PHP_VERSION=8.3 PHP_FULL_VERSION=8.3.15 build/build-php.sh
PHP_VERSION=8.3 PHP_FULL_VERSION=8.3.15 build/package.sh fcp-php
```

Production publication is intentionally available only through the serialized,
protected GitHub Actions workflow. Clients add:

```
deb [signed-by=/usr/share/keyrings/fastcp.gpg] https://repo.fastcp.io noble main
```

> Pin verified upstream release hashes by setting the `*_SHA256` env vars in the
> `build-*.sh` scripts before building.

## CI: build in GitHub Actions, publish to R2

[.github/workflows/packages.yml](.github/workflows/packages.yml) builds the
whole stack for each supported Ubuntu LTS and architecture on a native runner of
that exact OS/arch (so packages link against the correct system libraries), then
signs and syncs the APT repo to Cloudflare R2.

- Trigger: push a `v*` tag, or run it manually (`workflow_dispatch`).
- Build matrix: `jammy`/`noble` x `amd64`/`arm64`. Each job runs
  [install-build-deps.sh](build/install-build-deps.sh) then
  [build-all.sh](build/build-all.sh) and uploads `debs-<codename>-<arch>`.
- Publish job imports the signing key, configures rclone for R2, and runs
  [publish-ci.sh](repo/publish-ci.sh) to build a multi-distribution
  (`dists/jammy`, `dists/noble`), multi-arch repo and
  `rclone sync` it to R2.

Required repository secrets:

| Secret | Purpose |
| --- | --- |
| `FCP_GPG_PRIVATE_KEY` | armored GPG private key that signs the repo |
| `FCP_GPG_EMAIL` | identity of that key (e.g. `ops@fastcp.io`) |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Cloudflare R2 S3 credentials |
| `R2_ENDPOINT` | `https://<accountid>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | target bucket (e.g. `fastcp-repo`) |

Set protected repository variable `AGENT_REPOSITORY` to the exact
`owner/fastcp-agent` source. Agent dispatches include an authenticated manifest
digest, and publication verifies package identity, architecture, checksums, and
GitHub build provenance before signing.

Each run republishes the full current stack (latest-wins) and mirrors it to R2.
Bind `repo.fastcp.io` to the bucket once as an R2 custom domain.
Every run also writes an immutable, checksummed tree under
`snapshots/<run>-<commit>/` and updates the no-cache `current-snapshot` pointer.
The live pool retains prior package versions so an operator can restore a
previous signed snapshot without rebuilding artifacts.

The only supported origin is the versioned R2 publication produced by
`repo/publish-ci.sh`; alternate sync paths were removed because they could race
or delete installer and rollback artifacts.

## Security posture

- Every package is built from verified upstream source (set the `*_SHA256`
  env vars to pin release hashes; the scripts fail closed on mismatch).
- Only currently-supported PHP versions are enabled by default. Legacy PHP can
  be built on a separate track but is opt-in for security.
- PHP-FPM pools run as the app's system user with `open_basedir` and dangerous
  functions disabled (see the agent's `render` package).
- nginx and Apache ship hardened defaults: no server version disclosure,
  `TraceEnable off`, deny-all filesystem root, `.ht*` files unreadable.
- The repo is GPG-signed; clients pin the key via `signed-by=`.
