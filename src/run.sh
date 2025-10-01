#! /bin/sh

set -eu

if [ "$S3_S3V4" = "yes" ]; then
  aws configure set default.s3.signature_version s3v4
fi

if [ -z "$SCHEDULE" ]; then
  sh backup.sh
else
  cronfile="/tmp/supercronic.crontab"
  # We write the crontab atomically so health checks and restarts always see a valid file.
  tmp_cron="$(mktemp)"
  {
    echo "SHELL=/bin/sh"
    printf '%s /bin/sh /backup.sh\n' "$SCHEDULE"
  } >"$tmp_cron"
  mv "$tmp_cron" "$cronfile"
  prometheus_listen="${SUPERCRONIC_PROMETHEUS_LISTEN_ADDRESS:-127.0.0.1:9746}"

  # We build the supercronic command incrementally so every flag we optionally add is reused for validation and execution.
  set -- supercronic

  # Metrics are always available locally; the host can invert the address when it wants to expose them externally.
  set -- "$@" -prometheus-listen-address "$prometheus_listen"

  if [ "${SUPERCRONIC_SPLIT_LOGS:-}" = "yes" ]; then
    # We let logs split across stdout/stderr when folks want finer-grained log routing.
    set -- "$@" -split-logs
  fi

  if [ "${SUPERCRONIC_DEBUG:-}" = "yes" ]; then
    # Debug mode gives us richer logging whenever teammates troubleshoot schedules.
    set -- "$@" -debug
  fi

  # We dry-run the crontab with `-test` so invalid schedules fail fast with context.
  if ! "$@" -test "$cronfile"; then
    echo "ERROR: supercronic validation failed for SCHEDULE='$SCHEDULE'." >&2
    exit 1
  fi

  # We replace the shell with the final supercronic command so PID 1 is the scheduler.
  exec "$@" "$cronfile"
fi
