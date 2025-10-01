#!/bin/sh
#
# validate-schedule.sh — Smoke-test schedule parsing by running the backup container
# with a known-good cron string and an intentionally bad one. We rely on the image's
# own `run.sh` to run `supercronic -test` before scheduling, so a bad schedule aborts
# the container immediately.
#
# Usage: scripts/validate-schedule.sh
#
set -eu
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found; install Docker Desktop or the CLI." >&2
  exit 1
fi

# Rebuild the image so the test reflects the current checkout.
docker compose build backup >/dev/null

image="postgres-backup-s3-backup:latest"

# ---- happy path ----
echo "[validate-schedule] Checking valid schedule (@daily)..."
valid_container="schedule-valid-$$"
trap 'docker rm -f "$valid_container" >/dev/null 2>&1 || true' EXIT

if ! docker run --rm -d \
  --name "$valid_container" \
  -e SCHEDULE='@daily' \
  "$image" >/dev/null; then
  echo "ERROR: failed to start container for valid schedule." >&2
  exit 1
fi

# Wait until supercronic confirms the crontab, giving it a few seconds.
validated=false
for i in 1 2 3 4 5; do
  if docker logs "$valid_container" --tail 20 2>&1 | grep -q 'crontab is valid'; then
    echo "[validate-schedule] Valid schedule accepted."
    validated=true
    break
  fi
  sleep 1
  if ! docker ps --format '{{.Names}}' | grep -q "^$valid_container$"; then
    docker logs "$valid_container" 2>&1 >&2 || true
    echo "ERROR: container exited unexpectedly while validating a good schedule." >&2
    exit 1
  fi
done

if [ "$validated" = false ]; then
  docker logs "$valid_container" 2>&1 >&2 || true
  echo "ERROR: timed out waiting for supercronic to validate schedule." >&2
  exit 1
fi

docker rm -f "$valid_container" >/dev/null 2>&1 || true
trap - EXIT

# ---- failure path ----
echo "[validate-schedule] Checking invalid schedule..."
if docker run --rm \
  -e SCHEDULE='@thisisnotvalid' \
  "$image" >/dev/null 2>&1; then
  echo "ERROR: invalid schedule unexpectedly succeeded." >&2
  exit 1
fi

echo "[validate-schedule] Invalid schedule correctly rejected."

echo "[validate-schedule] OK"
