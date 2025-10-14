# ADR 003: Schedule Backups with Supercronic

- **Status:** Accepted
- **Date:** 2025-03-15

## Context
Our backup container runs as PID 1 inside a minimal Alpine image. Traditional `cron` daemons expect an init system, demand
privileged filesystem access, and provide limited observability. We need a scheduler that tolerates container restarts,
logs job results, exposes readiness signals, and speaks standard cron syntax so operators do not relearn schedules.

## Decision
We adopt [Supercronic](https://github.com/aptible/supercronic) as the embedded scheduler. Supercronic runs as the primary
process, tails a single cron file, emits structured logs, and publishes Prometheus metrics plus an HTTP health endpoint.
Our image ships with Supercronic pre-installed, and `run.sh` assembles the crontab from environment variables before
handing control over.

## Consequences
- We gain consistent job execution with clear logging, metrics endpoints, and dead-letter behavior without running a full
  init stack inside the container.
- Because Supercronic is an external project, we must monitor releases, verify checksums, and keep the binary up to date
  (our publish workflow now pins the version explicitly).
- Operators can flip runtime toggles (`SUPERCRONIC_DEBUG`, `SUPERCRONIC_SPLIT_LOGS`) to troubleshoot schedules without
  rebuilding the image.
- The container assumes a single-process model; anyone needing multiple independent schedules should run separate
  containers or extend the entrypoint.

## References
- `src/run.sh` describing the Supercronic entrypoint.
- `.github/workflows/publish-images.yml` for the pinned binary version and build arguments.
