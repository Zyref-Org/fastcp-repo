# FastCP packaging

From-source, hardened, FastCP-branded builds of the FastCP web stack (nginx,
Apache, PHP-FPM 8.1–8.5, composer, wp-cli), published to our own signed APT
repository. No ServerPilot binaries are used or redistributed.

The `fastcp-agent` package is built and published by the agent's own repository;
this repo owns only the web stack and the APT repo publishing pipeline.

## Layout produced

- `/opt/fcp/nginx` — public web server (ports 80/443), reverse-proxies to Apache
- `/opt/fcp/apache` — internal app server on `127.0.0.1:81`, PHP via FPM sockets,
  full `.htaccess` support behind the nginx proxy
- `/opt/fcp/php/<ver>` — co-installable PHP-FPM builds (8.1–8.5 by default) with
  the common extension set (gd, intl, bcmath, soap, exif, sodium, …) compiled in
  and an `etc/conf.d/` drop-in dir for extra extension/ini snippets
- `/etc/nginx-fcp`, `/etc/apache-fcp` — configs; per-app vhosts under `vhosts.d/`
  (no sites-available/sites-enabled)
- `/run/fcp` — runtime sockets/pids (per-app FPM sockets `<user>.<app>.sock`)

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

# Build and package the whole stack (nginx, apache, PHP 8.1-8.5, composer,
# wp-cli, php-cli) into dist/:
build/build-all.sh

# Or build individual components:
build/build-nginx.sh  && build/package.sh fcp-nginx
build/build-apache.sh && build/package.sh fcp-apache
PHP_VERSION=8.3 PHP_FULL_VERSION=8.3.15 build/build-php.sh
PHP_VERSION=8.3 PHP_FULL_VERSION=8.3.15 build/package.sh fcp-php
```

Publish and serve the signed repository on the repo host (DNS for
`repo.fastcp.io` must point at it):

```bash
FCP_REPO_DOMAIN=repo.fastcp.io repo/init-and-serve.sh
```

That generates the repo signing key (once), publishes `dist/*.deb` with aptly,
exports the public key to `/<repo>/fastcp.gpg`, and serves it over HTTPS via
Caddy. Clients (the installer) then add:

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
- Build matrix: `jammy`/`noble`/`resolute` x `amd64`/`arm64` (the
  `ubuntu-26.04` runners are in public preview). Each job runs
  [install-build-deps.sh](build/install-build-deps.sh) then
  [build-all.sh](build/build-all.sh) and uploads `debs-<codename>-<arch>`.
- Publish job imports the signing key, configures rclone for R2, and runs
  [publish-ci.sh](repo/publish-ci.sh) to build a multi-distribution
  (`dists/jammy`, `dists/noble`, `dists/resolute`), multi-arch repo and
  `rclone sync` it to R2.

Required repository secrets:

| Secret | Purpose |
| --- | --- |
| `FCP_GPG_PRIVATE_KEY` | armored GPG private key that signs the repo |
| `FCP_GPG_EMAIL` | identity of that key (e.g. `ops@fastcp.io`) |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | Cloudflare R2 S3 credentials |
| `R2_ENDPOINT` | `https://<accountid>.r2.cloudflarestorage.com` |
| `R2_BUCKET` | target bucket (e.g. `fastcp-repo`) |

Each run republishes the full current stack (latest-wins) and mirrors it to R2.
Bind `repo.fastcp.io` to the bucket once as an R2 custom domain.

### Hosting options

The published repo is static files, so it can be served by any static origin:

- **Own server (Caddy)**: `repo/init-and-serve.sh` publishes and serves
  it over HTTPS on the repo host.
- **Cloudflare R2 (no server)**: `repo/publish-r2.sh` signs locally and
  `rclone sync`s the published tree to an R2 bucket; bind `repo.fastcp.io` to the
  bucket as an R2 custom domain. Signing still happens on the build host with the
  private GPG key; R2 only serves the signed, static tree.

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
