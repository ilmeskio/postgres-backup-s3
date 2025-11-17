#!/bin/sh

# test-restore-verify.sh — We exercise restore.sh's fingerprint verification paths against a local
# Postgres + MinIO stack so auditors can trust the optional ISO 27001 evidence flow.
# The script seeds demo data, captures a backup, mutates the database, and checks both success and
# failure scenarios for full-database and table-scoped verification.

set -u
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi
set -e

echo "Bootstrapping docker compose stack for restore verification tests..."

# We lean on the same credentials the compose file advertises so teammates do not juggle test-only
# values. MinIO defaults mirror AWS-compatible semantics for these calls.
S3_BUCKET="${S3_BUCKET:-demo-backups}"
S3_PREFIX="${S3_PREFIX:-backup}"
POSTGRES_USER_COMPOSE="${POSTGRES_USER:-user}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
S3_REGION="${S3_REGION:-us-east-1}"
S3_ACCESS_KEY_ID="${S3_ACCESS_KEY_ID:-minioadmin}"
S3_SECRET_ACCESS_KEY="${S3_SECRET_ACCESS_KEY:-minioadmin}"
# AWS_* variables feed the CLI when we create buckets via docker exec.
AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
AWS_DEFAULT_REGION="$S3_REGION"
# Match the MinIO endpoint our compose file advertises so aws CLI talks to the right place.
aws_args="--endpoint-url ${S3_ENDPOINT:-http://minio:9000}"

docker compose down -v --remove-orphans >/dev/null 2>&1 || true
docker compose up -d --build postgres minio backup
# MinIO can take a moment to surface the API; this alias call is best-effort and will be skipped if the client is missing.
docker compose exec -T minio mc alias set local http://localhost:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1 || true

# Create the bucket once so the first backup upload succeeds; ignore "already owned" noise.
docker compose exec -T backup env AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" AWS_DEFAULT_REGION="$AWS_DEFAULT_REGION" aws $aws_args s3 mb "s3://${S3_BUCKET}" 2>/dev/null || true

psql_compose() {
  docker compose exec -T postgres psql -U "$POSTGRES_USER_COMPOSE" -d postgres -v ON_ERROR_STOP=1 -c "$1"
}

seed_data() {
  echo "Seeding demo data..."
  psql_compose "CREATE TABLE IF NOT EXISTS items(id serial PRIMARY KEY, name text);"
  psql_compose "TRUNCATE items; INSERT INTO items(name) VALUES ('alpha'),('beta');"
}

seed_data

echo "Creating baseline backup..."
docker compose exec -T backup sh backup.sh

run_restore() {
  # $1: description, $2: restore env vars, $3: expected exit code
  description="$1"
  restore_env="$2"
  expected="$3"

  echo "--- ${description} ---"
  set +e
  docker compose exec -T backup sh -c "env $restore_env sh restore.sh"
  status=$?
  set -e

  if [ "$status" -ne "$expected" ]; then
    echo "Test failed: ${description} (exit ${status}, expected ${expected})" >&2
    exit 1
  fi
}

# Happy path: full database verification resets drift and matches hashes.
psql_compose "DELETE FROM items WHERE name='beta';"
run_restore "happy path full database" "RESTORE_VERIFY=1" 0

# Happy path: table-scoped verification succeeds for a subset.
psql_compose "UPDATE items SET name='alpha-changed' WHERE name='alpha';"
run_restore "happy path table subset" "RESTORE_VERIFY=1 RESTORE_VERIFY_TABLES=public.items" 0

# Failure: full database verification catches divergence introduced after restore.
psql_compose "UPDATE items SET name='alpha' WHERE name='alpha-changed';"
run_restore "mismatched full database" "RESTORE_VERIFY=1 RESTORE_MUTATE_SQL=\"INSERT INTO items(name) VALUES ('iso-drift');\"" 1

# Failure: table-scoped verification catches divergence in targeted table.
run_restore "mismatched table subset" "RESTORE_VERIFY=1 RESTORE_VERIFY_TABLES=public.items RESTORE_MUTATE_SQL=\"UPDATE items SET name='mutated' WHERE name='beta';\"" 1

echo "All restore verification tests passed."
