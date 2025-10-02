#!/bin/sh
#
# metrics-smoke.sh — We launch the freshly built backup image with supercronic enabled,
# then we probe the Prometheus endpoint to prove that metrics stay reachable from the host.
# Running this script locally (or in CI) keeps us confident that users can scrape
# `/metrics` as soon as they publish port 9746.
#
# Usage: scripts/metrics-smoke.sh
#
set -u
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi
set -e

# We make sure Docker exists up front so teammates see a clear action item instead of
# an obscure error when the script tries to start containers.
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker command not found; install Docker Desktop or the CLI." >&2
  exit 1
fi

# We rebuild the backup service so the metrics probe always tests the latest sources,
# mirroring the steps that our CI workflow takes before running the same check.
docker compose build backup >/dev/null

image="postgres-backup-s3-backup:latest"
metrics_container="metrics-smoke-$$"
metrics_port="19746"
metrics_url="http://127.0.0.1:${metrics_port}/metrics"

cleanup() {
  docker rm -f "$metrics_container" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# We run the container with a long cadence so supercronic stays idle, letting us
# confirm the metrics endpoint without scheduling a real backup job. The placeholder
# environment variables satisfy env.sh whenever someone later flips the schedule to a
# short interval while reusing this script for deeper tests.
if ! docker run -d \
  --name "$metrics_container" \
  -p "${metrics_port}:9746" \
  -e SCHEDULE='@weekly' \
  -e S3_BUCKET='metrics-smoke' \
  -e S3_REGION='us-east-1' \
  -e POSTGRES_DATABASE='postgres' \
  -e POSTGRES_HOST='localhost' \
  -e POSTGRES_USER='postgres' \
  -e POSTGRES_PASSWORD='postgres' \
  "$image" >/dev/null; then
  echo "ERROR: failed to start container for metrics probe." >&2
  exit 1
fi

# We give supercronic a short window to boot, then poll the metrics endpoint until it
# responds. A ten second budget keeps the script quick while tolerating cold starts on
# slower CI runners.
attempt=1
max_attempts=10
tmp_metrics="$(mktemp)"
while [ "$attempt" -le "$max_attempts" ]; do
  if curl -fsSL "$metrics_url" >"$tmp_metrics" 2>/dev/null; then
    if grep -q 'promhttp_metric_handler_requests_total' "$tmp_metrics"; then
      echo "[metrics-smoke] Metrics endpoint responded with Prometheus counters."
      rm -f "$tmp_metrics"
      exit 0
    fi
  fi
  attempt=$((attempt + 1))
  sleep 1
done

# We only reach this point when the endpoint never came online. Capture logs and fail
# so teammates can inspect what went wrong.
docker logs "$metrics_container" >&2 || true
echo "ERROR: metrics endpoint did not expose Prometheus data within ${max_attempts} seconds." >&2
exit 1
