#!/bin/sh
#
# migration-smoke.sh — We rehearse a major-version migration by backing up data from an "old" Postgres,
# then bringing the stack back with a newer Postgres image and restoring the dump. Running this flow keeps us
# confident that our backup artifacts travel cleanly across version upgrades.
#
# Usage: FROM_VERSION=15 TO_VERSION=16 scripts/migration-smoke.sh
#
# We keep POSIX strict mode engaged (`-e` and `-u`) and try to enable `pipefail` when the shell offers it, giving our
# pipelines consistent failure behavior without surprising environments that run BusyBox or dash. We check support in a
# subshell because dash (the /bin/sh on GitHub Actions) aborts before a trailing `|| true` whenever `-e` is already set.
set -u
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi
set -e

# If teammates already keep a .env in place (copied from .env.development), we reuse it so docker compose picks up
# their preferred credentials, bucket, or image overrides. We temporarily export everything to make sure our shell
# and docker compose share the same configuration for the duration of the script.
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

# We confirm Docker and the compose plugin exist before we spin anything up; that way the script fails fast with
# clear guidance instead of plowing ahead to an opaque error.
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found; please install Docker Desktop or the CLI." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin not found; upgrade Docker so compose v2 is available." >&2
  exit 1
fi

# We let folks override the migration path, but we default to 15 -> 16 because that mirrors a common production step.
FROM_VERSION="${FROM_VERSION:-15}"
TO_VERSION="${TO_VERSION:-16}"
if [ "$FROM_VERSION" = "$TO_VERSION" ]; then
  echo "ERROR: FROM_VERSION and TO_VERSION must differ for a migration rehearsal." >&2
  exit 1
fi

# We reuse compose so we do not have to repeat the long command each time. The script keeps MinIO's bucket stable,
# but we scope backups to a dedicated prefix so we never trample other test data in the bucket teammates might keep around.
COMPOSE="docker compose"
POSTGRES_HOST="${POSTGRES_HOST:-postgres}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-postgres}"
POSTGRES_USER="${POSTGRES_USER:-user}"
MIGRATION_PREFIX="${MIGRATION_PREFIX:-migration-smoke}"
if [ "${S3_BUCKET+x}" = "x" ]; then
  ORIGINAL_S3_BUCKET="$S3_BUCKET"
  ORIGINAL_S3_BUCKET_DEFINED=1
else
  ORIGINAL_S3_BUCKET=""
  ORIGINAL_S3_BUCKET_DEFINED=0
fi
ORIGINAL_S3_PREFIX="${S3_PREFIX:-}"
if [ -z "${S3_BUCKET:-}" ]; then
  export S3_BUCKET=demo-backups
fi
export S3_PREFIX="$MIGRATION_PREFIX"

# We make sure supercronic's checksum matches the running architecture. If teammates already set SUPERCRONIC_SHA1SUM
# we keep that, otherwise we pick the default map we maintain in full-stack-smoke.sh to keep everything consistent.
if [ -z "${SUPERCRONIC_SHA1SUM:-}" ]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
  x86_64)
    export SUPERCRONIC_SHA1SUM=53a484404b0c559d64f78e9481a3ec22f782dc46
    ;;
  arm64|aarch64)
    export SUPERCRONIC_SHA1SUM=58b3c15304e7b59fe7b9d66a2242f37e71cf7db6
    ;;
  armv7l|armv6l)
    export SUPERCRONIC_SHA1SUM=80ad1c583043f6d6f2f5ad3e38f539c3e4d77271
    ;;
  i386|i686)
    export SUPERCRONIC_SHA1SUM=3b9c2597cde777eb8367f92c0ce5c829b828c488
    ;;
  *)
    echo "ERROR: unsupported architecture '$ARCH'; please provide SUPERCRONIC_SHA1SUM manually." >&2
    exit 1
    ;;
  esac
fi

