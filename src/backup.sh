#! /bin/sh

# We keep strict mode on so backup failures never slip by unnoticed—`set -e` stops on the first
# error, `set -u` flags missing inputs from env.sh, and `set -o pipefail` propagates pipeline
# failures like an S3 upload hiccup.
set -euo pipefail

# We load env.sh so our validation and shared AWS configuration apply consistently in backups and restores.
. ./env.sh

# We treat optional inputs as empty strings when not provided so `set -u` does not abort.
PASSPHRASE="${PASSPHRASE:-}"

BACKUP_KEEP_DAYS="${BACKUP_KEEP_DAYS:-}"

echo "Creating backup of $POSTGRES_DATABASE database..."
pg_dump --format=custom \
        -h $POSTGRES_HOST \
        -p $POSTGRES_PORT \
        -U $POSTGRES_USER \
        -d $POSTGRES_DATABASE \
        $PGDUMP_EXTRA_OPTS \
        > db.dump

# We capture deterministic per-table fingerprints from the live database so restores can compare
# against the original content without relying on dump formatting. These fingerprints ride next to
# the dump in S3 and let us prove the restore matches what we backed up.
table_fingerprint_local="db.fingerprints"
echo "Computing table fingerprints from source database..."
table_list_cmd="SELECT quote_ident(schemaname)||'.'||quote_ident(tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1;"
tables_to_check=$(psql -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE -At -c "$table_list_cmd")

# We log a header so auditors know each line is `table md5-hash`. Every hash is deterministic because
# we sort rows by the md5 of their JSON representation before aggregating. Empty tables use the md5 of
# an empty string so they are still represented in the evidence file.
echo "# table md5(row_to_json sorted)" > "$table_fingerprint_local"
for table in $tables_to_check; do
  data_hash=$(psql -h $POSTGRES_HOST -p $POSTGRES_PORT -U $POSTGRES_USER -d $POSTGRES_DATABASE -At \
    -c "SELECT coalesce(md5(string_agg(md5(row_to_json(t)::text), '' ORDER BY md5(row_to_json(t)::text))), 'd41d8cd98f00b204e9800998ecf8427e') FROM $table t;")
  echo "$table $data_hash" >> "$table_fingerprint_local"
done

# We name all artifacts with the same timestamped stem so operators can correlate the dump, its md5,
# and the per-table fingerprints when debugging or auditing a restore.
timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"
archive_md5_file="db.dump.md5"                       # md5 of the dump (or encrypted dump) for transport integrity
archive_md5_s3_uri="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.md5"
table_fingerprint_s3="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.fingerprints"

if [ -n "$PASSPHRASE" ]; then
  echo "Encrypting backup..."
  rm -f db.dump.gpg
  gpg --symmetric --batch --passphrase "$PASSPHRASE" db.dump
  rm db.dump
  local_file="db.dump.gpg"
  s3_uri="${s3_uri_base}.gpg"
  # We hash the encrypted payload so restores can compare against exactly what we uploaded.
  md5sum "${local_file}" | awk '{print $1}' > "$archive_md5_file"
else
  local_file="db.dump"
  s3_uri="$s3_uri_base"
  md5sum "${local_file}" | awk '{print $1}' > "$archive_md5_file"
fi

echo "Uploading backup to $S3_BUCKET..."
# We ship three artifacts: the dump (optionally encrypted), a table fingerprint sidecar, and an
# md5 of the dump to catch transfer corruption.
aws $aws_args s3 cp "$local_file" "$s3_uri"
aws $aws_args s3 cp "$table_fingerprint_local" "$table_fingerprint_s3"
aws $aws_args s3 cp "$archive_md5_file" "$archive_md5_s3_uri"
rm "$local_file"
rm "$table_fingerprint_local"
rm "$archive_md5_file"

echo "Backup complete."

# When retention is enabled, we translate days into a cutoff timestamp, and we subtract one extra
# second when BACKUP_KEEP_DAYS=0 so the filter never deletes the backup we just uploaded.
if [ -n "$BACKUP_KEEP_DAYS" ]; then
  sec=$((86400*BACKUP_KEEP_DAYS))
  cutoff_epoch=$(date +%s)
  if [ "$sec" -eq 0 ]; then
    cutoff_epoch=$((cutoff_epoch - 1))
  else
    cutoff_epoch=$((cutoff_epoch - sec))
  fi
  echo "Removing old backups from $S3_BUCKET..."
  keys_output=$(
    aws $aws_args s3api list-objects \
      --bucket "${S3_BUCKET}" \
      --prefix "${S3_PREFIX}" \
      --query 'Contents[].[LastModified,Key]' \
      --output text
  )

  keys_to_remove=""
  if [ -n "$keys_output" ]; then
    while IFS=$(printf '\t') read -r _ key; do
      if [ -z "${key:-}" ]; then
        continue
      fi

      base_key=${key#${S3_PREFIX}/}
      base_key=${base_key%.gpg}
      base_key=${base_key%.dump}

      timestamp_part=${base_key#${POSTGRES_DATABASE}_}
      if [ "$timestamp_part" = "$base_key" ]; then
        continue
      fi

      timestamp_formatted=$(printf '%s\n' "$timestamp_part" | sed 's/T/ /')
      key_epoch=$(date -u -d "$timestamp_formatted" +%s 2>/dev/null || true)
      if [ -z "$key_epoch" ]; then
        continue
      fi

      if [ "$key_epoch" -lt "$cutoff_epoch" ]; then
        keys_to_remove="${keys_to_remove}${key}"$'\n'
      fi
    done <<EOF
$keys_output
EOF
  fi

  if [ -n "$keys_to_remove" ]; then
    printf '%s' "$keys_to_remove" | sed '/^$/d' | xargs -n1 -t -I 'KEY' aws $aws_args s3 rm s3://"${S3_BUCKET}"/'KEY'
  fi
  echo "Removal complete."
fi
