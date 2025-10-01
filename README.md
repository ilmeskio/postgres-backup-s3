# Introduction
This project provides Docker images to periodically back up a PostgreSQL database to AWS S3, and to restore from the backup as needed.

Like everything else I do, the purpose is to contribue to mine and others educational path.

# Usage
## Backup
```yaml
postgres:
  image: postgres:13
  environment:
    POSTGRES_USER: user
    POSTGRES_PASSWORD: password

pg_backup_s3:
  image: ilmeskio/postgres-backup-s3:13
  environment:
    SCHEDULE: '@weekly'
    PASSPHRASE: passphrase
    S3_REGION: region
    S3_ACCESS_KEY_ID: key
    S3_SECRET_ACCESS_KEY: secret
    S3_BUCKET: my-bucket
    S3_PREFIX: backup
    POSTGRES_HOST: postgres
    POSTGRES_DATABASE: dbname
    POSTGRES_USER: user
    POSTGRES_PASSWORD: password
    ENABLE_METRICS: true
```
- Images are tagged by the major PostgreSQL version they support: `9`, `10`, `11`, `12`, or `13`.
- The `SCHEDULE` variable determines backup frequency. See [supercronic's schedule documentation](https://github.com/aptible/supercronic#usage) for supported syntax (standard cron expressions and `@every` intervals).
- If `PASSPHRASE` is provided, the backup will be encrypted using GPG.
- Run `docker exec <container name> sh backup.sh` to trigger a backup ad-hoc

### Backup Metrics

Optionally you can also export backup metrics, e.g. size, start time in Prometheus
file format. To read the metrics, you'll have to mount the metrics folder to your host at `/metrics`.
The file is called `metrics.txt`.

```sh
$ docker run -v $(pwd)/metrics:/metrics -e ENABLE_METRICS=true -e ... siemens/postgres-backup-s3
```

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

Run `scripts/test-local.sh` to confirm the Docker image still builds before sharing a branch. The helper picks
architecture-aware defaults (`ALPINE_VERSION=3.20`, `POSTGRES_VERSION=16`, and the matching supercronic checksum), while
allowing overrides through environment variables when we want to experiment:

```sh
$ ALPINE_VERSION=3.19 POSTGRES_VERSION=15 scripts/test-local.sh
```

To run the check automatically on every push, point Git hooks to the provided scripts:

```sh
$ git config core.hooksPath githooks
```

The `githooks/pre-push` script delegates to `scripts/test-local.sh`, so local pushes will fail fast whenever the image
breaks.

### End-to-end smoke test (no real S3 required)

Run `scripts/dev-smoke.sh` to spin up Postgres, a MinIO S3-compatible target, and the backup job via `docker compose`.
The script seeds a demo bucket (`demo-backups`), performs a backup, and immediately restores it to verify the entire
flow. MinIO exposes a local console at http://localhost:9001 if you want to inspect objects, and all traffic stays on
your machine.

Copy `.env.development` to `.env` before running the compose stack so the build and runtime variables have sensible
defaults. Tweak the values (especially `SUPERCRONIC_SHA1SUM` for your architecture) whenever you want to test a new
Postgres or Alpine combination. (The file only contains public demo credentials—swap them before pointing at a real S3.)


## Goals
[ ] add testing to ensure correct build and backup with restore
[ ] walkthough for version upgrade
[x] leverages https://github.com/aptible/supercronic?tab=readme-ov-file for cron instead of go-cron
