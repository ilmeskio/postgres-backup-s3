#!/bin/sh
#
# install.sh — installs pg_dump (psql), gpg, aws-cli, and go-cron on Alpine.
#
# Strict mode: fail on errors, unset vars, and failed pipeline commands.
set -euo pipefail
set -x

# ---- expected inputs ----
: "${TARGETARCH:?TARGETARCH not set}"       # amd64 | arm64 (from buildx)
: "${POSTGRES_VERSION:?POSTGRES_VERSION not set}"   # e.g. 16, 15
GOCRON_VERSION="${GOCRON_VERSION:-0.0.5}"

# Map TARGETARCH to asset arch (adjust here if you add more)
case "$TARGETARCH" in
  amd64|arm64) ARCH="$TARGETARCH" ;;
  *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;;
esac

GOCRON_URL="https://github.com/ivoronin/go-cron/releases/download/v${GOCRON_VERSION}/go-cron_${GOCRON_VERSION}_linux_${ARCH}.tar.gz"

# ---- base packages ----
apk update

# Safeguard: attempt to install the requested PG client; if it’s not available, error nicely.
PG_CLIENT="postgresql${POSTGRES_VERSION}-client"
if ! apk add --no-cache "$PG_CLIENT"; then
  echo "ERROR: Package '$PG_CLIENT' is not available on this Alpine base ($(cat /etc/alpine-release))." >&2
  echo "Hint: try a different POSTGRES_VERSION (e.g., 16 or 15) or pin a compatible ALPINE_VERSION (e.g., 3.19/3.20) in your Dockerfile." >&2
  exit 1
fi

# Rest of deps
apk add --no-cache \
  gnupg \
  aws-cli \
  curl \
  ca-certificates \
  tar

# Verify the installed psql major matches POSTGRES_VERSION (extra safety)
INSTALLED_MAJOR="$(psql --version | awk '{print $3}' | cut -d. -f1)"
if [ "$INSTALLED_MAJOR" != "$POSTGRES_VERSION" ]; then
  echo "ERROR: Installed psql major ($INSTALLED_MAJOR) != requested ($POSTGRES_VERSION)." >&2
  exit 1
fi

# ---- install go-cron ----
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

curl -fSL "$GOCRON_URL" -o "$tmpdir/go-cron.tgz"
tar xvf "$tmpdir/go-cron.tgz" -C "$tmpdir"
install -m 0755 "$tmpdir/go-cron" /usr/local/bin/go-cron

# slim down
apk del curl || true

# ---- smoke checks ----
psql --version
aws --version
/usr/local/bin/go-cron -h >/dev/null

echo "install.sh OK — TARGETARCH=${TARGETARCH}, POSTGRES_VERSION=${POSTGRES_VERSION}"
