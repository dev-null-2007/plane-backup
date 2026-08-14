#!/usr/bin/env bash
# Restore driver for the plane-restore Job's main container
# (PLAN_plane_backup.md §7, phase 2). Only reached if restore-preflight.sh
# passed, so no re-validation of reachability/emptiness happens here.
#
# Required/optional env: same as restore-preflight.sh.

set -euo pipefail
# Ignore SIGPIPE: nothing here relies on it, and a container-runtime log
# pipe hiccup mid-command (observed in testing: pg_restore killed with
# exit 141 - 128+SIGPIPE - right as it finished, aborting the script
# before the MinIO mirror step ever ran) would otherwise silently kill
# whichever command happened to be writing to stdout/stderr at the time,
# with no diagnostic output at all.
trap '' PIPE

: "${POSTGRES_USER:?}" "${POSTGRES_PASSWORD:?}" "${POSTGRES_DB:?}"
: "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}" "${AWS_S3_BUCKET_NAME:?}" "${AWS_S3_ENDPOINT_URL:?}"
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}" "${B2_ACCOUNT_ID:?}" "${B2_ACCOUNT_KEY:?}"

POSTGRES_HOST="${POSTGRES_HOST:-plane-app-pgdb.${POD_NAMESPACE:-plane-ce}.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
RESTIC_HOST="${RESTIC_HOST:-plane-ce-prod}"
SNAPSHOT_ID="${SNAPSHOT_ID:-latest}"
RESTORE_SCRATCH_DIR="${RESTORE_SCRATCH_DIR:-/restore}"
CONTENT_ROW_COUNT_SQL="${CONTENT_ROW_COUNT_SQL:-/usr/local/share/plane-backup/queries/content_row_count.sql}"

export RESTIC_REPOSITORY RESTIC_PASSWORD B2_ACCOUNT_ID B2_ACCOUNT_KEY

echo "[restore] 1/3 restic restore snapshot '${SNAPSHOT_ID}' -> ${RESTORE_SCRATCH_DIR}"
restic restore "${SNAPSHOT_ID}" --host "${RESTIC_HOST}" --target "${RESTORE_SCRATCH_DIR}"

DUMP_FILE=$(find "${RESTORE_SCRATCH_DIR}" -type f -name plane.dump | head -1)
: "${DUMP_FILE:?no plane.dump found under ${RESTORE_SCRATCH_DIR} after restic restore}"

echo "[restore] 2/3 pg_restore ${DUMP_FILE} -> ${POSTGRES_DB}@${POSTGRES_HOST}:${POSTGRES_PORT}"
# Buffered to a local file rather than writing straight to the container's
# stdout: pg_restore's own writes never touch the (occasionally flaky)
# container-log pipe while it's running, and we always get full output
# printed afterward, on both success and failure, instead of losing
# whatever hadn't been flushed yet if something downstream breaks.
PG_RESTORE_LOG="$(mktemp)"
PG_RESTORE_RC=0
PGPASSWORD="${POSTGRES_PASSWORD}" pg_restore --clean --if-exists \
  -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  "${DUMP_FILE}" >"${PG_RESTORE_LOG}" 2>&1 || PG_RESTORE_RC=$?
cat "${PG_RESTORE_LOG}" || true
rm -f "${PG_RESTORE_LOG}"
if [ "${PG_RESTORE_RC}" -ne 0 ]; then
  echo "[restore] pg_restore failed (exit ${PG_RESTORE_RC}) - see output above" >&2
  exit "${PG_RESTORE_RC}"
fi

MINIO_SRC_DIR=$(find "${RESTORE_SCRATCH_DIR}" -type d -path '*/minio/*' -mindepth 1 -maxdepth 10 | head -1)
: "${MINIO_SRC_DIR:?no minio object directory found under ${RESTORE_SCRATCH_DIR} after restic restore}"

echo "[restore] 3/3 mc mirror ${MINIO_SRC_DIR} -> target bucket ${AWS_S3_BUCKET_NAME}"
mc alias set targetminio "${AWS_S3_ENDPOINT_URL}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" >/dev/null
mc mirror --overwrite "${MINIO_SRC_DIR}" "targetminio/${AWS_S3_BUCKET_NAME}"

echo
echo "[restore] summary"
echo "  snapshot restored: ${SNAPSHOT_ID} (host=${RESTIC_HOST})"
ROW_COUNT=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
  -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tA \
  -f "${CONTENT_ROW_COUNT_SQL}" 2>/dev/null || echo "unknown")
echo "  postgres content rows (post-restore, excludes framework tables): ${ROW_COUNT}"
OBJECT_COUNT=$(mc ls --recursive "targetminio/${AWS_S3_BUCKET_NAME}" 2>/dev/null | wc -l || echo "unknown")
echo "  minio objects mirrored (post-restore): ${OBJECT_COUNT}"
echo
echo "[restore] done - verify by logging into the Plane UI and confirming a recent issue + its attachment (PLAN_plane_backup.md §7 operator steps)"
