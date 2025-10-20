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

timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
s3_uri_base="s3://${S3_BUCKET}/${S3_PREFIX}/${POSTGRES_DATABASE}_${timestamp}.dump"

if [ -n "$PASSPHRASE" ]; then
  echo "Encrypting backup..."
  rm -f db.dump.gpg
  gpg --symmetric --batch --passphrase "$PASSPHRASE" db.dump
  rm db.dump
  local_file="db.dump.gpg"
  s3_uri="${s3_uri_base}.gpg"
else
  local_file="db.dump"
  s3_uri="$s3_uri_base"
fi

echo "Uploading backup to $S3_BUCKET..."
aws $aws_args s3 cp "$local_file" "$s3_uri"
rm "$local_file"

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
