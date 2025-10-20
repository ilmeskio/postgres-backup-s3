#!/bin/sh
#
# retention-smoke.sh — We run the freshly built image against disposable Postgres + MinIO containers so we can
# witness the backup job prune with the new seven-day default while still letting teammates disable pruning on demand.
# This gives our CI pipeline concrete proof that the default retention path stays alive.
#
# Usage: scripts/retention-smoke.sh
#
set -u
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi
set -e

# We honour existing .env overrides so the smoke test mirrors whatever knobs teammates already use locally.
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi

# We confirm Docker and the compose plugin exist up front so folks get clear guidance instead of opaque failures later.
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found; please install Docker Desktop or the CLI." >&2
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  echo "ERROR: docker compose plugin not found; upgrade Docker so compose v2 is available." >&2
  exit 1
fi

# We rebuild the backup image so this script always exercises the latest sources before checking retention behaviour.
docker compose build backup >/dev/null
image="postgres-backup-s3-backup:latest"

# We dedicate a network to the smoke pairings so the helper containers can discover each other without polluting default networks.
network="retention-smoke-$$"
docker network create "$network" >/dev/null

# We pick friendly identifiers so cleanup stays straightforward even if a step fails midway.
postgres_container="retention-postgres-$$"
minio_container="retention-minio-$$"
bucket="${RETENTION_SMOKE_BUCKET:-retention-smoke}"
prefix="${RETENTION_SMOKE_PREFIX:-retention-smoke}"
region="${S3_REGION:-us-east-1}"
minio_access="${MINIO_ROOT_USER:-minioadmin}"
minio_secret="${MINIO_ROOT_PASSWORD:-minioadmin}"

aws_cli() {
  docker run --rm \
    --network "$network" \
    -e AWS_ACCESS_KEY_ID="$minio_access" \
    -e AWS_SECRET_ACCESS_KEY="$minio_secret" \
    -e AWS_DEFAULT_REGION="$region" \
    amazon/aws-cli \
    --endpoint-url "http://${minio_container}:9000" \
    "$@"
}

