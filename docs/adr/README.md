# Architecture Decision Records

We capture notable technical choices in lightweight ADRs so everyone can follow the story behind the system. Each record
focuses on one decision, links relevant context, and notes the consequences we expect. New insights can supersede older
ADRs, but we keep the history intact for future teammates.

| ADR | Title | Status |
| --- | ----- | ------ |
| [001](001-s3-storage-technology.md) | Standardize on S3-Compatible Object Storage | Accepted |
| [002](002-backup-dump-strategy.md) | Use `pg_dump` Logical Backups | Accepted |
| [003](003-job-scheduler-supercronic.md) | Schedule Backups with Supercronic | Accepted |
| [004](004-testing-approach.md) | Embrace Scripted Smoke Tests Over Full Integration Suite | Accepted |
| [005](005-versioning-and-tagging.md) | Anchor Tags by Postgres Major with Numeric Revision Suffixes | Accepted |
