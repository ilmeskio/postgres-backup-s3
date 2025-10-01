#!/bin/sh
#
# build-image.sh — We run this helper to confirm that our Docker image still assembles with the defaults we ship.
# The script feeds our preferred build arguments into docker build so our pre-push hook and CI pipeline can catch
# version drifts or missing checksums before we share changes.
#
# We keep strict mode on so the build check fails fast: `-e` stops on docker errors, `-u` catches missing env vars,
# and (when supported) `-o pipefail` surfaces issues in piped commands during the compose build.
set -eu
set -o pipefail 2>/dev/null || true

# When a .env file exists (e.g., copied from .env.development) we load it so docker compose and this script share
# the same defaults.
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

# We ensure Docker (and docker compose) are available before we do anything costly so teammates see a clear message
# instead of a stack trace.
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker is not on PATH; please install Docker Desktop or the CLI." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin not found; make sure you're on a recent Docker installation." >&2
  exit 1
fi

# We derive the architecture-specific checksum so the integrity check in install.sh succeeds without extra input.
# The mapping mirrors the release assets from https://github.com/aptible/supercronic/releases/tag/v0.2.36.
case "$(uname -m)" in
  x86_64)
    arch=amd64
    default_supercronic_sha=53a484404b0c559d64f78e9481a3ec22f782dc46
    ;;
  arm64|aarch64)
    arch=arm64
    default_supercronic_sha=58b3c15304e7b59fe7b9d66a2242f37e71cf7db6
    ;;
  armv7l|armv6l)
    arch=arm
    default_supercronic_sha=80ad1c583043f6d6f2f5ad3e38f539c3e4d77271
    ;;
  i386|i686)
    arch=386
    default_supercronic_sha=3b9c2597cde777eb8367f92c0ce5c829b828c488
    ;;
  *)
    echo "ERROR: unsupported architecture '$(uname -m)'; please set SUPERCRONIC_SHA1SUM manually." >&2
    exit 1
    ;;
esac

# We allow teammates to override the knobs through environment variables so the same hook can exercise feature branches.
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
SUPERCRONIC_SHA1SUM="${SUPERCRONIC_SHA1SUM:-$default_supercronic_sha}"

export ALPINE_VERSION POSTGRES_VERSION SUPERCRONIC_SHA1SUM

# We let folks confirm what is about to happen, celebrating that the hook is doing real validation for us.
echo "Running docker compose build for backup with ALPINE_VERSION=${ALPINE_VERSION}, POSTGRES_VERSION=${POSTGRES_VERSION}, SUPERCRONIC_SHA1SUM=${SUPERCRONIC_SHA1SUM}"

# Compose picks up the build arguments declared in Dockerfile via these environment variables, giving us the same build
# path the smoke test uses without bringing the entire stack online.
docker compose build backup
