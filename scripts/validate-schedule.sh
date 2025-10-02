#!/bin/sh
#
# validate-schedule.sh — We boot the backup container with an intentionally broken
# schedule so we can watch `run.sh` fail fast. Our goal is to confirm that
# supercronic's `-test` gate still aborts the container with exit code 1 instead of
# letting a bad cron expression linger. We run the container in the background to
# mirror real startup and then inspect its state to verify that it terminated the way
# we expect.
#
# Usage: scripts/validate-schedule.sh
#
set -u
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found; install Docker Desktop or the CLI." >&2
  exit 1
fi

# We rebuild the image so this check always mirrors our local changes.
docker compose build backup >/dev/null

image="postgres-backup-s3-backup:latest"
invalid_schedule='@thisisnotvalid'
# We sprinkle the PID (`$$` expands to the current shell's process ID) into the container
# name so parallel runs pick unique IDs without manual bookkeeping.
invalid_container="schedule-invalid-$$"

cleanup() {
  docker rm -f "$invalid_container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[validate-schedule] Verifying invalid schedule ($invalid_schedule) causes exit code 1..."

if ! docker run -d \
  --name "$invalid_container" \
  -e SCHEDULE="$invalid_schedule" \
  "$image" >/dev/null 2>&1; then
  echo "ERROR: failed to start container for invalid schedule test." >&2
  exit 1
fi

# We give the container a moment to run its validation logic before we check the exit
# status. Because the failure path should be immediate, a quick single check keeps the
# script snappy while still catching regressions. If this ever proves too racy we can
# reintroduce a short polling loop.
sleep 1
state=$(docker inspect -f '{{.State.Status}}' "$invalid_container" 2>/dev/null || printf 'missing')

if [ "$state" != "exited" ]; then
  docker logs "$invalid_container" 2>&1 >&2 || true
  echo "ERROR: container did not exit; invalid schedule appears to be accepted." >&2
  exit 1
fi

exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$invalid_container" 2>/dev/null || printf 'unknown')

if [ "$exit_code" != "1" ]; then
  docker logs "$invalid_container" 2>&1 >&2 || true
  echo "ERROR: container exited with code $exit_code; expected exit code 1." >&2
  exit 1
fi

echo "[validate-schedule] Invalid schedule correctly rejected with exit code 1."

echo "[validate-schedule] OK"
