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
docker compose down -v --remove-orphans >/dev/null 2>&1 || true
docker compose up -d --build postgres minio backup

# We lean on the same credentials the compose file advertises so teammates do not juggle test-only
# values. MinIO defaults mirror AWS-compatible semantics for these calls.
S3_BUCKET="${S3_BUCKET:-demo-backups}"
S3_PREFIX="${S3_PREFIX:-backup}"
POSTGRES_USER_COMPOSE="${POSTGRES_USER:-user}"

echo "Ensuring MinIO bucket exists..."
docker compose exec -T backup aws $aws_args s3 mb "s3://${S3_BUCKET}" 2>/dev/null || true

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
  docker compose exec -T backup env $restore_env sh restore.sh
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
