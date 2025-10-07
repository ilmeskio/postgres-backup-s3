# Repository Guidelines

## Project Structure & Module Organization
- Root contains `Dockerfile` for image, `compose.yml` for local harness, `README.md` w/ user docs.
- `src/` holds POSIX shell entrypoints: `install.sh` builds dependencies, `run.sh` orchestrates cron loop, `backup.sh` & `restore.sh` interact with Postgres and S3, `env.sh` centralizes environment validation.
- Backups and metrics write to container FS (e.g. `/metrics/metrics.txt`); mount volumes accordingly when developing.

## Build, Test, and Development Commands
- `docker build --build-arg ALPINE_VERSION=3.20 -t postgres-backup-s3 .` builds image against specific Alpine base.
- `docker compose up -d --build --force-recreate` spins up sample Postgres + backup job for manual verification.
- `docker exec postgres-backup-s3_backup_1 sh backup.sh` triggers on-demand backup inside running container; append `timestamp` argument to `restore.sh` to test targeted restores.
- `docker run --rm -v $(pwd)/src:/mnt koalaman/shellcheck:stable /mnt/*.sh` runs linting if you have Docker available.
- See `CONTRIBUTING.md` for the full checklist we expect before opening a PR.

## Coding Style & Naming Conventions
- Scripts are POSIX `sh`; avoid Bash-only features, keep two-space indentation inside blocks.
- Prefer uppercase snake_case for environment variables and read-only constants; use lowercase for local variables like `timestamp`.
- Always quote substitutions ("$VAR") and keep `set -eu -o pipefail` at the top of new scripts.
- Name new scripts consistently inside `src/` and document them in the Dockerfile `ADD` list.
- Write explanatory comments in a collaborative, narrative voice (“we …”) so teammates understand what each command does and why it exists without chasing external references.

## Testing Guidelines
- No automated suite yet; rely on `docker compose` scenario to validate backups and restores.
- Confirm encrypted backups when `PASSPHRASE` is set by checking S3 object suffix `.gpg`.
- When altering retention logic, run `aws s3api list-objects` against a test bucket and ensure pruning respects `BACKUP_KEEP_DAYS`.
- Capture `metrics/metrics.txt` to verify Prometheus output whenever metrics-related changes occur.

## Commit & Pull Request Guidelines
- Follow existing history: short, present-tense subjects under ~65 characters (`add cron metrics`, `update restore docs`).
- Provide context in the body for behavioural changes, especially anything touching S3 or secrets.
- PRs should enumerate changes, test evidence (commands and outputs), and note any required environment updates. Include related issue links or TODO references when applicable.

## Security & Configuration Tips
- Never commit real AWS keys; rely on `.env` files or local `docker compose` overrides excluded by `.gitignore`.
- Document new environment variables in `README.md` and `env.sh` so runtime validation stays consistent.
