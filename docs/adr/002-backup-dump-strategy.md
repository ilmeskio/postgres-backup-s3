# ADR 002: Use `pg_dump` Logical Backups

- **Status:** Accepted
- **Date:** 2025-03-15

## Context
We need backups that travel easily between environments, avoid requiring superuser filesystem access, and restore cleanly
on newer PostgreSQL majors during rehearsals. Physical base backups or WAL archiving deliver point-in-time recovery but
force operators to manage full-cluster states, matching minor versions, and replication slots. Our container often runs
against managed databases where low-privilege credentials are the norm.

## Decision
We rely on `pg_dump` logical backups (`pg_dump --format=custom`) to capture schema and data. The script lives inside the
container, authenticates with the provided Postgres credentials, and streams compressed dumps directly to S3. During
restores we use `pg_restore` to recreate the database objects, enabling cross-version rehearsals when teams migrate.

## Consequences
- Logical dumps remain portable: we can restore into newer majors as part of upgrade rehearsals without spinning up matching
  minor versions.
- Backup size can be larger than physical backups for write-heavy workloads, and point-in-time recovery still requires an
  additional WAL strategy.
- Restores drop and recreate objects, so operators must point the job at an empty database or accept data loss during a
  recovery run.
- Because `pg_dump` operates at the SQL layer, we must educate users about handling extensions or large objects that may
  need extra flags—our scripts expose `PGDUMP_EXTRA_OPTS` to help.

## References
- `src/backup.sh` and `src/restore.sh` for the canonical implementation.
- README guidance on migrations and manual restores.