cleanup() {
  docker rm -f "$postgres_container" >/dev/null 2>&1 || true
  docker rm -f "$minio_container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# We start Postgres so pg_dump has a live target. Credentials match our defaults for quick local runs.
docker run -d --rm \
  --name "$postgres_container" \
  --network "$network" \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=postgres \
  "postgres:${POSTGRES_VERSION:-16}" >/dev/null

# We launch MinIO to stand in for S3. Matching credentials make it trivial for the backup container to connect.
docker run -d --rm \
  --name "$minio_container" \
  --network "$network" \
  -e MINIO_ROOT_USER="$minio_access" \
  -e MINIO_ROOT_PASSWORD="$minio_secret" \
  minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1 \
  server /data >/dev/null

# We give both services a short window to finish booting so follow-up calls do not race their readiness.
sleep 6

# We wait for Postgres explicitly so pg_dump does not face connection refusals.
attempt=1
max_attempts=20
while [ "$attempt" -le "$max_attempts" ]; do
  if docker exec "$postgres_container" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 1
done
if [ "$attempt" -gt "$max_attempts" ]; then
  docker logs "$postgres_container" >&2 || true
  echo "ERROR: Postgres never became ready for the retention smoke test." >&2
  exit 1
fi

# We create the bucket so the backup run can upload immediately instead of tripping on a missing target.
aws_cli s3api create-bucket --bucket "$bucket" >/dev/null 2>&1 || true
aws_cli s3api head-bucket --bucket "$bucket" >/dev/null
aws_cli s3 rm "s3://$bucket/$prefix/" --recursive >/dev/null 2>&1 || true

run_backup() {
  retention_env="$1"
  docker run --rm \
    --network "$network" \
    -e SCHEDULE='' \
    -e S3_BUCKET="$bucket" \
    -e S3_PREFIX="$prefix" \
    -e S3_REGION="$region" \
    -e S3_ENDPOINT="http://${minio_container}:9000" \
    -e S3_ACCESS_KEY_ID="$minio_access" \
    -e S3_SECRET_ACCESS_KEY="$minio_secret" \
    -e S3_S3V4='yes' \
    -e POSTGRES_HOST="$postgres_container" \
    -e POSTGRES_DATABASE='postgres' \
    -e POSTGRES_USER='postgres' \
    -e POSTGRES_PASSWORD='postgres' \
    $retention_env \
    "$image" \
    sh -lc 'sh backup.sh'
}

list_backup_keys() {
  keys=$(aws_cli s3api list-objects --bucket "$bucket" --prefix "$prefix" --query 'Contents[].Key' --output text 2>/dev/null || true)
  if [ "$keys" = "None" ] || [ "$keys" = "null" ]; then
    keys=""
  fi
  printf "%s\n" "$keys" | tr '\t' '\n' | sed '/^$/d'
}

# We count objects by expanding the list to one key per line and piping through wc.
backup_key_count() {
  keys="$(list_backup_keys)"
  if [ -z "$keys" ]; then
    echo "0"
  else
    printf "%s\n" "$keys" | wc -l | tr -d ' '
  fi
}

# We enforce BACKUP_KEEP_DAYS=0 so every new dump should evict the previous one, letting us prove pruning by inspecting objects.
zero_keep_env='-e BACKUP_KEEP_DAYS=0'
run_backup "$zero_keep_env" >/dev/null
first_keys="$(list_backup_keys)"
if [ -z "$first_keys" ]; then
  echo "ERROR: First backup did not leave any objects in the bucket." >&2
  exit 1
fi
first_key=$(printf '%s\n' "$first_keys" | head -n1)
if [ "$(backup_key_count)" -ne 1 ]; then
  echo "ERROR: Expected exactly one object after the first zero-day run." >&2
  printf 'Keys:\n%s\n' "$first_keys" >&2
  exit 1
fi

# We give timestamps a moment to advance so MinIO stores the next dump under a distinct object key.
sleep 2
run_backup "$zero_keep_env" >/dev/null
second_keys="$(list_backup_keys)"
if [ -z "$second_keys" ]; then
  echo "ERROR: Second backup removed all objects; expected the latest dump to remain." >&2
  exit 1
fi

if printf '%s\n' "$second_keys" | grep -qx "$first_key"; then
  echo "ERROR: Expected the second backup to replace the first, but '${first_key}' still exists." >&2
  printf 'Current keys after second run:\n%s\n' "$second_keys" >&2
  exit 1
fi
second_key=$(printf '%s\n' "$second_keys" | head -n1)

# Opting out of pruning should let the previous dump stick around alongside the fresh one.
sleep 2
run_backup "-e BACKUP_KEEP_DAYS=" >/dev/null
opt_out_keys="$(list_backup_keys)"
opt_out_count="$(backup_key_count)"
if [ "$opt_out_count" -lt 2 ]; then
  echo "ERROR: Opt-out run should retain earlier backups, but only ${opt_out_count} object(s) remain." >&2
  printf 'Keys:\n%s\n' "$opt_out_keys" >&2
  exit 1
fi
if ! printf '%s\n' "$opt_out_keys" | grep -qx "$second_key"; then
  echo "ERROR: Opt-out run lost the previously retained backup (${second_key})." >&2
  printf 'Keys:\n%s\n' "$opt_out_keys" >&2
  exit 1
fi

# Another zero-day run should prune everything but the newest dump, proving the opt-out toggle is reversible.
sleep 2
run_backup "$zero_keep_env" >/dev/null
final_keys="$(list_backup_keys)"
final_count="$(backup_key_count)"
if [ "$final_count" -ne 1 ]; then
  echo "ERROR: Final zero-day run should collapse to one backup, but ${final_count} objects remain." >&2
  printf 'Keys:\n%s\n' "$final_keys" >&2
  exit 1
fi
if printf '%s\n' "$final_keys" | grep -qx "$second_key"; then
  echo "ERROR: Final zero-day run failed to remove the previously retained backup (${second_key})." >&2
  printf 'Keys:\n%s\n' "$final_keys" >&2
  exit 1
fi

printf '%s\n' "[retention-smoke] Verified BACKUP_KEEP_DAYS toggles between pruning and opt-out behaviour."
