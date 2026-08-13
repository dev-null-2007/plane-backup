# Plane CE backup/restore image: restic + mc + pg_dump/pg_restore/psql +
# driver scripts. Used by both the backup CronJob and the plane-restore Job
# (see PLAN_plane_backup.md §5.3, §6, §7).
#
# NOTE: postgresql15-client below assumes the live Postgres server is major
# version 15 (plan §2, unverified against the live cluster as of writing).
# Re-check `kubectl get statefulset plane-app-pgdb-wl -n plane-ce -o
# jsonpath='{.spec.template.spec.containers[0].image}'` before building, and
# bump the package version here to match if it has changed.

FROM alpine:3.20

ARG MC_VERSION=RELEASE.2024-07-31T15-58-33Z
ARG TARGETARCH

RUN apk add --no-cache \
      bash \
      restic \
      postgresql15-client \
      curl \
      ca-certificates \
  && curl -fsSL -o /usr/local/bin/mc \
      "https://dl.min.io/client/mc/release/linux-${TARGETARCH}/archive/mc.${MC_VERSION}" \
  && chmod +x /usr/local/bin/mc \
  && mc --version

COPY backup.sh /usr/local/bin/backup.sh
COPY restore-preflight.sh /usr/local/bin/restore-preflight.sh
COPY restore.sh /usr/local/bin/restore.sh
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore-preflight.sh /usr/local/bin/restore.sh

ENTRYPOINT []