# We remember the caller's Postgres version so we can hand it back once we are done. That way running this script does
# not leave the environment in a surprising state for the next command they run.
ORIGINAL_POSTGRES_VERSION="${POSTGRES_VERSION:-}"
restore_env() {
  if [ -n "$ORIGINAL_POSTGRES_VERSION" ]; then
    export POSTGRES_VERSION="$ORIGINAL_POSTGRES_VERSION"
  else
    unset POSTGRES_VERSION || true
  fi
  if [ "$ORIGINAL_S3_BUCKET_DEFINED" -eq 1 ]; then
    export S3_BUCKET="$ORIGINAL_S3_BUCKET"
  else
    unset S3_BUCKET || true
  fi
  if [ -n "$ORIGINAL_S3_PREFIX" ]; then
    export S3_PREFIX="$ORIGINAL_S3_PREFIX"
  else
    unset S3_PREFIX || true
  fi
}
trap restore_env EXIT

# We wrap the pg_isready loop so we can reuse it for both the "from" and "to" phases without duplicating the docker
# exec plumbing.
wait_for_postgres() {
  $COMPOSE exec -T backup sh -lc \
    ". ./env.sh && until pg_isready -h \"$POSTGRES_HOST\" -p \"$POSTGRES_PORT\" -U \"$POSTGRES_USER\" >/dev/null 2>&1; do sleep 1; done"
}

# We keep our validation query in a helper so we can assert that the row we inserted upstream made it through the
# backup -> restore cycle. Using -A -t gives us a clean line we can compare without extra headers from psql.
fetch_note() {
  $COMPOSE exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -At \
    -c "SELECT note FROM migration_notes ORDER BY id DESC LIMIT 1;"
}

# ---- phase 1: seed data on the source version ----
#
# We start from a clean stack, launch the services with the "from" Postgres image, and take a backup into our MinIO bucket.
# The goal is to capture a dump that represents the state we need to carry forward.
export POSTGRES_VERSION="$FROM_VERSION"
$COMPOSE down >/dev/null 2>&1 || true
$COMPOSE up -d --build --force-recreate
wait_for_postgres

# We prepare the schema and stash a recognizable message so we can verify it resurfaces later.
MIGRATION_NOTE="migrating from ${FROM_VERSION} to ${TO_VERSION}"
$COMPOSE exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" \
  -c "CREATE TABLE IF NOT EXISTS migration_notes(id serial PRIMARY KEY, note text);" \
  -c "TRUNCATE migration_notes;" \
  -c "INSERT INTO migration_notes(note) VALUES ('$MIGRATION_NOTE');"

# We create the bucket if needed and clear out any leftover objects under our dedicated prefix so each run starts fresh.
$COMPOSE exec -T backup sh -lc \
  ". ./env.sh && (aws \$aws_args s3api head-bucket --bucket \"$S3_BUCKET\" >/dev/null 2>&1 || aws \$aws_args s3api create-bucket --bucket \"$S3_BUCKET\")"
$COMPOSE exec -T backup sh -lc \
  ". ./env.sh && aws \$aws_args s3 rm \"s3://$S3_BUCKET/$S3_PREFIX\" --recursive >/dev/null 2>&1 || true"

# We capture the backup on the source version.
$COMPOSE exec -T backup sh backup.sh

# ---- phase 2: restore on the target version ----
#
# We restart the stack with the target Postgres version so the restore runs against a fresh server. MinIO keeps the dump
# because we avoided removing its named volume during the down/up dance.
$COMPOSE down >/dev/null 2>&1 || true
export POSTGRES_VERSION="$TO_VERSION"
$COMPOSE up -d --build --force-recreate
wait_for_postgres

# We pull the most recent backup back in and validate that the note survived the journey.
$COMPOSE exec -T backup sh restore.sh
RESTORED_NOTE="$(fetch_note)"
if [ "$RESTORED_NOTE" != "$MIGRATION_NOTE" ]; then
  echo "ERROR: expected restored note '$MIGRATION_NOTE' but found '$RESTORED_NOTE'." >&2
  exit 1
fi

# We record the server version too so folks can see which target they just validated against.
TARGET_SERVER="$($COMPOSE exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DATABASE" -At -c 'SHOW server_version;')"

echo "Migration smoke succeeded — backup from Postgres $FROM_VERSION restored into Postgres $TARGET_SERVER."

# Unless callers asked us to keep the stack running (KEEP_STACK=1), we clean up containers but keep the MinIO volume so
# future test runs can reuse the bucket without downloading everything again.
if [ "${KEEP_STACK:-0}" != "1" ]; then
  $COMPOSE down >/dev/null 2>&1 || true
fi
