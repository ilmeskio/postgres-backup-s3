#!/bin/sh
#
# test-supercronic-arg.sh — We make sure our Dockerfile accepts and forwards the SUPERCRONIC_VERSION build argument so
# the publish pipeline can pin the scheduler release it expects. Catching this statically keeps us from shipping images
# with stale supercronic builds when teammates bump the default in CI.
#
# We enable strict mode so our check fails fast whenever the Dockerfile drifts.
set -euo pipefail

# We verify the Dockerfile declares SUPERCRONIC_VERSION as a build argument at least once so docker build treats the
# value from our workflow as legitimate.
if ! grep -q '^ARG SUPERCRONIC_VERSION' Dockerfile; then
  echo "ERROR: Dockerfile does not declare ARG SUPERCRONIC_VERSION, so the publish workflow's build-arg is ignored." >&2
  exit 1
fi

# We want the stage after FROM to re-declare the argument; otherwise RUN commands (including install.sh) never see the
# version that CI provides.
if ! awk '
  BEGIN { saw_from = 0; found = 0 }
  /^FROM[[:space:]]/ { saw_from = 1 }
  saw_from && /^ARG[[:space:]]+SUPERCRONIC_VERSION/ { found = 1 }
  END { exit(found ? 0 : 1) }
' Dockerfile >/dev/null; then
  echo "ERROR: Dockerfile does not re-declare ARG SUPERCRONIC_VERSION after FROM, so install.sh cannot read the value." >&2
  exit 1
fi

# We confirm the image exports the version as an environment variable so install.sh and future runtime scripts read the
# same release identifier our publish workflow selected.
if ! grep -q '^ENV SUPERCRONIC_VERSION=' Dockerfile; then
  echo "ERROR: Dockerfile never sets ENV SUPERCRONIC_VERSION, so install.sh falls back to its baked-in default." >&2
  exit 1
fi

echo "SUCCESS: Dockerfile exposes SUPERCRONIC_VERSION for both build-time and runtime consumers."
