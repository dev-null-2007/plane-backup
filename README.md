# plane-backup

Backup and restore for a self-hosted Plane CE instance's Postgres database
and MinIO object store, using [restic](https://restic.net/) against
Backblaze B2. Full design rationale lives in
[`PLAN_plane_backup.md`](PLAN_plane_backup.md) — this README is the
operational how-to. See [`CLAUDE.md`](CLAUDE.md) for a repo-structure
summary if you're working on the code itself.

## Prerequisites

- `kubectl` access to the target cluster/namespace(s).
- `docker` (or another OCI builder) and push access to a registry the
  cluster can pull from. Examples below use MicroK8s's built-in registry,
  `localhost:32000`.
- A Backblaze B2 bucket and an application key scoped to just that bucket
  (not a master key). Create these in the B2 console before starting.

## 1. Build and push the backup/restore image

The same image is used for both the backup CronJob and the restore Job — it
bundles `restic`, `mc`, and `pg_dump`/`pg_restore`/`psql` (client major
version 15, matching the assumed Postgres server version — see
`image/Dockerfile`'s header comment and re-check against your live
StatefulSet if you're not sure).

```bash
cd image
docker build -t localhost:32000/plane-backup:latest .
docker push localhost:32000/plane-backup:latest
```

If your registry isn't `localhost:32000`, use that tag instead, and update
the `image:` field in `manifests/cronjob.yaml` and `manifests/restore-job.yaml`
to match.

## 2. Bootstrap the B2/restic credentials Secret

Run this once (and again any time you need to rotate credentials). It
creates/updates a Secret named `plane-backup-restic-creds` in the target
namespace — by default `plane-ce`, since the backup CronJob and restore Job
both run there and read it via `envFrom.secretRef`.

```bash
./setup-backup-secret.sh \
  --b2-account-id <your-b2-account-id> \
  --b2-account-key <your-b2-application-key> \
  --restic-password <a-strong-password-you-generate-and-save-elsewhere> \
  --b2-bucket <your-b2-bucket-name> \
  [--repo-path plane-ce] \
  [--namespace plane-ce]
```

- `--restic-password` encrypts the restic repository. **Save it somewhere
  durable outside this cluster** (password manager, etc.) — losing it makes
  every backup unreadable, including by you.
- `--repo-path` namespaces the restic repository within the bucket
  (`b2:<bucket>:<repo-path>`). Defaults to `plane-ce`; only relevant if
  you're backing up multiple things into the same bucket.
- The script fails fast (no secret written at all) if any required value is
  missing, and never prints the credential values itself.
- If you rotate credentials mid-cycle and want the new ones to take effect
  immediately rather than waiting for the next scheduled run, the script
  prints a ready-to-run `kubectl create job --from=cronjob/plane-backup ...`
  command at the end.

## 3. Deploy the nightly backup CronJob

```bash
kubectl apply -f manifests/cronjob.yaml
```

Runs nightly at `0 6 * * *` (edit the `schedule` field in the manifest to
change). It reads:
- `plane-backup-restic-creds` (from step 2)
- `plane-app-pgdb-secrets` and `plane-app-doc-store-secrets` (already
  present in `plane-ce`, created by the Plane Helm chart itself — nothing
  to do here)

## 4. Trigger a backup manually

Don't wait for 6am to find out something's wrong. Trigger one run right
after deploying:

```bash
kubectl create job --from=cronjob/plane-backup plane-backup-manual-$(date +%s) -n plane-ce
kubectl get jobs -n plane-ce -w
kubectl logs -f job/plane-backup-manual-<timestamp> -n plane-ce
```

A successful run logs each step (`pg_dump`, `mc mirror`, `restic backup`,
`restic forget --prune`, `restic check`) and ends with `[backup] done`.

## 5. Verify a backup landed

From anywhere with the same restic env vars (e.g. `kubectl exec` into a
running/completed backup pod, or run the image locally with the B2
credentials exported):

```bash
restic snapshots --host plane-ce-prod
```

You should see at least one snapshot tagged `plane-ce`.

## 6. Restore

Restores are a **copy-and-edit template**, not a fixed manifest — you edit
`manifests/restore-job.yaml` per attempt and apply the copy. This is
deliberate: it forces you to consciously choose the target snapshot and
target instance instead of accidentally re-running a stale restore. Read the
comment block at the top of that file too.

The restore Job runs an `initContainer` (`restore-preflight.sh`) that does
several **read-only** checks — restic repo reachable, target snapshot
exists, target Postgres reachable and either empty or `RESTORE_FORCE=1`,
target MinIO bucket exists, enough scratch disk space — and prints a
plain-language summary of what it's about to do. If any check fails, the
main `restore` container never starts and **nothing is touched**.

### Restoring into the same instance (e.g. after a disaster, fresh reinstall)

1. Reinstall the `plane-app` Helm chart fresh (so Postgres/MinIO exist and
   are initialized, but empty). Scale `api`/`worker`/`web`/etc. to 0 so
   nothing writes mid-restore.
2. Copy and apply the template:
   ```bash
   cp manifests/restore-job.yaml /tmp/plane-restore.yaml
   $EDITOR /tmp/plane-restore.yaml   # set SNAPSHOT_ID (or leave "latest")
   kubectl create -f /tmp/plane-restore.yaml
   ```
3. Watch it:
   ```bash
   kubectl get jobs -n plane-ce -w
   kubectl logs -f job/<generated-name> -n plane-ce -c preflight
   kubectl logs -f job/<generated-name> -n plane-ce -c restore
   ```
4. On success, scale the Plane app deployments back up.
5. **Verify in the UI**: log in, confirm recent issues are present, open an
   issue with a known attachment and confirm the file downloads (this is
   what actually proves Postgres and MinIO ended up consistent with each
   other).

### Restoring into a secondary/arbitrary instance (e.g. a test restore drill)

This is the useful path for proving the backup is actually usable without
touching production. `POSTGRES_HOST` and `AWS_S3_ENDPOINT_URL` both default
to *whatever namespace the pod is actually running in* (via the Downward
API `POD_NAMESPACE` env var wired into `manifests/restore-job.yaml`), so a
same-cluster restore into a different namespace needs no manual host
overrides — just point the Job at that namespace.

1. **Stand up the secondary Plane CE instance** (different namespace, e.g.
   `plane-ce-test`, or a different cluster entirely) via its own
   `plane-app` Helm install, scaled to 0 before restoring into it. This Job
   never creates databases, roles, or buckets — the target chart's own init
   must have already run.

2. **Make the restic/B2 credentials available to that namespace.** Secrets
   don't cross namespaces, so re-run the bootstrap script pointed at the
   *same* B2 bucket/repo-path but the *new* namespace:
   ```bash
   ./setup-backup-secret.sh \
     --b2-account-id <same-as-before> \
     --b2-account-key <same-as-before> \
     --restic-password <same-as-before> \
     --b2-bucket <same-bucket> \
     --repo-path plane-ce \
     --namespace plane-ce-test
   ```
   (Same restic password and repo-path as the original — you're reading the
   *same* repository, just from a different namespace/pod.)

3. **Copy the template and point it at the secondary instance:**
   ```bash
   cp manifests/restore-job.yaml /tmp/plane-restore-test.yaml
   ```
   Edit `/tmp/plane-restore-test.yaml`:
   - `metadata.namespace: plane-ce-test` — that's it for host targeting.
     `POD_NAMESPACE` (Downward API) automatically becomes `plane-ce-test`
     for both containers, so `POSTGRES_HOST` resolves to
     `plane-app-pgdb.plane-ce-test.svc.cluster.local` with no manual edit.
     `AWS_S3_ENDPOINT_URL` always comes straight from that namespace's own
     `plane-app-doc-store-secrets`, so it's correct automatically too.
   - Set `SNAPSHOT_ID` (same value in both the `preflight` initContainer and
     the `restore` container).
   - If the secondary instance is in a **different cluster** (not just a
     different namespace in the same cluster), its DNS domain may not be
     `svc.cluster.local`, or the Postgres/MinIO service names may differ.
     In that case add explicit `POSTGRES_HOST` / `AWS_S3_ENDPOINT_URL`
     overrides to **both** containers' `env:` lists instead of relying on
     the computed default.
   - Credentials (`POSTGRES_USER/PASSWORD/DB`, `AWS_ACCESS_KEY_ID/SECRET_ACCESS_KEY/S3_BUCKET_NAME`)
     still come from that namespace's own `plane-app-pgdb-secrets` /
     `plane-app-doc-store-secrets` via `envFrom` — no changes needed there,
     since Helm creates fresh ones per install.

4. **Apply and watch, same as above**, but note the preflight's non-empty-database
   guard will matter here: a truly fresh secondary install should pass the
   emptiness check without `RESTORE_FORCE`. If you want to specifically
   test that the guard *blocks* a bad restore, seed the secondary instance
   with a throwaway issue or two first and confirm the preflight refuses to
   proceed without `RESTORE_FORCE: "1"` — this is worth doing at least once
   before trusting the guard in a real incident.

5. **Verify** in the secondary instance's UI, same checklist as above (recent
   issues present, an attachment downloads).

### Restoring a specific (non-latest) snapshot

```bash
restic snapshots --host plane-ce-prod   # find the short ID you want
```

Set `SNAPSHOT_ID` in both containers of the copied Job manifest to that ID
instead of `latest`.

## Troubleshooting

- **Preflight fails with a list of problems**: that's the point — it
  collects every failing check before exiting so you see the whole picture
  in one `kubectl logs`, rather than fixing one thing at a time. Fix all
  listed items and re-apply a fresh copy of the Job (Jobs aren't
  re-runnable in place — `kubectl create -f` a new copy from the template).
- **CronJob shows no recent successful runs**: `kubectl get cronjob
  plane-backup -n plane-ce` and `kubectl get jobs -n plane-ce` — check
  `failedJobsHistoryLimit`-worth of recent failed Job logs.
- **`restic snapshots` returns nothing at all**: either the repository was
  never initialized (first backup run does this automatically) or the B2
  credentials/bucket in the Secret are wrong — re-run
  `setup-backup-secret.sh` with correct values.
- **Preflight's "target database already has data" check trips on a
  supposedly-empty instance**: as of `image/queries/content_row_count.sql`,
  it counts real `COUNT(*)` rows in content tables only, excluding known
  Django/DRF/Celery framework and Plane instance-config tables
  (`auth_permission`, `django_content_type`, `django_migrations`,
  `instance_configurations`, `django_celery_beat_*`, etc.) that are
  populated the instant migrations finish, before any real onboarding
  happens — those alone can total 700+ rows on a genuinely empty instance.
  If this still trips unexpectedly (e.g. after a Plane/chart upgrade
  introduces a new framework table not on that excluded list), run
  `./scripts/check_table_rows.py -n <namespace>` (needs only `kubectl` and
  `python3` — no local SQL client) to see the per-table breakdown, and
  extend the excluded-table list in `content_row_count.sql` if a new
  framework table needs adding.
