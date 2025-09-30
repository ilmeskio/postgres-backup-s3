#!/bin/sh
#
# install.sh — installs pg_dump (psql), gpg, aws-cli, and supercronic on Alpine.
#
# We enable strict mode to fail on errors, unset vars, and pipeline issues.
set -euo pipefail
set -x

# ---- expected inputs ----
# We use the `:` builtin with `${VAR:?}` to assert the variable is set; otherwise the script stops with the message we provide.
# That gives us quick feedback when required build arguments such as TARGETARCH and POSTGRES_VERSION are missing.
: "${TARGETARCH:?TARGETARCH not set}"       # amd64 | arm64 (from buildx)
: "${POSTGRES_VERSION:?POSTGRES_VERSION not set}"   # e.g. 16, 15
SUPERCRONIC_VERSION="${SUPERCRONIC_VERSION:-0.2.36}"

# We map the buildx architecture string to the asset name used by the release downloads.
# If the supercronic project later publishes binaries for more architectures (e.g., ppc64le), we add another
# pattern here so the right filename is selected—no repo branching required.
case "$TARGETARCH" in
  amd64|arm64) ARCH="$TARGETARCH" ;;
  *) echo "Unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;;
esac

SUPERCRONIC_BIN="supercronic-linux-${ARCH}"
SUPERCRONIC_URL="https://github.com/aptible/supercronic/releases/download/v${SUPERCRONIC_VERSION}/${SUPERCRONIC_BIN}"

# ---- base packages ----
apk update

# We try to install the requested PostgreSQL client package; if Alpine can’t find it, we stop with a helpful hint.
PG_CLIENT="postgresql${POSTGRES_VERSION}-client"
if ! apk add --no-cache "$PG_CLIENT"; then
  echo "ERROR: Package '$PG_CLIENT' is not available on this Alpine base ($(cat /etc/alpine-release))." >&2
  echo "Hint: try a different POSTGRES_VERSION (e.g., 16 or 15) or pin a compatible ALPINE_VERSION (e.g., 3.19/3.20) in your Dockerfile." >&2
  exit 1
fi

# We install the remaining tools we depend on: gnupg for encryption, aws-cli for S3 access, curl for downloads,
# and ca-certificates to trust HTTPS endpoints.
apk add --no-cache \
  gnupg \
  aws-cli \
  curl \
  ca-certificates

# We double-check that the psql client major version matches POSTGRES_VERSION to avoid protocol surprises.
INSTALLED_MAJOR="$(psql --version | awk '{print $3}' | cut -d. -f1)"
if [ "$INSTALLED_MAJOR" != "$POSTGRES_VERSION" ]; then
  echo "ERROR: Installed psql major ($INSTALLED_MAJOR) != requested ($POSTGRES_VERSION)." >&2
  exit 1
fi

# ---- install supercronic ----
# We create a fresh temporary directory for downloads so the build stays clean. `mktemp -d` prints a unique path
# like /tmp/tmp.abcd1234.
tmpdir="$(mktemp -d)"
# `trap ... EXIT` registers a cleanup command that runs when the script finishes (even on errors or Ctrl+C).
# We delete the directory here so we never leave stray temporary files behind.
trap 'rm -rf "$tmpdir"' EXIT

# We fetch the prebuilt supercronic release. curl's flags matter here: -f fails on HTTP errors, -S prints errors,
# and -L follows redirects from GitHub's CDN.
curl -fSL "$SUPERCRONIC_URL" -o "$tmpdir/$SUPERCRONIC_BIN"

if [ -z "${SUPERCRONIC_SHA1SUM:-}" ]; then
  echo "ERROR: SUPERCRONIC_SHA1SUM must be provided for ${SUPERCRONIC_BIN}." >&2
  echo "Hint: export SUPERCRONIC_SHA1SUM for v${SUPERCRONIC_VERSION} or update install.sh defaults." >&2
  exit 1
fi

# We build the expected checksum line (`<hash><two spaces><filename>`) and feed it into sha1sum.
# sha1sum then recomputes the digest of the downloaded binary and compares it to the supplied hex string.
# If they differ, sha1sum exits with status 1 and, thanks to `set -e`, the script stops immediately.
(cd "$tmpdir" && printf '%s  %s\n' "$SUPERCRONIC_SHA1SUM" "$SUPERCRONIC_BIN" | sha1sum -c -)

# We use the `install` utility to copy the file and adjust permissions in a single command. `-m 0755` sets rwxr-xr-x so
# anyone can execute the binary once it lands in /usr/local/bin.
install -m 0755 "$tmpdir/$SUPERCRONIC_BIN" \
  "/usr/local/bin/$SUPERCRONIC_BIN"
# We keep a stable name (`supercronic`) in PATH while still preserving the architecture-specific filename.
ln -sf "/usr/local/bin/$SUPERCRONIC_BIN" /usr/local/bin/supercronic

# We remove the build-only download helper to keep the final image slim.
apk del curl || true

# ---- smoke checks ----
# We confirm the key binaries respond so the build fails fast if any dependency is missing.
psql --version
aws --version
/usr/local/bin/supercronic --help >/dev/null

echo "install.sh OK — TARGETARCH=${TARGETARCH}, POSTGRES_VERSION=${POSTGRES_VERSION}"
