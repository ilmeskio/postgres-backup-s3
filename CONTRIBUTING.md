# Contributing

We welcome fixes and experiments that keep our backup image dependable. This guide explains how we validate changes together, how we write shell scripts consistently, and how we share the results back with the team.

## Getting Set Up
- Install Docker Desktop or a recent Docker Engine so we can build and run containers locally.
- Copy `.env.development` to `.env` before running any helper scripts. The defaults mirror our demo stack; adjust values like `SUPERCRONIC_SHA1SUM` or `MINIO_IMAGE` when you want to test other combinations.
- Use `docker compose up -d --build --force-recreate` to spin up the sample Postgres, MinIO, and backup containers. This gives us a fast playground to verify new behaviour without touching production systems.

## Local Verification Checklist
- `scripts/build-image.sh` — We rebuild the backup image with the current sources to confirm our Dockerfile, install flow, and build args still work together. The helper reads `.env`, so teammates can override `ALPINE_VERSION`, `POSTGRES_VERSION`, or `SUPERCRONIC_SHA1SUM` without editing files.
- `scripts/metrics-smoke.sh` — We launch the backup container with a long cron cadence, expose metrics on port 19746, and confirm Prometheus counters (`promhttp_metric_handler_requests_total`, `supercronic_*`) render correctly.
- `scripts/full-stack-smoke.sh` — We rehearse an end-to-end backup and restore against MinIO, giving us confidence that AWS-compatible flows keep working even when we change the S3 client or database logic. The script seeds the `demo-backups` bucket and keeps traffic on localhost.
- `scripts/migration-smoke.sh` — When touching dump or restore logic, we capture data on one Postgres major and restore it on another to ensure cross-version upgrades remain safe. Override `FROM_VERSION`, `TO_VERSION`, `FROM_ALPINE_VERSION`, or `TO_ALPINE_VERSION` to explore other combinations.
- `docker run --rm -v "$(pwd)"/src:/mnt koalaman/shellcheck:stable /mnt/*.sh` — We lint our POSIX scripts to catch quoting mistakes and subshell surprises early.

Running the full list is ideal for feature work. For small documentation updates, call out which checks you skipped when opening a pull request so reviewers know what remains.

### Helpful Extras
- Git hooks: `git config core.hooksPath githooks` enables our pre-push hook, which delegates to `scripts/build-image.sh` so broken images never leave your machine.
- Schedule validation: `scripts/validate-schedule.sh` starts the image with `supercronic -test`, confirms a known-good cron line passes, then expects a failure for an invalid cadence. Run it when you change scheduling defaults or env validation.
- Metrics peek: After running `scripts/metrics-smoke.sh`, fetch a sample payload with `curl -s http://localhost:19746/metrics | head` to verify Prometheus parsing locally.

## Local Stack Architecture
Our Dockerfile mirrors the production image we publish. We declare build arguments for the Alpine base, the Postgres client version, and the supercronic checksum so `src/install.sh` can pull the exact binaries we need. Because `docker compose` forwards those build args from environment variables, we can iterate on `ALPINE_VERSION`, `POSTGRES_VERSION`, or `SUPERCRONIC_SHA1SUM` without editing source files.

The compose stack spins up three services for us:
- **postgres** — a disposable database whose version tracks `POSTGRES_VERSION`, letting us confirm `pg_dump` parity.
- **minio** — an S3-compatible endpoint controlled by `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD`. Override them when you point at a real object store.
- **backup** — the image under development. Its environment block mirrors what we expect in Kamal or Kubernetes, so the smoke tests behave like production.

