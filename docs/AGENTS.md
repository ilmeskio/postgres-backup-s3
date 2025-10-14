# Documentation Guidelines

We keep documentation close to the code so userland teams can trust what they read. This guide covers how we approach
reference docs, ADRs, and contributor notes inside `docs/`.

## ADR Stewardship
- Store every architecture decision under `docs/adr/` using the numbered convention (`00x-title.md`).
- Start from `000-template.md` when drafting a new ADR so context, decision, and consequences stay consistent.
- Update `docs/adr/README.md` with each new record, and link related pull requests or issues in the ADR references section.

## User Documentation
- `README.md` remains the primary onboarding surface. When we adjust runtime behavior (tagging, env vars, schedules),
  update both the README and any relevant ADR so stories stay in sync.
- Example snippets should reflect the latest tagging policy (major anchors with optional numeric suffixes) and current
  environment variables validated by `src/env.sh`.
- Use the project’s narrative tone—explain why a step exists, what it does, and how readers should expect it to behave.

## Contributor References
- Keep `CONTRIBUTING.md` aligned with our smoke scripts, GitHub Actions expectations, and release process. When we add a
  new mandatory check, reflect it there.
- If we introduce tooling that impacts documentation (e.g., new diagrams, ADR tooling), note prerequisites and commands in
  this file so future writers can reproduce the setup.

## Review Checklist
- Confirm links resolve (including ADR cross-references).
- Validate that instructions match current scripts (run `scripts/build-image.sh` or other referenced commands if they are
  part of the workflow).
- Flag any divergence between ADRs and README/CONTRIBUTING quickly so we do not drift on policy.
