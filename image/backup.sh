#!/usr/bin/env bash
# Backup driver for the plane-backup CronJob (PLAN_plane_backup.md §6).
#
# Dumps Postgres (pg_dump -Fc) and mirrors the MinIO bucket (mc mirror) to a
# scratch directory, then hands both to restic for a deduped/encrypted
# snapshot in B2, prunes per retention policy, and runs a metadata-only
# integrity check.
#
# Required env (from plane-app-pgdb-secrets, plane-app-doc-store-secrets,
# and plane-backup-restic-creds via envFrom):
#   POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_S3_BUCKET_NAME,
#     AWS_S3_ENDPOINT_URL
#   RESTIC_REPOSITORY, RESTIC_PASSWORD, B2_ACCOUNT_ID, B2_ACCOUNT_KEY
#
# Optional env:
#   POD_NAMESPACE (via Downward API fieldRef: metadata.namespace) - used to
#     build the default POSTGRES_HOST below so it targets whichever
#     namespace this pod actually runs in, not a hardcoded one. Falls back
#     to "plane-ce" if unset (e.g. a manually-run debug pod).
#   POSTGRES_HOST (default plane-app-pgdb.<POD_NAMESPACE>.svc.cluster.local)
#   POSTGRES_PORT (default 5432)
#   RESTIC_HOST (default plane-ce-prod)
#   RESTIC_KEEP_DAILY / RESTIC_KEEP_WEEKLY / RESTIC_KEEP_MONTHLY
#     (defaults 14 / 8 / 12)
#   BACKUP_DIR (default /backup)

set -euo pipefail

: "${POSTGRES_USER:?}" "${POSTGRES_PASSWORD:?}" "${POSTGRES_DB:?}"
: "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}" "${AWS_S3_BUCKET_NAME:?}" "${AWS_S3_ENDPOINT_URL:?}"
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}" "${B2_ACCOUNT_ID:?}" "${B2_ACCOUNT_KEY:?}"

POSTGRES_HOST="${POSTGRES_HOST:-plane-app-pgdb.${POD_NAMESPACE:-plane-ce}.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
RESTIC_HOST="${RESTIC_HOST:-plane-ce-prod}"
RESTIC_KEEP_DAILY="${RESTIC_KEEP_DAILY:-14}"
RESTIC_KEEP_WEEKLY="${RESTIC_KEEP_WEEKLY:-8}"
RESTIC_KEEP_MONTHLY="${RESTIC_KEEP_MONTHLY:-12}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"

export RESTIC_REPOSITORY RESTIC_PASSWORD B2_ACCOUNT_ID B2_ACCOUNT_KEY

echo "[backup] preparing scratch dir ${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}/postgres" "${BACKUP_DIR}/minio"

echo "[backup] pg_dump ${POSTGRES_DB}@${POSTGRES_HOST}:${POSTGRES_PORT}"
PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
  -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc \
  -f "${BACKUP_DIR}/postgres/plane.dump"

echo "[backup] mirroring MinIO bucket ${AWS_S3_BUCKET_NAME}"
mc alias set planeminio "${AWS_S3_ENDPOINT_URL}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" >/dev/null
mc mirror --overwrite "planeminio/${AWS_S3_BUCKET_NAME}" "${BACKUP_DIR}/minio/${AWS_S3_BUCKET_NAME}"

echo "[backup] ensuring restic repository is initialized"
restic snapshots --host "${RESTIC_HOST}" >/dev/null 2>&1 || restic init

echo "[backup] restic backup"
restic backup "${BACKUP_DIR}" --tag plane-ce --host "${RESTIC_HOST}"

echo "[backup] pruning per retention policy (daily=${RESTIC_KEEP_DAILY} weekly=${RESTIC_KEEP_WEEKLY} monthly=${RESTIC_KEEP_MONTHLY})"
restic forget --tag plane-ce --host "${RESTIC_HOST}" \
  --keep-daily "${RESTIC_KEEP_DAILY}" \
  --keep-weekly "${RESTIC_KEEP_WEEKLY}" \
  --keep-monthly "${RESTIC_KEEP_MONTHLY}" \
  --prune

echo "[backup] integrity check (metadata-only)"
restic check

echo "[backup] done"
