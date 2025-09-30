#!/bin/sh
#
# install.sh — installs pg_dump (psql), gpg, aws-cli, and supercronic on Alpine.
#
# Strict mode: fail on errors, unset vars, and failed pipeline commands.
set -euo pipefail
set -x

# ---- expected inputs ----
: "${TARGETARCH:?TARGETARCH not set}"       # amd64 | arm64 (from buildx)
: "${POSTGRES_VERSION:?POSTGRES_VERSION not set}"   # e.g. 16, 15
SUPERCRONIC_VERSION="${SUPERCRONIC_VERSION:-0.2.36}"

# Map TARGETARCH to asset arch (adjust here if you add more)
case "$TARGETARCH" in
  amd64|arm64) ARCH="$TARGETARCH" ;;
  *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;;
esac

SUPERCRONIC_BIN="supercronic-linux-${ARCH}"
SUPERCRONIC_URL="https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/${SUPERCRONIC_BIN}"

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
  ca-certificates

# Verify the installed psql major matches POSTGRES_VERSION (extra safety)
INSTALLED_MAJOR="$(psql --version | awk '{print $3}' | cut -d. -f1)"
if [ "$INSTALLED_MAJOR" != "$POSTGRES_VERSION" ]; then
  echo "ERROR: Installed psql major ($INSTALLED_MAJOR) != requested ($POSTGRES_VERSION)." >&2
  exit 1
fi

# ---- install supercronic ----
tmpdir="$(mktemp -d)"
# Always delete the temporary download directory when the script stops (success or error).
trap 'rm -rf "$tmpdir"' EXIT

curl -fSL "$SUPERCRONIC_URL" -o "$tmpdir/$SUPERCRONIC_BIN"

if [ -z "${SUPERCRONIC_SHA1SUM:-}" ]; then
  echo "ERROR: SUPERCRONIC_SHA1SUM must be provided for ${SUPERCRONIC_BIN}." >&2
  echo "Hint: export SUPERCRONIC_SHA1SUM for v${SUPERCRONIC_VERSION} or update install.sh defaults." >&2
  exit 1
fi

# Recalculate the checksum of the downloaded file; abort if it differs from the expected hash.
(cd "$tmpdir" && printf '%s  %s\n' "$SUPERCRONIC_SHA1SUM" "$SUPERCRONIC_BIN" | sha1sum -c -)

# Copy the binary into /usr/local/bin and mark it executable in the same step.
install -m 0755 "$tmpdir/$SUPERCRONIC_BIN" \
  "/usr/local/bin/$SUPERCRONIC_BIN"
ln -sf "/usr/local/bin/$SUPERCRONIC_BIN" /usr/local/bin/supercronic

# slim down
apk del curl || true

# ---- smoke checks ----
psql --version
aws --version
/usr/local/bin/supercronic --help >/dev/null

echo "install.sh OK — TARGETARCH=${TARGETARCH}, POSTGRES_VERSION=${POSTGRES_VERSION}"
