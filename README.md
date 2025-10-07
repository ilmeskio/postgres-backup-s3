# Introduction
This project provides Docker images to periodically back up a PostgreSQL database to AWS S3, and to restore from the backup as needed.

Like everything else I do, the purpose is to contribute to my and others' educational path.

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

## Migrating to a new PostgreSQL version
When you promote your production database to a newer major, treat the backup flow as a rehearsal for the cutover:

1. Capture a fresh dump from the current cluster by running this image (or `docker exec <container> sh backup.sh`) with the existing connection details. This snapshot becomes the baseline you will restore into the new instance.
2. Provision a brand-new Postgres deployment on the target version. Keep the original database online while you validate the newcomer.
3. Restore the snapshot into the new instance with `docker exec <new-container> sh restore.sh <timestamp>`. The command drops and re-creates all objects, so run it against the empty destination you just created.
4. Run your application smoke tests, extension checks, and migration scripts against the restored database. Confirm credentials, extensions, and any foreign data wrappers behave as expected on the new major.
5. Schedule the production cutover: pause writes to the old cluster, take one last backup, restore it into the new database, then redirect traffic. If problems surface, you can point clients back at the previous cluster because it never changed in place.

Following this pattern keeps the upgrade reversible while proving that your backup artifacts travel cleanly across Postgres versions.

### Example: migrating from Postgres 16 to 17 with Docker Compose
When you rely on this repository’s published image, you can practice the cutover locally by running two stacks side by side:

1. **Spin up the Postgres 16 source.** Save the snippet below as `compose.v16.yml`, export AWS-style credentials in your shell, then bring it up with `docker compose -f compose.v16.yml up -d`. The backup service publishes dumps to `s3://my-upgrade-bucket/pg16`.

   ```yaml
   services:
     postgres16:
       image: postgres:16
       environment:
         POSTGRES_USER: demo
         POSTGRES_PASSWORD: demo

     backup16:
       image: ilmeskio/postgres-backup-s3:16
       environment:
         POSTGRES_HOST: postgres16
         POSTGRES_DATABASE: postgres
         POSTGRES_USER: demo
         POSTGRES_PASSWORD: demo
         S3_BUCKET: my-upgrade-bucket
         S3_PREFIX: pg16
         S3_REGION: us-east-1
         S3_ACCESS_KEY_ID: ${S3_ACCESS_KEY_ID}
         S3_SECRET_ACCESS_KEY: ${S3_SECRET_ACCESS_KEY}
         SCHEDULE: ''
       depends_on:
         - postgres16
   ```

   Before starting the stack, export the credentials you want the container to use:

   ```sh
   export S3_ACCESS_KEY_ID=AKIA...
   export S3_SECRET_ACCESS_KEY=super-secret
   ```

   Trigger a dump whenever you need it with `docker compose -f compose.v16.yml exec backup16 sh backup.sh`.

2. **Restore into the Postgres 17 target.** Create a second file `compose.v17.yml` that points at the same bucket (and, during testing, the same prefix). Bring it up with `docker compose -f compose.v17.yml up -d` and run `restore.sh` against the timestamp you just created.

   ```yaml
   services:
     postgres17:
       image: postgres:17
       environment:
         POSTGRES_USER: demo
         POSTGRES_PASSWORD: demo

     restore17:
       image: ilmeskio/postgres-backup-s3:17
       environment:
         POSTGRES_HOST: postgres17
         POSTGRES_DATABASE: postgres
         POSTGRES_USER: demo
         POSTGRES_PASSWORD: demo
         S3_BUCKET: my-upgrade-bucket
         S3_PREFIX: pg16
         S3_REGION: us-east-1
         S3_ACCESS_KEY_ID: ${S3_ACCESS_KEY_ID}
         S3_SECRET_ACCESS_KEY: ${S3_SECRET_ACCESS_KEY}
         SCHEDULE: ''
       depends_on:
         - postgres17
   ```

   Because both stacks target the same S3 bucket, the restore container sees the dumps created by the 16.x job. After running `docker compose -f compose.v17.yml exec restore17 sh restore.sh <timestamp>`, point your application at `postgres17` and confirm everything works. Once satisfied, you can tear down the temporary stacks with `docker compose -f compose.v16.yml down` and `docker compose -f compose.v17.yml down`.

# Acknowledgements
This project follows the path and great work of [schickling/dockerfiles](https://github.com/schickling/dockerfiles)
 and [eeshugerman/docker-postgres-backup-s3](https://github.com/eeshugerman/postgres-backup-s3) that unfortunately decided to archive the project.

Also thanks to [siemens/postgres-backup-s3](https://github.com/siemens/postgres-backup-s3/tree/master) that maintained a fork.


## Contributing
See [CONTRIBUTING.md](CONTRIBUTING.md) for hands-on setup, testing, and local stack guidance (including the Postgres version upgrade playbook), and [AGENTS.md](AGENTS.md) for the shared repository rules we follow.
