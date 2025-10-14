ARG ALPINE_VERSION=3.20
ARG SUPERCRONIC_VERSION=0.2.36
#
# We build the runtime on top of the requested Alpine release so we can test
# multiple combinations locally and publish matching image tags downstream.
# Every build goes through install.sh, which expects TARGETARCH, POSTGRES_VERSION,
# and the SUPERCRONIC_SHA1SUM for the platform-specific binary. We declare the
# args here so docker compose (and manual builds) can override them without
# editing this file.
FROM alpine:${ALPINE_VERSION}
ARG TARGETARCH
ARG POSTGRES_VERSION
ARG SUPERCRONIC_VERSION
ARG SUPERCRONIC_SHA1SUM

ADD src/install.sh install.sh
ENV SUPERCRONIC_VERSION=${SUPERCRONIC_VERSION}
RUN sh install.sh && rm install.sh

ENV POSTGRES_PORT=5432
ENV PGDUMP_EXTRA_OPTS=""
ENV S3_REGION=us-west-1
ENV S3_PATH=backup
ENV S3_ENDPOINT=""
ENV S3_S3V4=no
ENV SCHEDULE=""
ENV BACKUP_KEEP_DAYS=""

ADD src/run.sh run.sh
ADD src/healthcheck.sh healthcheck.sh
ADD src/env.sh env.sh
ADD src/backup.sh backup.sh
ADD src/restore.sh restore.sh

HEALTHCHECK --interval=60s --timeout=5s --start-period=10s --retries=3 CMD sh /healthcheck.sh

CMD ["sh", "run.sh"]
