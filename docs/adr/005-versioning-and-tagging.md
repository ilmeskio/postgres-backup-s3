# ADR 005: Anchor Tags by Postgres Major with Numeric Revision Suffixes

- **Status:** Accepted
- **Date:** 2025-03-15

## Context
We publish one image per supported Postgres major and need a predictable way to communicate internal changes—new
Supercronic versions, Alpine patch levels, or backup script tweaks. Docker users expect `:16` or `:17` to map to the
latest build for that major, mirroring the official Postgres image. We previously experimented with `latest` tags and
Alpine-specific suffixes, but they caused confusion when teams wanted to pin a specific revision.

## Decision
We tag every release with:
- A major anchor: `ilmeskio/postgres-backup-s3:<major>` (e.g., `:17`) that always points at the newest build for that
  Postgres major.
- A numbered revision suffix: `ilmeskio/postgres-backup-s3:<major>-<n>` (e.g., `:17-3`) that increments whenever we change
  internals for that major. The revision value is shared across all majors in the release, so a single publication emits
  `:14-3`, `:15-3`, `:16-3`, and `:17-3`.

We no longer push a global `latest` tag or embed Alpine version names in Docker tags. Release automation expects a git tag
`v<n>` that matches the numeric suffix and reuses it for every major in the matrix.

## Consequences
- Users who want “the newest 17.x backup image” can pull `:17`; those who need deterministic builds can pin `:17-3`.
- Removing the `latest` tag eliminates ambiguity when new majors appear—operators must choose the anchor explicitly.
- Release tooling must ensure the numeric suffix monotonically increases across releases and that superseded anchors are
  overwritten.
- Documentation, compose files, and examples should continue showcasing anchor tags with optional suffixes so users learn
  the pattern.

## References
- `.github/workflows/publish-images.yml` for the tagging implementation.
- `README.md` section on image tags.
