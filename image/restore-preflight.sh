#!/usr/bin/env bash
# Preflight checks for the plane-restore Job's initContainer
# (PLAN_plane_backup.md §7, phase 1).
#
# Every check is read-only. All checks run regardless of earlier failures so
# a single `kubectl logs` shows the complete list of what's missing, not
# just the first problem. Any failure -> non-zero exit -> the Job's main
# container (phase 2, restore.sh) never starts.
#
# Required env: same restic/Postgres/MinIO vars as backup.sh, describing the
# *target* (fresh) install this restore is writing into.
#
# Optional env:
#   POD_NAMESPACE (via Downward API fieldRef: metadata.namespace) - used to
#     build the default POSTGRES_HOST below so the restore targets whichever
#     namespace this pod actually runs in, not a hardcoded one. Falls back
#     to "plane-ce" if unset (e.g. a manually-run debug pod).
#   SNAPSHOT_ID (default "latest")
#   RESTORE_FORCE=1 to allow restoring into a non-empty target database
#   RESTORE_SCRATCH_DIR (default /restore) - disk space is checked here

set -uo pipefail

: "${POSTGRES_USER:?}" "${POSTGRES_PASSWORD:?}" "${POSTGRES_DB:?}"
: "${AWS_ACCESS_KEY_ID:?}" "${AWS_SECRET_ACCESS_KEY:?}" "${AWS_S3_BUCKET_NAME:?}" "${AWS_S3_ENDPOINT_URL:?}"
: "${RESTIC_REPOSITORY:?}" "${RESTIC_PASSWORD:?}" "${B2_ACCOUNT_ID:?}" "${B2_ACCOUNT_KEY:?}"

POSTGRES_HOST="${POSTGRES_HOST:-plane-app-pgdb.${POD_NAMESPACE:-plane-ce}.svc.cluster.local}"
POSTGRES_PORT="${POSTGRES_PORT:-5432}"
RESTIC_HOST="${RESTIC_HOST:-plane-ce-prod}"
SNAPSHOT_ID="${SNAPSHOT_ID:-latest}"
RESTORE_FORCE="${RESTORE_FORCE:-0}"
RESTORE_SCRATCH_DIR="${RESTORE_SCRATCH_DIR:-/restore}"

export RESTIC_REPOSITORY RESTIC_PASSWORD B2_ACCOUNT_ID B2_ACCOUNT_KEY

FAILURES=()
SNAPSHOT_SUMMARY=""
STATS_SUMMARY=""

echo "[preflight] 1/6 checking restic repository and snapshots"
if ! SNAPSHOTS_JSON=$(restic snapshots --host "${RESTIC_HOST}" --json 2>&1); then
  FAILURES+=("restic snapshots failed - check RESTIC_REPOSITORY/RESTIC_PASSWORD/B2 creds and network egress to B2. Output: ${SNAPSHOTS_JSON}")
elif [ "$(echo "${SNAPSHOTS_JSON}" | grep -c '"id"')" -eq 0 ]; then
  FAILURES+=("restic repository reachable but has no snapshots for --host ${RESTIC_HOST}")
