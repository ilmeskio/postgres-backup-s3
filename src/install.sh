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
# Create a fresh temporary directory for downloads so the build stays clean. `mktemp -d` prints a unique path
# like /tmp/tmp.abcd1234.
tmpdir="$(mktemp -d)"
# `trap ... EXIT` registers a cleanup command that runs when the script finishes (even on errors or Ctrl+C).
# Deleting the directory here means we never leave stray temporary files behind.
trap 'rm -rf "$tmpdir"' EXIT

# Fetch the prebuilt supercronic release. curl's flags matter here: -f fails on HTTP errors, -S prints errors,
# and -L follows redirects from GitHub's CDN.
curl -fSL "$SUPERCRONIC_URL" -o "$tmpdir/$SUPERCRONIC_BIN"

if [ -z "${SUPERCRONIC_SHA1SUM:-}" ]; then
  echo "ERROR: SUPERCRONIC_SHA1SUM must be provided for ${SUPERCRONIC_BIN}." >&2
  echo "Hint: export SUPERCRONIC_SHA1SUM for v${SUPERCRONIC_VERSION} or update install.sh defaults." >&2
  exit 1
fi

# Build the expected checksum line (`<hash><two spaces><filename>`) and feed it into sha1sum.
# sha1sum recomputes the digest of the downloaded binary and compares it to the supplied hex string.
# If they differ, sha1sum exits with status 1 and, thanks to `set -e`, the script stops immediately.
(cd "$tmpdir" && printf '%s  %s\n' "$SUPERCRONIC_SHA1SUM" "$SUPERCRONIC_BIN" | sha1sum -c -)

# The `install` utility copies the file and adjusts permissions in a single command. `-m 0755` sets rwxr-xr-x so
# anyone can execute the binary once it lands in /usr/local/bin.
install -m 0755 "$tmpdir/$SUPERCRONIC_BIN" \
  "/usr/local/bin/$SUPERCRONIC_BIN"
# Keep a stable name (`supercronic`) in PATH while still preserving the architecture-specific filename.
ln -sf "/usr/local/bin/$SUPERCRONIC_BIN" /usr/local/bin/supercronic

# slim down
apk del curl || true

# ---- smoke checks ----
psql --version
aws --version
/usr/local/bin/supercronic --help >/dev/null

echo "install.sh OK — TARGETARCH=${TARGETARCH}, POSTGRES_VERSION=${POSTGRES_VERSION}"
