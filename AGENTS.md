# Engineering Guidelines

This public repository delivers a user-facing Docker image that operators can run in their own infrastructure. Our job is to
ship predictable builds, document notable decisions, and keep the scripts approachable for folks who do not maintain the
code every day.

## Structure & Ownership
- Root houses the image contract: `Dockerfile`, `compose.yml` for rehearsal harnesses, and `README.md` for user docs.
- Runtime scripts live in `src/` (`install.sh`, `run.sh`, `backup.sh`, `restore.sh`, `env.sh`); each script owns a focused
  responsibility and must stay POSIX `sh`.
- Decision records land under `docs/adr/`; check the index before reinventing a policy and add a new ADR whenever we change
  course.
- We keep a living `TODO.md` checklist; review it when starting a session so we catch the outstanding release and registry
  integration steps before diving into fresh tasks.

## Coding Conventions
- Keep scripts strict: start with `set -eu` and probe for `pipefail` availability (`if (set -o pipefail) ...`).
- Use uppercase snake case for environment variables, lowercase for locals; quote every substitution and prefer two-space
  indentation inside control blocks.
- Document non-obvious logic with the inclusive narrative voice we use elsewhere so userland contributors can follow the
  story.
- Whenever we add new entrypoints, list them in the Dockerfile `ADD` segment so downstream builds stay reproducible.

## Testing & CI Flow
- Local guard rails live in `scripts/`: run `sh scripts/build-image.sh` before pushing. The script now calls
  `scripts/test-supercronic-arg.sh` and `docker compose build backup`, matching our GitHub Actions flow.
- GitHub Actions builds a matrix across supported Postgres majors, runs the smoke scripts, and publishes when we push an
  annotated release tag. When adding new checks, extend the workflow so local and CI behavior stay aligned.
- We now keep the GitHub CLI (`gh`) in our toolbox, so we can review and rerun pipelines quickly. After every push, run
  `gh run list --limit 5` to confirm the latest workflow is green, and use `gh run view <run-id> --log` when we need to
  narrate failures back into fixes.
- Use `docker compose` scenarios for end-to-end rehearsals (backup + restore, migrations). Record additional scripts under
  `scripts/` so the whole team can reproduce them.

## Release & Tagging
- Publish images by pushing git tags that match the numeric revision suffix (`v3` → `:14-3`, `:15-3`, `:16-3`, `:17-3`).
- Anchor tags (`:14`, `:15`, `:16`, `:17`) always point at the newest release per major; we deliberately skip a global
  `latest` tag to keep users intentional about the major they deploy.
- Document changes to tagging, retention, or scheduling policy through ADRs and CHANGELOG/README updates so userland teams
  understand the impact.
- Before we trigger the **Publish Images** workflow, confirm `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` exist in repository
  secrets; our `TODO.md` checklist tracks the setup and the dry-run we expect before announcing a release.

## Pull Requests & Reviews
- Match the existing commit style: short, present-tense subjects under ~65 characters; explain context and include test
  evidence in the body.
- When touching S3 flows, metrics, or retention, list the manual verifications you ran (e.g., `aws s3api list-objects`,
  metrics scrape, restore rehearsal).
- Highlight user-facing implications in PR summaries so downstream teams can prepare for the change.

## Security & Configuration
- Never commit actual secrets. Use `.env` (ignored) or compose overrides for local work, and document new variables in both
  `README.md` and `src/env.sh`.
- Keep AWS CLI usage scoped to the required calls (`PutObject`, `ListBucket`, `GetObject`); anything broader needs a clear
  justification in code review.
