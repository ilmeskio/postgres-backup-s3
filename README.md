# Introduction
This project provides Docker images to periodically back up a PostgreSQL database to AWS S3, and to restore from the backup as needed.

Like everything else I do, the purpose is to contribue to mine and others educational path.

# Usage
## Backup
```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password

  pg_backup_s3:
    image: ilmeskio/postgres-backup-s3:16
    environment:
      # Core Postgres connection details
      POSTGRES_HOST: postgres
      POSTGRES_DATABASE: postgres
      POSTGRES_USER: user
      POSTGRES_PASSWORD: password

      # Target object storage (works with AWS S3, MinIO, DigitalOcean Spaces, Ceph, etc.)
      S3_BUCKET: my-bucket
      S3_PREFIX: backup
      S3_REGION: us-east-1
      S3_ACCESS_KEY_ID: key
      S3_SECRET_ACCESS_KEY: secret

      # Optional behaviours
      S3_ENDPOINT: https://s3.amazonaws.com   # point to MinIO / other S3-compatible URLs as needed
      S3_S3V4: yes                            # set to "yes" when the endpoint requires signature v4
      SCHEDULE: '@weekly'                     # cron cadence for supercronic
      BACKUP_KEEP_DAYS: 7                     # prune backups older than N days; leave empty to disable
      PASSPHRASE: ''                          # provide to encrypt dumps with GPG
```
- Images are tagged by the major PostgreSQL version they bundle, e.g., `ilmeskio/postgres-backup-s3:16`.
- All S3-compatible stores work as long as the credentials allow `s3:PutObject` and `s3:ListBucket` calls (AWS S3, MinIO,
  DigitalOcean Spaces, Wasabi, Ceph RGW, Backblaze B2, etc.). Use `S3_ENDPOINT` to point at non-AWS providers.
- `SCHEDULE` accepts supercronic syntax (standard cron entries plus handy shortcuts). Set it to empty if you only trigger
  backups manually.
- `BACKUP_KEEP_DAYS` prunes objects older than N days; leave it blank to retain everything.
- `PASSPHRASE` enables GPG encryption. When omitted, dumps stay unencrypted for quicker restores.
- Run `docker exec <container name> sh backup.sh` to trigger an immediate backup, regardless of the schedule.

## Restore
> **WARNING:** DATA LOSS! All database objects will be dropped and re-created.
### ... from latest backup
```sh
docker exec <container name> sh restore.sh
```
> **NOTE:** If your bucket has more than a 1000 files, the latest may not be restored -- only one S3 `ls` command is used
### ... from specific backup
```sh
docker exec <container name> sh restore.sh <timestamp>
```

