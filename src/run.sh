#! /bin/sh

set -eu

if [ "$S3_S3V4" = "yes" ]; then
  aws configure set default.s3.signature_version s3v4
fi

if [ -z "$SCHEDULE" ]; then
  sh backup.sh
else
  cronfile="$(mktemp)"
  {
    echo "SHELL=/bin/sh"
    printf '%s /bin/sh /backup.sh\n' "$SCHEDULE"
  } >"$cronfile"
  exec supercronic "$cronfile"
fi
