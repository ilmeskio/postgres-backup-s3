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

HOST=127.0.0.1
PORT=9746
if curl -fsS "http://$HOST:$PORT/health" >/dev/null; then
  exit 0
fi

echo "prometheus health endpoint unavailable" >&2
supercronic -test "$cronfile"
