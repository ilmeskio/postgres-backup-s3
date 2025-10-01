#!/bin/sh
set -eu
if (set -o pipefail) 2>/dev/null; then
  set -o pipefail
fi

cronfile="/tmp/supercronic.crontab"
if [ ! -f "$cronfile" ]; then
  echo "cron file not found" >&2
  exit 1
fi

listen="${SUPERCRONIC_PROMETHEUS_LISTEN_ADDRESS:-0.0.0.0:9746}"
host="${listen%%:*}"
port="${listen##*:}"
if [ -z "$host" ] || [ "$host" = "0.0.0.0" ]; then
  host=127.0.0.1
fi
if curl -fsS "http://$host:$port/health" >/dev/null; then
  exit 0
fi

echo "prometheus health endpoint unavailable" >&2
supercronic -test "$cronfile"
