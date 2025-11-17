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
# We allow an optional mutation step (primarily for tests) between restore and verification so we can
# prove the fingerprint guard catches divergence when data changes after the import.
RESTORE_MUTATE_SQL="${RESTORE_MUTATE_SQL:-}"

s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}"

if [ -z "$PASSPHRASE" ]; then
  file_type=".dump"
else
  file_type=".dump.gpg"
fi

if [ $# -eq 1 ]; then
  timestamp="$1"
  key_suffix="${POSTGRES_DATABASE}_${timestamp}${file_type}"
  md5_key_suffix="${POSTGRES_DATABASE}_${timestamp}.md5${file_type:+""}"
else
  echo "Finding latest backup..."
  # We ask S3 for all matching backups, sort them, and grab the most recent key. `tail -n 1` exits with
  # status 1 when the list is empty, so we append `|| true` to avoid tripping strict mode and then make
  # the emptiness decision ourselves.
  latest_line=$( \
    aws $aws_args s3 ls "${s3_uri_base}/${POSTGRES_DATABASE}" \
      | awk '{print $4}' \
      | grep -E '\.dump(\.gpg)?$' \
      | sort \
      | tail -n 1 \
  ) || true

  key_suffix="$latest_line"

  timestamp=$(printf '%s' "$key_suffix" | sed "s/^${POSTGRES_DATABASE}_//" | sed 's/\.dump$//' | sed 's/\.dump\.gpg$//' )

  if [ -z "$key_suffix" ]; then
    echo "ERROR: No backups found for ${POSTGRES_DATABASE}." >&2
    exit 1
  fi

  md5_candidate=$(printf '%s' "$key_suffix" | sed 's/\.gpg$//' | sed 's/\.dump$/.md5/')
  md5_key_suffix="$md5_candidate"
fi

echo "Fetching backup from S3..."
aws $aws_args s3 cp "${s3_uri_base}/${key_suffix}" "db${file_type}"
aws $aws_args s3 cp "${s3_uri_base}/${md5_key_suffix}" db.dump.md5 || true

if [ -n "$PASSPHRASE" ]; then
  echo "Decrypting backup..."
  gpg --decrypt --batch --passphrase "$PASSPHRASE" db.dump.gpg > db.dump
  rm db.dump.gpg
fi

conn_opts="-h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE"

echo "Restoring from backup..."
pg_restore $conn_opts --clean --if-exists db.dump

if [ -n "$RESTORE_MUTATE_SQL" ]; then
  echo "Applying post-restore mutation (testing hook)..."
  psql $conn_opts -v ON_ERROR_STOP=1 -c "$RESTORE_MUTATE_SQL"
fi

if [ -n "$RESTORE_VERIFY" ]; then
  # We compute deterministic hashes directly from table contents to avoid dump-format drift. When
  # RESTORE_VERIFY_TABLES is empty we hash every user table; otherwise we hash only the requested
  # comma-separated list. This keeps evidence stable and makes mismatches obvious.
  echo "Running post-restore fingerprint verification..."

  if [ -f db.dump.md5 ]; then
    stored_md5=$(cat db.dump.md5 | tr -d ' \n')
    local_md5=$(md5sum db.dump | awk '{print $1}')
    echo "Archive fingerprint (stored/live): ${stored_md5:-missing} / ${local_md5:-missing}"
    if [ -n "$stored_md5" ] && [ "$stored_md5" != "$local_md5" ]; then
      echo "ERROR: Archive fingerprint mismatch (dump hash differs from stored md5)." >&2
      rm -f db.dump db.dump.md5
      exit 1
    fi
  else
    echo "WARNING: No stored md5 found alongside dump; skipping archive integrity comparison."
  fi

  table_list_cmd="SELECT quote_ident(schemaname)||'.'||quote_ident(tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;"
  tables_to_check="$RESTORE_VERIFY_TABLES"
  if [ -z "$tables_to_check" ]; then
    tables_to_check=$(psql $conn_opts -At -c "$table_list_cmd")
  fi

  stored_fingerprints=""
  if aws $aws_args s3 cp "${s3_uri_base}/${POSTGRES_DATABASE}_${timestamp}.fingerprints" db.fingerprints 2>/dev/null; then
    stored_fingerprints=$(cat db.fingerprints)
  else
    echo "WARNING: No stored table fingerprints found; continuing with live-only logging." >&2
  fi

  combined_table_hash_input=""
  for table in $(printf '%s\n' "$tables_to_check" | tr ',' '\n'); do
    if [ -z "$table" ]; then
      continue
    fi

    data_hash_live=$(psql $conn_opts -At -c "SELECT coalesce(md5(string_agg(md5(row_to_json(t)::text), '' ORDER BY md5(row_to_json(t)::text))), 'd41d8cd98f00b204e9800998ecf8427e') FROM $table t;" 2>/dev/null || true)

    data_hash_dump=""
    if printf '%s\n' "$stored_fingerprints" | grep -q "^$table "; then
      data_hash_dump=$(printf '%s\n' "$stored_fingerprints" | awk -v t="$table" '$1==t {print $2}')
    fi

    if [ -z "$data_hash_live" ]; then
      echo "ERROR: Could not compute live fingerprint for $table (perhaps it does not exist)." >&2
      rm -f db.dump
      [ -f db.fingerprints ] && rm -f db.fingerprints
      exit 1
    fi

    if [ -n "$data_hash_dump" ]; then
      echo "Fingerprint for $table (stored/live): $data_hash_dump / $data_hash_live"
      if [ "$data_hash_dump" != "$data_hash_live" ]; then
        echo "ERROR: Fingerprint mismatch for $table (stored $data_hash_dump vs live $data_hash_live)." >&2
        rm -f db.dump
        [ -f db.fingerprints ] && rm -f db.fingerprints
        exit 1
      fi
    else
      echo "Fingerprint for $table (live only): $data_hash_live"
    fi

    combined_table_hash_input="${combined_table_hash_input}${table}:${data_hash_live}\n"
  done

  combined_table_hash=$(printf '%s' "$combined_table_hash_input" | md5sum | cut -d' ' -f1)
  echo "Combined tables fingerprint: $combined_table_hash"
fi

rm db.dump
[ -f db.fingerprints ] && rm -f db.fingerprints
[ -f db.dump.md5 ] && rm -f db.dump.md5

echo "Restore complete."
