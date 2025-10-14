# ADR 004: Embrace Scripted Smoke Tests Over Full Integration Suite

- **Status:** Accepted
- **Date:** 2025-03-15

## Context
The project primarily ships shell scripts and a Docker image. A full integration harness would require orchestrating real
PostgreSQL clusters, S3-compatible endpoints, and time-based schedules—heavyweight for contributors and CI. We still need
confidence in critical flows: building the image, running backup/restore scripts, and maintaining metrics.

## Decision
We rely on targeted shell-based smoke tests and helper scripts rather than a bespoke test framework. Key pieces:
- `scripts/build-image.sh` validates Docker builds with the current defaults and now asserts the Dockerfile wiring we rely
  on (e.g., Supercronic version propagation).
- Docker Compose scenarios in `compose.yml` and companion smoke scripts let us rehearse end-to-end flows manually without
  pulling in large dependencies at commit time.
- Contributors run `docker compose` and optional Docker-based linting (e.g., shellcheck) locally to validate changes prior
  to release.

## Consequences
- Tests stay fast and accessible; any teammate with Docker can reproduce the critical checks.
- We trade exhaustive automation for pragmatic coverage: certain distributed behaviors (network partitions, S3 throttling)
  remain manual verification items.
- Each new regression guard should follow the same philosophy—lightweight shell scripts or Compose stacks that live in the
  repo and are easy to run in CI.
- Documentation must continue pointing contributors at the smoke scripts so expectations stay aligned.

## References
- `scripts/` directory containing build and smoke helpers.
- `CONTRIBUTING.md` checklist describing the expected manual verification steps.