Because compose reads `.env`, we can rehearse real-world scenarios by adjusting variables such as:
- `S3_BUCKET`, `S3_PREFIX`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` — the core object storage settings. Point them at AWS, MinIO, DigitalOcean Spaces, Wasabi, Ceph, Backblaze B2, and other compatible targets.
- `S3_ENDPOINT` and `S3_S3V4` — toggle signature v4 or point to a custom endpoint when needed.
- `PASSPHRASE` — enable GPG encryption and confirm restores still succeed.
- `POSTGRES_HOST`, `POSTGRES_DATABASE`, `POSTGRES_USER`, `POSTGRES_PASSWORD` — direct the backup job at the database we are testing.
- `BACKUP_KEEP_DAYS` — exercise retention logic without pruning production data.
- `SCHEDULE`, `SUPERCRONIC_SPLIT_LOGS`, `SUPERCRONIC_DEBUG` — rehearse cron behaviour and logging changes before they reach production.
- `MINIO_IMAGE` — try newer MinIO releases while keeping the rest of the stack stable.

These knobs keep all traffic on localhost while simulating the combinations we expect in the field.

## Postgres Version Upgrade Playbook
When a new Postgres major or minor release lands, we follow this checklist so the image, scripts, and docs stay in sync.

1. **Confirm client packages exist.** Check the scheduled **Monitor Postgres 18 Client** workflow results (or run it manually) to see whether Alpine ships `postgresql<version>-client`. If the package is missing, open or update the tracking issue instead of shipping a partial upgrade.
2. **Update pinned defaults.** Bump the baseline versions in `Dockerfile` (`ARG ALPINE_VERSION`), `scripts/build-image.sh`, `.env.development`, and the build args inside `compose.yml`. Keep these values aligned so local smoke tests and CI exercise the same pairing.
3. **Refresh automation matrices.** Extend the version lists in `.github/workflows/ci.yml` (both the image-build and migration matrices) and `.github/workflows/publish-images.yml`. When we add a new highest major, mark it as `latest` in the publish job and adjust any skip comments that referenced the old ceiling.
4. **Revisit helper scripts.** Update mappings like `resolve_alpine_version` in `scripts/migration-smoke.sh` and any other version-specific logic (for example, default MinIO images or checksum tables) so rehearsals pick the right Alpine base.
5. **Run the full validation suite.** Execute `scripts/build-image.sh`, `scripts/metrics-smoke.sh`, `scripts/full-stack-smoke.sh`, and `scripts/migration-smoke.sh` (covering the new upgrade path as well as the previous highest -> new highest). Note the command outputs in your PR so reviewers see evidence.
6. **Document the change.** Adjust README snippets (image tags, supported majors, example compose files) and AGENTS/CONTRIBUTING notes to match the new support window. If the release introduces behavioural differences, call them out in the changelog or release notes.
7. **Coordinate the release.** Once the branch merges, tag a release or trigger the **Publish Images** workflow with an explicit `version_tag`. Confirm Docker Hub shows the new major tags and that `latest` points at the highest supported Postgres build.

Following these steps keeps our upgrade story predictable for anyone depending on the published images.

## Coding Standards
- Write POSIX `sh` compatible code: avoid Bash-only niceties, prefer two-space indentation inside blocks, and keep `set -eu` (plus `-o pipefail` when available) at the top of executable scripts.
- Name environment variables in uppercase snake_case (`S3_BUCKET`), and keep short-lived locals lowercase (`timestamp`).
- Quote parameter expansions (`"$VAR"`) to defend against spaces and globbing.
- Narrate non-trivial steps with collaborative comments: explain why the command exists, what it does, and how teammates should expect it to behave. This storytelling style keeps future contributors confident when they extend the scripts.

## Branches, Commits, and Reviews
- Use short, present-tense commit subjects under ~65 characters (e.g., `add cron metrics`, `document restore caveats`).
- In commit bodies and pull requests, list the validation steps you ran and include command snippets or output when it adds clarity.
- Document any new environment variables in both `README.md` and `src/env.sh` so runtime validation stays aligned with the docs.
- Mention related issues or TODOs in the PR description to link context for future readers.

## Release Readiness
- Before tagging a release or pushing image changes, ensure the `githooks/pre-push` hook (or an explicit run of `scripts/build-image.sh`) passes.
 - Our **Publish Images** workflow builds multi-architecture images (Postgres majors 14–18 for `linux/amd64` and `linux/arm64`) and promotes the highest major to `latest`. Run it on tags matching `v*` or trigger it manually with a custom `version_tag`.
- Check that the workflow secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` remain valid; mention any credential or registry changes in the release notes so the team can follow up.

With these guardrails, we can evolve the project quickly while keeping restores reliable for everyone depending on it. Thanks for helping us maintain that standard!
