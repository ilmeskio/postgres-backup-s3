#! /bin/sh

# We restore a dump from S3 into our target database and, when requested, compute fingerprints so
# we can show auditors the database contents and schema were reachable right after the import.

# We run with strict mode so restores bail out as soon as something looks wrong—`-e` aborts on
# failing commands (including AWS downloads), `-u` catches missing variables from env.sh, and
# `-o pipefail` ensures pipeline errors (like `tail` not finding a key) bubble up for us to handle.
set -euo pipefail

# We source env.sh to reuse the same validation and AWS settings the backup flow relies on.
. ./env.sh

# Optional inputs might be unset when we're running without encryption or when the caller skips verification.
PASSPHRASE="${PASSPHRASE:-}"
RESTORE_VERIFY="${RESTORE_VERIFY:-}"
RESTORE_VERIFY_TABLES="${RESTORE_VERIFY_TABLES:-}"

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

if [ -n "$RESTORE_VERIFY" ]; then
  # We compute deterministic hashes so we can prove the restored database matches the dump we pulled
  # from S3. When RESTORE_VERIFY_TABLES is empty we fingerprint the whole database (schema + data).
  # Otherwise we hash only the listed tables, keeping the workload predictable for large clusters.
  echo "Running post-restore fingerprint verification..."

  if [ -z "$RESTORE_VERIFY_TABLES" ]; then
    echo "Fingerprinting full database schema..."
    schema_dump_hash=$(pg_restore --schema-only --no-owner --no-privileges db.dump | md5sum | cut -d' ' -f1)
    schema_live_hash=$(pg_dump $conn_opts --schema-only --no-owner --no-privileges | md5sum | cut -d' ' -f1)
    echo "Schema fingerprint (dump/live): $schema_dump_hash / $schema_live_hash"

    echo "Fingerprinting full database data section..."
    data_dump_hash=$(pg_restore --data-only --inserts --no-owner --no-privileges db.dump | md5sum | cut -d' ' -f1)
    data_live_hash=$(pg_dump $conn_opts --data-only --inserts --no-owner --no-privileges | md5sum | cut -d' ' -f1)
    echo "Data fingerprint (dump/live):   $data_dump_hash / $data_live_hash"

    if [ "$schema_dump_hash" != "$schema_live_hash" ]; then
      echo "ERROR: Schema fingerprint mismatch (dump $schema_dump_hash vs live $schema_live_hash)." >&2
      rm -f db.dump
      exit 1
    fi

    if [ "$data_dump_hash" != "$data_live_hash" ]; then
      echo "ERROR: Data fingerprint mismatch (dump $data_dump_hash vs live $data_live_hash)." >&2
      rm -f db.dump
      exit 1
    fi
    echo "Schema fingerprint match confirmed."
    echo "Data fingerprint match confirmed."
  else
    echo "Fingerprinting tables: $RESTORE_VERIFY_TABLES"
    combined_table_hash_input=""
    # We iterate in the order provided so the combined hash stays stable across runs.
    for table in $(printf '%s\n' "$RESTORE_VERIFY_TABLES" | tr ',' ' '); do
      table_dump_hash=$(pg_restore --data-only --inserts --no-owner --no-privileges --table="$table" db.dump | md5sum | cut -d' ' -f1)
      table_live_hash=$(pg_dump $conn_opts --data-only --inserts --no-owner --no-privileges --table="$table" | md5sum | cut -d' ' -f1)

      echo "Fingerprint for $table (dump/live): $table_dump_hash / $table_live_hash"

      if [ "$table_dump_hash" != "$table_live_hash" ]; then
        echo "ERROR: Fingerprint mismatch for $table (dump $table_dump_hash vs live $table_live_hash)." >&2
        rm -f db.dump
        exit 1
      fi
      combined_table_hash_input="${combined_table_hash_input}${table}:${table_live_hash}\n"
    done

    combined_table_hash=$(printf '%s' "$combined_table_hash_input" | md5sum | cut -d' ' -f1)
    echo "Combined tables fingerprint: $combined_table_hash"
  fi
fi

rm db.dump

echo "Restore complete."
