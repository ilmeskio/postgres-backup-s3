ARG ALPINE_VERSION=3.20
FROM alpine:${ALPINE_VERSION}
ARG TARGETARCH
ARG POSTGRES_VERSION
ARG SUPERCRONIC_SHA1SUM

ADD src/install.sh install.sh
RUN sh install.sh && rm install.sh

ENV POSTGRES_PORT=5432
ENV PGDUMP_EXTRA_OPTS=""
ENV S3_REGION=us-west-1
ENV S3_PATH=backup
ENV S3_ENDPOINT=""
ENV S3_S3V4=no
ENV SCHEDULE=""
ENV PASSPHRASE=""
ENV BACKUP_KEEP_DAYS=""

ADD src/run.sh run.sh
ADD src/env.sh env.sh
ADD src/backup.sh backup.sh
ADD src/restore.sh restore.sh

CMD ["sh", "run.sh"]
