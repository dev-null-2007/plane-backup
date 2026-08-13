#!/usr/bin/env bash
# Creates/updates the plane-backup-restic-creds Secret (PLAN_plane_backup.md
# §4). Run manually/locally whenever B2/restic credentials need to be
# (re)set. Never commit the values this script takes as arguments.
#
# Usage:
#   ./setup-backup-secret.sh \
#     --b2-account-id <id> \
#     --b2-account-key <key> \
#     --restic-password <password> \
#     --b2-bucket <bucket-name> \
#     [--repo-path plane-ce] \
#     [--namespace plane-ce] \
#     [--secret-name plane-backup-restic-creds]
#
# The Secret lives in the plane-ce namespace by default (plan §5's revised
# decision: co-located with the CronJob so cross-namespace secretRef isn't
# needed), separate from the chart-managed plane-app-* secrets so a
# `helm upgrade plane-app` can never touch or wipe it.

set -euo pipefail

NAMESPACE="plane-ce"
SECRET_NAME="plane-backup-restic-creds"
REPO_PATH="plane-ce"
B2_ACCOUNT_ID=""
B2_ACCOUNT_KEY=""
RESTIC_PASSWORD=""
B2_BUCKET=""

usage() {
  grep '^#' "$0" | sed -e '1d' -e 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --b2-account-id) B2_ACCOUNT_ID="$2"; shift 2 ;;
    --b2-account-key) B2_ACCOUNT_KEY="$2"; shift 2 ;;
    --restic-password) RESTIC_PASSWORD="$2"; shift 2 ;;
    --b2-bucket) B2_BUCKET="$2"; shift 2 ;;
    --repo-path) REPO_PATH="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --secret-name) SECRET_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

MISSING=()
[ -n "${B2_ACCOUNT_ID}" ] || MISSING+=("--b2-account-id")
[ -n "${B2_ACCOUNT_KEY}" ] || MISSING+=("--b2-account-key")
[ -n "${RESTIC_PASSWORD}" ] || MISSING+=("--restic-password")
[ -n "${B2_BUCKET}" ] || MISSING+=("--b2-bucket")

if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "error: missing required argument(s): ${MISSING[*]}" >&2
  echo "no secret was created (fail fast, no partial secret)" >&2
  exit 1
fi

RESTIC_REPOSITORY="b2:${B2_BUCKET}:${REPO_PATH}"

echo "Creating/updating Secret '${SECRET_NAME}' in namespace '${NAMESPACE}'..."
echo "  RESTIC_REPOSITORY=${RESTIC_REPOSITORY}"

kubectl create secret generic "${SECRET_NAME}" \
  --namespace "${NAMESPACE}" \
  --from-literal=B2_ACCOUNT_ID="${B2_ACCOUNT_ID}" \
  --from-literal=B2_ACCOUNT_KEY="${B2_ACCOUNT_KEY}" \
  --from-literal=RESTIC_PASSWORD="${RESTIC_PASSWORD}" \
  --from-literal=RESTIC_REPOSITORY="${RESTIC_REPOSITORY}" \
  --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

echo "done."
echo
echo "NOTE: if this rotated existing credentials mid-cycle, the running"
echo "CronJob's next scheduled run will pick up the new Secret automatically,"
echo "but any Job already in flight was started with the old values. If you"
echo "need the new credentials to take effect immediately, re-trigger the"
echo "CronJob now: kubectl create job --from=cronjob/plane-backup" \
     "plane-backup-manual-\$(date +%s) -n ${NAMESPACE}"
