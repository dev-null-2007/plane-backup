#!/usr/bin/env python3
"""Print per-table row counts (pg_stat_user_tables) for a Plane instance's
Postgres, without needing a local SQL client.

Spins up (or reuses) a throwaway pod built from the plane-backup image
(which already bundles psql) in the target namespace, reads that
namespace's own plane-app-pgdb-secrets, and runs the query via `kubectl
exec`. Only `kubectl` and `python3` are required locally.

Usage:
  ./scripts/check_table_rows.py -n plane-ce
  ./scripts/check_table_rows.py -n plane2-ce --limit 40
  ./scripts/check_table_rows.py -n plane2-ce --cleanup   # delete pod after

This exists to diagnose PLAN_plane_backup.md §7's preflight "is the target
database empty" check by hand: `restore-preflight.sh` sums n_live_tup
across ALL user tables, which also counts Django/DRF framework bookkeeping
(auth_permission, django_content_type, django_migrations, etc.) that's
present the instant migrations finish, before any real user data exists.
Use this to see which tables actually hold the rows before deciding
whether the preflight check needs to get smarter.
"""
import argparse
import subprocess
import sys

POD_NAME = "plane-backup-diag"

POD_MANIFEST_TEMPLATE = """\
apiVersion: v1
kind: Pod
metadata:
  name: {pod_name}
  namespace: {namespace}
spec:
  restartPolicy: Never
  containers:
    - name: shell
      image: {image}
      command: ["sleep", "3600"]
      envFrom:
        - secretRef:
            name: plane-app-pgdb-secrets
"""

QUERY = "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit {limit};"


def ensure_pod(namespace: str, image: str) -> None:
    existing = subprocess.run(
        ["kubectl", "-n", namespace, "get", "pod", POD_NAME, "-o", "jsonpath={.status.phase}"],
        text=True,
        capture_output=True,
    )
    if existing.returncode == 0 and existing.stdout.strip() == "Running":
        print(f"[check_table_rows] reusing existing pod {POD_NAME} in {namespace}", file=sys.stderr)
        return

    manifest = POD_MANIFEST_TEMPLATE.format(pod_name=POD_NAME, namespace=namespace, image=image)
    print(f"[check_table_rows] creating pod {POD_NAME} in {namespace}", file=sys.stderr)
    subprocess.run(["kubectl", "apply", "-f", "-"], input=manifest, text=True, check=True)
    subprocess.run(
        ["kubectl", "-n", namespace, "wait", "--for=condition=Ready", f"pod/{POD_NAME}", "--timeout=60s"],
        check=True,
    )


def query_rows(namespace: str, limit: int) -> str:
    sql = QUERY.format(limit=limit)
    remote_script = (
        f'PGPASSWORD="$POSTGRES_PASSWORD" psql '
        f'-h "plane-app-pgdb.{namespace}.svc.cluster.local" '
        f'-U "$POSTGRES_USER" -d "$POSTGRES_DB" -tA -F"," -c "{sql}"'
    )
    result = subprocess.run(
        ["kubectl", "-n", namespace, "exec", POD_NAME, "--", "bash", "-c", remote_script],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        print(result.stderr, file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def cleanup_pod(namespace: str) -> None:
    subprocess.run(["kubectl", "-n", namespace, "delete", "pod", POD_NAME, "--ignore-not-found"], check=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("-n", "--namespace", default="plane-ce", help="namespace to query (default plane-ce)")
    parser.add_argument("--image", default="localhost:32000/plane-backup:latest", help="plane-backup image to run")
    parser.add_argument("--limit", type=int, default=30, help="max tables to show (default 30)")
    parser.add_argument("--cleanup", action="store_true", help="delete the debug pod after querying")
    args = parser.parse_args()

    ensure_pod(args.namespace, args.image)
    try:
        output = query_rows(args.namespace, args.limit)
    finally:
        if args.cleanup:
            cleanup_pod(args.namespace)

    rows = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        relname, n_live_tup = line.rsplit(",", 1)
        rows.append((relname, int(n_live_tup)))

    print(f"{'table':40s} rows")
    print("-" * 50)
    for relname, n in rows:
        print(f"{relname:40s} {n}")
    print("-" * 50)
    print(f"{'TOTAL':40s} {sum(n for _, n in rows)}")

    if not args.cleanup:
        print(
            f"\n(pod {POD_NAME} left running in {args.namespace} for reuse; "
            f"pass --cleanup to delete it, or `kubectl -n {args.namespace} delete pod {POD_NAME}` manually)",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