else
  echo "[preflight] 2/6 resolving target snapshot '${SNAPSHOT_ID}'"
  if [ "${SNAPSHOT_ID}" = "latest" ]; then
    SNAPSHOT_SUMMARY=$(restic snapshots --host "${RESTIC_HOST}" --latest 1 2>&1) \
      || FAILURES+=("could not resolve latest snapshot: ${SNAPSHOT_SUMMARY}")
  else
    if ! restic snapshots --host "${RESTIC_HOST}" | grep -q "${SNAPSHOT_ID}"; then
      FAILURES+=("requested snapshot '${SNAPSHOT_ID}' not found for --host ${RESTIC_HOST}")
    else
      SNAPSHOT_SUMMARY=$(restic snapshots "${SNAPSHOT_ID}" 2>&1)
    fi
  fi

  echo "[preflight] 5/6 checking B2/restic scratch space vs snapshot size"
  if STATS_SUMMARY=$(restic stats "${SNAPSHOT_ID}" --host "${RESTIC_HOST}" --mode raw-data 2>&1); then
    NEEDED_BYTES=$(echo "${STATS_SUMMARY}" | grep -oE '[0-9]+' | tail -1)
    AVAILABLE_BYTES=$(df -B1 --output=avail "${RESTORE_SCRATCH_DIR}" 2>/dev/null | tail -1 | tr -d ' ')
    if [ -n "${NEEDED_BYTES:-}" ] && [ -n "${AVAILABLE_BYTES:-}" ] && [ "${AVAILABLE_BYTES}" -lt "${NEEDED_BYTES}" ]; then
      FAILURES+=("insufficient space on ${RESTORE_SCRATCH_DIR}: need ~${NEEDED_BYTES} bytes, have ${AVAILABLE_BYTES}")
    fi
  else
    FAILURES+=("restic stats failed for snapshot '${SNAPSHOT_ID}': ${STATS_SUMMARY}")
  fi
fi

echo "[preflight] 3/6 checking target Postgres"
if ! PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
      -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc 'select 1' >/dev/null 2>&1; then
  FAILURES+=("cannot connect to target Postgres ${POSTGRES_DB}@${POSTGRES_HOST}:${POSTGRES_PORT} - confirm the fresh plane-app chart install has already run its own db/role init")
else
  LIVE_ROWS=$(PGPASSWORD="${POSTGRES_PASSWORD}" psql -h "${POSTGRES_HOST}" -p "${POSTGRES_PORT}" \
    -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -tAc \
    "select coalesce(sum(n_live_tup), 0) from pg_stat_user_tables" 2>/dev/null || echo "")
  if [ -z "${LIVE_ROWS}" ]; then
    FAILURES+=("could not determine whether target database already has data (pg_stat_user_tables query failed)")
  elif [ "${LIVE_ROWS}" -gt 0 ] && [ "${RESTORE_FORCE}" != "1" ]; then
    FAILURES+=("target database ${POSTGRES_DB} already has data (~${LIVE_ROWS} live rows across user tables) - refusing to restore over it. Set RESTORE_FORCE=1 to override.")
  fi
fi

echo "[preflight] 4/6 checking target MinIO"
if ! mc alias set targetminio "${AWS_S3_ENDPOINT_URL}" "${AWS_ACCESS_KEY_ID}" "${AWS_SECRET_ACCESS_KEY}" >/dev/null 2>&1; then
  FAILURES+=("mc alias set failed for target MinIO endpoint ${AWS_S3_ENDPOINT_URL}")
elif ! mc ls "targetminio/${AWS_S3_BUCKET_NAME}" >/dev/null 2>&1; then
  FAILURES+=("target MinIO bucket '${AWS_S3_BUCKET_NAME}' not reachable/does not exist - confirm the target chart's minio-bucket Job has run")
fi

echo
echo "[preflight] 6/6 summary"
echo "  source snapshot:   ${SNAPSHOT_ID} (host=${RESTIC_HOST})"
echo "${SNAPSHOT_SUMMARY}" | sed 's/^/  /'
echo "  target postgres:   ${POSTGRES_DB}@${POSTGRES_HOST}:${POSTGRES_PORT}"
echo "  target minio:      ${AWS_S3_ENDPOINT_URL}/${AWS_S3_BUCKET_NAME}"
echo "  restore size est.: ${STATS_SUMMARY:-unknown}"
echo

if [ "${#FAILURES[@]}" -gt 0 ]; then
  echo "[preflight] FAILED - ${#FAILURES[@]} problem(s) found, restore will NOT proceed:"
  for f in "${FAILURES[@]}"; do
    echo "  - ${f}"
  done
  exit 1
fi

echo "[preflight] all checks passed - proceeding to restore"
