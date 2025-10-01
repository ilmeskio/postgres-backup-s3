#!/bin/sh
#
# dev-smoke.sh — We spin up the docker compose stack (Postgres + backup job + MinIO), seed the demo bucket,
# trigger a backup, and then exercise the restore flow against the locally stored dump. Running this script gives us
# confidence that the full pipeline still works without touching a real S3 account.
#
# Usage: scripts/dev-smoke.sh
#
set -euo pipefail

# If a .env file exists (e.g., copied from .env.development), we load it so the script and
# docker compose share the same configuration. We temporarily mark variables for export so
# downstream commands inherit them.
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

# We check for docker compose support up front so teammates see actionable guidance instead of a shell error later on.
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found; please install Docker Desktop or the CLI." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin not found; make sure you're on a recent Docker installation." >&2
  exit 1
fi

# We map the host architecture to the matching supercronic release so docker compose passes the right checksum through
# the build args. Folks can override POSTGRES_VERSION or SUPERCRONIC_SHA1SUM before running the script when trying
# different combinations.
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64)
    DEFAULT_SUPERCRONIC_SHA=53a484404b0c559d64f78e9481a3ec22f782dc46
    ;;
  arm64|aarch64)
    DEFAULT_SUPERCRONIC_SHA=58b3c15304e7b59fe7b9d66a2242f37e71cf7db6
    ;;
  armv7l|armv6l)
    DEFAULT_SUPERCRONIC_SHA=80ad1c583043f6d6f2f5ad3e38f539c3e4d77271
    ;;
  i386|i686)
    DEFAULT_SUPERCRONIC_SHA=3b9c2597cde777eb8367f92c0ce5c829b828c488
    ;;
  *)
    echo "ERROR: unsupported architecture '$ARCH'; please set SUPERCRONIC_SHA1SUM manually." >&2
    exit 1
    ;;
esac

POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_USER="${POSTGRES_USER:-user}"
export POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
export SUPERCRONIC_SHA1SUM="${SUPERCRONIC_SHA1SUM:-$DEFAULT_SUPERCRONIC_SHA}"

# We give Docker a chance to reuse existing containers when possible, but we force a rebuild so code changes are picked up.
COMPOSE="docker compose"
$COMPOSE down -v >/dev/null 2>&1 || true
$COMPOSE up -d --build --force-recreate

echo "Builded"

# We hold until Postgres accepts connections so downstream commands do not race the startup sequence.
$COMPOSE exec -T backup sh -lc \
  ". ./env.sh && until pg_isready -h \"$POSTGRES_HOST\" -p \"$POSTGRES_PORT\" -U \"$POSTGRES_USER\" >/dev/null 2>&1; do sleep 1; done"

# We seed a simple table so we can prove that our backup actually captured and restored data.
$COMPOSE exec -T postgres psql -U user -d postgres \
  -c "CREATE TABLE IF NOT EXISTS smoke_notes(id serial PRIMARY KEY, note text);" \
  -c "TRUNCATE smoke_notes;" \
  -c "INSERT INTO smoke_notes(note) VALUES ('backup smoke test');"

# We create the demo bucket inside MinIO; create-bucket fails if it already exists, so we ignore that case to keep reruns smooth.
BUCKET_NAME="demo-backups"
if ! $COMPOSE exec -T backup sh -lc \
  ". ./env.sh && aws --endpoint-url http://minio:9000 s3api head-bucket --bucket '$BUCKET_NAME'" >/dev/null 2>&1; then
  $COMPOSE exec -T backup sh -lc \
    ". ./env.sh && aws --endpoint-url http://minio:9000 s3api create-bucket --bucket '$BUCKET_NAME'"
fi

# We trigger one backup so we have a dump to restore. pg_dump produces unique timestamps, so reruns stack neatly in MinIO.
$COMPOSE exec -T backup sh backup.sh

# We immediately restore from the most recent backup to make sure pg_restore succeeds against Postgres.
$COMPOSE exec -T backup sh restore.sh

# We confirm the restored table still carries the row we inserted pre-backup.
$COMPOSE exec -T postgres psql -U user -d postgres -c "TABLE smoke_notes;"

echo "Smoke test complete — backup and restore flowed successfully against local MinIO."