# Acknowledgements
This projet follows the path and great work of [schickling/dockerfiles](https://github.com/schickling/dockerfiles)
 and [eeshugerman/docker-postgres-backup-s3](https://github.com/eeshugerman/postgres-backup-s3) that unfortunately decided to archive the project.

Also thanks to [siemens/postgres-backup-s3](https://github.com/siemens/postgres-backup-s3/tree/master) that mantained a fork.


## Contributing
See [Repository Guidelines](AGENTS.md) for contributor and workflow expectations.

### Local verification

Run `scripts/build-image.sh` to confirm the Docker image still builds before sharing a branch. The helper loads `.env`
when present, picks architecture-aware defaults (`ALPINE_VERSION=3.20`, `POSTGRES_VERSION=16`, and the matching
supercronic checksum), and runs `docker compose build backup` so the result mirrors our smoke test build. Override any
of the knobs through environment variables when you want to experiment:

```sh
$ ALPINE_VERSION=3.19 POSTGRES_VERSION=15 scripts/build-image.sh
```

To run the check automatically on every push, point Git hooks to the provided scripts:

```sh
$ git config core.hooksPath githooks
```

The `githooks/pre-push` script delegates to `scripts/build-image.sh`, so local pushes will fail fast whenever the image
breaks. A scheduled GitHub Actions workflow (`Monitor Postgres 18 Client`) also polls the Alpine package index; when
`postgresql18-client` finally ships, it opens a tracking issue so we remember to expand CI back to Postgres 18.

### End-to-end smoke test (no real S3 required)

Run `scripts/full-stack-smoke.sh` to spin up Postgres, a MinIO S3-compatible target, and the backup job via `docker compose`.
The script seeds a demo bucket (`demo-backups`), performs a backup, and immediately restores it to verify the entire
flow. MinIO exposes a local console at http://localhost:9001 if you want to inspect objects, and all traffic stays on
your machine.

Copy `.env.development` to `.env` before running the compose stack so the build and runtime variables have sensible
defaults. Tweak the values (especially `SUPERCRONIC_SHA1SUM` for your architecture or `MINIO_IMAGE` when pinning a new
release) whenever you want to test a different combination. The file only contains public demo credentials—swap them
before pointing at a real S3.

### Major-version migration rehearsal

Run `scripts/migration-smoke.sh` when we want to prove that a dump captured on one major Postgres release restores cleanly
into a newer release. The helper backs up sample data on `FROM_VERSION` (default `15`), restarts the stack with
`TO_VERSION` (default `16`), and restores the dump while MinIO keeps the archive available. Override the versions on the
command line:

```sh
$ FROM_VERSION=14 TO_VERSION=16 scripts/migration-smoke.sh
```

The script scopes its work to an S3 prefix named `migration-smoke`, so our habitual `full-stack-smoke.sh` runs keep their own
objects untouched. Set `MIGRATION_PREFIX` when you want a different namespace, or flip `KEEP_STACK=1` to leave the stack
running for follow-up exploration.

### How the Dockerfile and compose stack fit together

The Dockerfile mirrors the production image we publish: we declare build arguments for the Alpine base, the Postgres
client version, and the supercronic checksum so `install.sh` can fetch the exact binaries we need. When we run the
compose stack, those args flow in from environment variables, giving us room to test multiple combinations without
editing the Dockerfile itself.

Compose orchestrates three containers for us:
- **postgres** – a disposable database whose version tracks `POSTGRES_VERSION`, letting us validate compatibility with
  the bundled `pg_dump`.
- **minio** – an S3-compatible endpoint that uses `MINIO_ROOT_USER` / `MINIO_ROOT_PASSWORD`; override these if you point
  the stack at a real bucket.
- **backup** – the image under development. Its environment block mirrors what we expect in Kamal/Kubernetes so the
  smoke test behaves like production.

Because compose reads `.env`, tweaking variables such as `PASSPHRASE`, `S3_BUCKET`, or `POSTGRES_HOST` gives us realistic
scenarios (encrypted dumps, alternate buckets, remote databases) while staying entirely local.

Key environment variables the stack understands:
- `ALPINE_VERSION`, `POSTGRES_VERSION`, `SUPERCRONIC_SHA1SUM` — build-time knobs passed into the Dockerfile so `install.sh`
  downloads the matching client tools.
- `POSTGRES_HOST`, `POSTGRES_DATABASE`, `POSTGRES_USER`, `POSTGRES_PASSWORD` — describe the database to dump/restore. Point
  them at any reachable Postgres instance.
- `S3_BUCKET`, `S3_PREFIX`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` — core object storage settings. Swap
  them to match AWS, MinIO, DigitalOcean Spaces, Wasabi, Ceph, Backblaze B2, etc.
- `S3_ENDPOINT` — override the URL for S3-compatible providers. Leave empty to use AWS defaults.
- `S3_S3V4` — set to `yes` when the endpoint requires signature v4 (most modern providers).
- `SCHEDULE` — supercronic cadence for automated backups. Leave blank for manual runs only.
- `BACKUP_KEEP_DAYS` — optional pruning window. Empty skips deletion.
- `PASSPHRASE` — enables GPG encryption of dumps when set.
- `MINIO_IMAGE`, `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` — control which MinIO build runs in the dev stack and with which
  credentials; adjust them to mirror production S3 credentials if desired.


## Goals
[ ] add testing to ensure correct build and backup with restore
[ ] walkthough for version upgrade
[x] leverages https://github.com/aptible/supercronic?tab=readme-ov-file for cron instead of go-cron
