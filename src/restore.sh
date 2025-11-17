#! /bin/sh

# We restore a dump from S3 into our target database and, when requested, run a post-restore
# verification query so we can show auditors the database responds after the import.

# We run with strict mode so restores bail out as soon as something looks wrong—`-e` aborts on
# failing commands (including AWS downloads), `-u` catches missing variables from env.sh, and
# `-o pipefail` ensures pipeline errors (like `tail` not finding a key) bubble up for us to handle.
set -euo pipefail

# We source env.sh to reuse the same validation and AWS settings the backup flow relies on.
. ./env.sh

# Optional inputs might be unset when we're running without encryption or when the caller skips verification.
PASSPHRASE="${PASSPHRASE:-}"
RESTORE_VERIFY="${RESTORE_VERIFY:-}"
RESTORE_VERIFY_QUERY="${RESTORE_VERIFY_QUERY:-SELECT 1;}"

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

if [ -z "$PASSPHRASE" ]; then
  file_type=".dump"
else
  file_type=".dump.gpg"
fi

if [ $# -eq 1 ]; then
  timestamp="$1"
  key_suffix="${POSTGRES_DATABASE}_${timestamp}${file_type}"
else
  echo "Finding latest backup..."
  # We ask S3 for all matching backups, sort them, and grab the most recent key. `tail -n 1` exits with
  # status 1 when the list is empty, so we append `|| true` to avoid tripping strict mode and then make
  # the emptiness decision ourselves.
  key_suffix=$( \
    aws $aws_args s3 ls "${s3_uri_base}/${POSTGRES_DATABASE}" \
      | sort \
      | tail -n 1 \
      | awk '{ print $4 }' \
  ) || true

  if [ -z "$key_suffix" ]; then
    echo "ERROR: No backups found for ${POSTGRES_DATABASE}." >&2
    exit 1
  fi
fi

echo "Fetching backup from S3..."
aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "db${file_type}"

if [ -n "$PASSPHRASE" ]; then
  echo "Decrypting backup..."
  gpg --decrypt --batch --passphrase "$PASSPHRASE" db.dump.gpg > db.dump
  rm db.dump.gpg
fi

conn_opts="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE"

echo "Restoring from backup..."
pg_restore $conn_opts --clean --if-exists db.dump
rm db.dump

if [ -n "$RESTORE_VERIFY" ]; then
  # We run a lightweight query so auditors can see evidence the restore produced a responsive database.
  # The default `SELECT 1;` keeps the check generic, and teams can override RESTORE_VERIFY_QUERY to point at
  # a domain-specific table when they want deeper assurance.
  echo "Running post-restore verification query..."
  if verification_output=$(psql $conn_opts -At -c "$RESTORE_VERIFY_QUERY"); then
    echo "Verification succeeded: $verification_output"
  else
    echo "ERROR: Verification query failed to run after restore." >&2
    exit 1
  fi
fi

echo "Restore complete."
