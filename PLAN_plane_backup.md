# Plane CE Backup — Implementation Plan

> **Note:** This plan was originally drafted inside `task-tracker` for
> convenience (it could see the deployed `plane-ce` chart dump for
> reference) and has since been moved into its own `plane-backup` repo,
> which is now the permanent home for this capability's implementation
> (Dockerfile, scripts, k8s manifests).

## 1. Goal

Back up the two stateful components of the self-hosted Plane CE instance
(namespace `plane-ce`, Helm release `plane-app`, MicroK8s single node) to
Backblaze B2, on a schedule, in a form that can be restored into a **fresh**
Plane CE install without depending on the original node or its hostPath
volumes.

Components in scope:
- **Postgres** (`plane-app-pgdb-wl` StatefulSet) — all application data
- **MinIO** (`plane-app-minio-wl` StatefulSet) — file/attachment object store

Out of scope (confirmed in prior discussion): **Redis** — used for
cache/session/Celery broker/realtime state only, not durable data. Not backed
up. RabbitMQ likewise not backed up (message broker, no durable state worth
recovering — queues drain and repopulate from Postgres-backed workers).

## 2. Key facts (verify against the live cluster before implementing)

> These facts were gathered by reading a point-in-time dump of the `plane-ce`
> Helm chart (release `plane-app`, namespace `plane-ce`, single-node
> MicroK8s) that is **not** included alongside this plan. Treat everything
> in this section as "true as of the time this plan was written" rather than
> guaranteed — re-check with `kubectl get secret/svc -n plane-ce` and/or the
> live `helm get values plane-app -n plane-ce` before writing manifests
> against it, in case the chart version or values have since changed.

- Both Postgres and MinIO run as single-replica StatefulSets with
  `ReadWriteOnce` PVCs (`storageClassName: ""` → cluster default, which is
  MicroK8s's `hostpath-storage` — implicitly node-pinned to whichever node
  the PVC was first bound on).
- Chart image versions at time of writing: `postgres:15.7-alpine`,
  `minio/minio:latest`. **Match the backup image's `pg_dump`/`pg_restore`
  client to the server's major version (15)** — a mismatched major version
  can fail or silently produce an incompatible dump. Re-check the live
  version (`kubectl get statefulset plane-app-pgdb-wl -n plane-ce -o
  jsonpath='{.spec.template.spec.containers[0].image}'`) before pinning the
  client version in the Dockerfile.
- **No NetworkPolicy ships with this chart** — confirmed by scanning the
  chart's `templates/` directory for `networkpolicy`, none found. Any pod
  anywhere in
  the cluster can currently reach the Postgres and MinIO Services on their
  ClusterIPs. This means a backup CronJob does **not** need to run on the
  same node or mount the same PVCs — it can back up purely over the network
  (`pg_dump` against the Postgres service, `mc mirror` against the MinIO S3
  API). This avoids all hostPath/node-affinity/multi-attach complexity.
- Credentials already exist as k8s Secrets in `plane-ce`, created by the
  chart itself:
  - `plane-app-pgdb-secrets` → `POSTGRES_USER`, `POSTGRES_PASSWORD`,
    `POSTGRES_DB` (defaults: `plane` / `plane` / `plane`)
  - `plane-app-doc-store-secrets` → `MINIO_ROOT_USER` / `AWS_ACCESS_KEY_ID`,
    `MINIO_ROOT_PASSWORD` / `AWS_SECRET_ACCESS_KEY`, `AWS_S3_BUCKET_NAME`,
    `AWS_S3_ENDPOINT_URL` (`http://plane-app-minio:9000`)
  - The backup job can read these directly via `envFrom.secretRef` — no need
    to duplicate credentials into a new secret, which also means credential
    rotation in the Plane chart doesn't require touching the backup config.
- Service DNS names (in-cluster): `plane-app-pgdb.plane-ce.svc.cluster.local:5432`,
  `plane-app-minio.plane-ce.svc.cluster.local:9000`.

## 3. Backup mechanism

**Tool: [restic](https://restic.net/)**, repository backend = Backblaze B2
(restic has native `b2:bucket:path` support, no rclone layer needed).

Two logical objects get backed up per run, both landing as plain files on an
`emptyDir` before being handed to restic:

1. `pg_dump -Fc` (custom/compressed format, single-file, restorable with
   `pg_restore`, includes schema + data) → `/backup/postgres/plane.dump`
2. `mc mirror` of the MinIO bucket (using the existing S3 creds, endpoint
   `http://plane-app-minio.plane-ce.svc.cluster.local:9000`) →
   `/backup/minio/<bucket>/...`

Then: `restic backup /backup --tag plane-ce` in the same job, followed by
`restic forget --prune` with a retention policy (e.g. `--keep-daily 14
--keep-weekly 8 --keep-monthly 12`).

Why restic on top of raw dumps rather than just uploading dumps to B2
directly: dedup + compression across snapshots (MinIO objects don't change
much day to day, so incremental storage cost stays low), built-in encryption
at rest (repository password), and `restic check` for integrity verification
— all for free, versus hand-rolling versioning/retention against raw B2.

## 4. Secret bootstrap script

A script (e.g. `setup-backup-secret.sh`), run manually/locally whenever
credentials need (re)setting:

```bash
./setup-backup-secret.sh \
  --b2-account-id <id> \
  --b2-account-key <key> \
  --restic-password <password> \
  [--namespace plane-backup] \
  [--repo-path bucket-name:plane-ce]
```

Behavior:
- Validates all three values are non-empty (fail fast, no partial secret).
- Runs `kubectl create secret generic plane-backup-restic-creds \
  --from-literal=B2_ACCOUNT_ID=... \
  --from-literal=B2_ACCOUNT_KEY=... \
  --from-literal=RESTIC_PASSWORD=... \
  --from-literal=RESTIC_REPOSITORY=b2:<bucket>:<path> \
  --namespace <ns> --dry-run=client -o yaml | kubectl apply -f -`
  — the `dry-run | apply` idiom makes it idempotent (create-or-update) with
  no diffing logic needed.
- Does **not** echo the values back or log them.
- Prints a reminder to restart/re-trigger the CronJob if credentials were
  rotated mid-cycle (stale creds would otherwise just fail silently until
  next scheduled run — better to catch it immediately).
- Should live next to the k8s manifests for this backup capability, not in
  `task-tracker/scripts/`.

Secret name/namespace chosen so it's decoupled from the `plane-ce` chart's
own secrets (which get regenerated/overwritten by `helm upgrade`) — a
`helm upgrade` of `plane-app` must never be able to wipe backup credentials.

## 5. Kubernetes resources

Recommend a **new namespace**, e.g. `plane-backup`, rather than piggybacking
on `plane-ce` or `task-bot`:
- Keeps backup credentials (B2 keys, restic password) out of the blast
  radius of `helm upgrade plane-app`.
- Keeps it independent of `task-bot`'s lifecycle (task-bot itself is a
  Plane *client*; the backup job should survive task-bot being torn down
  for redeployment/debugging).

Resources needed:
1. `Namespace plane-backup`
2. `Secret plane-backup-restic-creds` (created by the script above, not by
   Helm/manifest — credentials never live in git)
3. A backup **container image**: restic + `mc` + `postgresql-client`
   (for `pg_dump`) + a small driver script. Simplest path: a minimal
   Dockerfile (`FROM restic/restic` won't have `mc`/`pg_dump`, so probably
   `FROM alpine`, install a `postgresql-client` package matching the
   server's major version (§2), download the `mc` and `restic` static
   binaries). Push to whatever registry the target cluster already pulls
   from — for this MicroK8s cluster that's its built-in local registry
   (`localhost:32000/plane-backup:latest`); a small multi-stage Dockerfile
   is fine given this only runs on a schedule, not latency-sensitive.
4. `CronJob plane-backup` in `plane-ce`-reachable network space (any
   namespace works, given no NetworkPolicy restricts ingress today — but if
   one is ever added to `plane-ce`, this job's namespace/labels will need an
   explicit allow rule)
   - `envFrom`: the new `plane-backup-restic-creds` Secret **and** the
     existing `plane-app-pgdb-secrets` / `plane-app-doc-store-secrets`
     Secrets — cross-namespace `secretRef` isn't possible in k8s, so
     **this requires the CronJob to run in `plane-ce` namespace itself**,
     or requires copying/mirroring those two secrets into `plane-backup`.
     → Decision needed: simplest is to run the CronJob in `plane-ce`
     (co-located with what it's backing up, consistent with how the chart's
     own `minio-bucket` Job already runs there) and rely on RBAC to scope
     what it can touch. Namespace isolation of the *B2/restic* credentials
     (the sensitive, exfil-worthy ones) is preserved by keeping just that
     one Secret separate.
   - Revised plan: **CronJob lives in `plane-ce`**, restic/B2 Secret is
     created in `plane-ce` too (simplifies wiring, still isolated from
     `helm upgrade plane-app` since it's not a chart-managed resource and
     Helm won't touch a Secret it doesn't own).
   - Schedule: nightly, e.g. `0 6 * * *` (adjust for timezone/quiet hours).
   - `concurrencyPolicy: Forbid` (don't overlap runs if one hangs).
   - `successfulJobsHistoryLimit` / `failedJobsHistoryLimit` small (e.g. 3/3).
   - Resource requests/limits modest (this is I/O-bound, not compute-bound).
5. `ServiceAccount` + RBAC: none needed beyond default — the job talks to
   Postgres/MinIO over their Service ClusterIPs using DB/S3 credentials, not
   the k8s API, so no special RBAC bindings required.

## 6. CronJob driver script (runs inside the container)

Pseudocode for the single script the CronJob invokes:

```bash
set -euo pipefail

mkdir -p /backup/postgres /backup/minio

# 1. Postgres dump
PGPASSWORD="$POSTGRES_PASSWORD" pg_dump \
  -h plane-app-pgdb.plane-ce.svc.cluster.local -p 5432 \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc \
  -f /backup/postgres/plane.dump

# 2. MinIO mirror
mc alias set planeminio "$AWS_S3_ENDPOINT_URL" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY"
mc mirror --overwrite planeminio/"$AWS_S3_BUCKET_NAME" /backup/minio/"$AWS_S3_BUCKET_NAME"

# 3. restic snapshot
export RESTIC_REPOSITORY B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
restic snapshots >/dev/null 2>&1 || restic init
restic backup /backup --tag plane-ce --host plane-ce-prod

# 4. prune
restic forget --tag plane-ce --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune

# 5. integrity check (cheap, metadata-only; full --read-data on a slower cadence — see §8)
restic check
```

Notes:
- `restic init` only fires once (first run creates the repo; subsequent runs
  find it already initialized). Safe to leave the guarded `init` in
  permanently.
- `--host plane-ce-prod` gives snapshots a stable identity independent of
  the pod's ephemeral hostname, so `restic snapshots` output stays readable
  across job restarts.
- Failure of any step (`set -e`) should fail the Job/CronJob run visibly in
  `kubectl get jobs` — see §9 for actually noticing that.

## 7. Restore procedure — `plane-restore` Job

Restore is implemented as a **k8s Job** (not a CronJob — one-shot, triggered
by hand: `kubectl create job --from=cronjob/plane-restore-template
plane-restore-$(date +%s) -n plane-ce`, or a plain `Job` manifest applied
directly), reusing the same container image as the backup CronJob (it
already has `restic`, `mc`, and `pg_dump`/`pg_restore`/`psql` in it).

The job is split into two phases that run as **separate containers in the
same pod, in order** — an `initContainer` for preflight, then the main
container for the actual restore. If the initContainer fails, the main
container never starts and **nothing is touched** — this is what gives the
fail-fast/no-partial-impact property, using a plain k8s primitive rather
than hand-rolled rollback logic.

### Phase 1 — preflight (`initContainer: plane-restore-preflight`)

Every check is read-only / non-mutating. Any failure = non-zero exit = Job
never proceeds to phase 2. All checks run before any single one is allowed
to abort early, so one `kubectl logs` shows the *complete* list of what's
missing, not just the first failure (an operator mid-incident doing three
rounds of "fix one thing, retry, discover the next missing thing" is exactly
the friction this is meant to avoid):

1. **B2 / restic reachable and repository valid.**
   `restic snapshots` succeeds and returns at least one snapshot for
   `--host plane-ce-prod` (catches: wrong/missing `RESTIC_PASSWORD`, bad B2
   keys, empty or not-yet-initialized repo, network egress to B2 blocked).
2. **Target snapshot resolvable.** If a specific snapshot ID/tag is
   requested via env/arg (default `latest`), confirm `restic snapshots`
   contains it — don't let restic fail this deep into the job.
3. **Postgres reachable and empty/expected-safe-to-restore-into.**
   `psql` connects using the target `POSTGRES_*` creds, and:
   - confirms the target database exists (i.e. the fresh `plane-app` chart
     install has already run its own init — this job never creates
     databases/roles, only restores into ones the chart already made), and
   - checks whether the `plane` schema already has data. If it's non-empty,
     **abort** unless an explicit `RESTORE_FORCE=1` env var/flag is set —
     this is the guard against silently clobbering a live, populated
     instance by pointing the job at the wrong target.
     **Implementation note (learned during testing):** this can't be a
     blanket row-count sum across all tables — Django/DRF/Celery framework
     tables (`auth_permission`, `django_content_type`, `django_migrations`,
     `instance_configurations`, `django_celery_beat_*`) are populated the
     instant migrations finish and can total 700+ rows before any real
     onboarding, which tripped the guard on a genuinely fresh test
     instance. It also can't rely on `pg_stat_user_tables.n_live_tup` at
     all — that's an autovacuum/ANALYZE-driven estimate, confirmed stale
     (reading as 0, or absent from the stats view entirely) for
     rarely-touched tables on a real production instance during testing,
     which could just as easily mask genuine content. The implemented fix
     (`image/queries/content_row_count.sql`) uses real `COUNT(*)` restricted
     to an evidence-derived excluded-table list, verified against both a
     real production instance and a simulated fresh instance.
4. **MinIO reachable and bucket exists.** `mc alias set` + `mc ls` against
   the target endpoint/bucket succeeds (catches: wrong endpoint, bucket not
   yet created by the target chart's `minio-bucket` Job, bad creds).
5. **Disk space check** on the scratch `emptyDir`/volume the job will
   restore into — compare available space to the size reported by
   `restic stats latest` so a giant snapshot doesn't fail messily halfway
   through a slow download.
6. Print a **plain-language summary** of what phase 2 is about to do
   (source snapshot ID/date, target Postgres host/db, target MinIO
   endpoint/bucket) before phase 2 starts — this is the operator's last
   chance to `kubectl delete job` if the target looks wrong, since phase 2
   runs unattended once it starts.

### Phase 2 — restore (`container: plane-restore`)

Only reached if every phase-1 check passed.

1. `restic restore <snapshot> --target /restore`
2. `pg_restore --clean --if-exists -h <target-pgdb-svc> -U "$POSTGRES_USER"
   -d "$POSTGRES_DB" /restore/postgres/plane.dump`
3. `mc mirror --overwrite /restore/minio/<bucket> targetminio/<bucket>`
4. Print a restore summary (snapshot id, row counts restored, object count
   mirrored) to the Job log for the operator to sanity-check.

### Operator steps around the Job

1. Stand up a **fresh** `plane-app` Helm release (new/recovered cluster),
   with `api`/`worker`/`web`/etc. deployments scaled to 0 (or restored into
   before first traffic) so nothing writes to Postgres/MinIO mid-restore.
2. Apply the restore Job (pointed at that install's Postgres/MinIO
   Services/creds via the same `envFrom secretRef` pattern as the backup
   CronJob).
3. Watch `kubectl logs -f job/plane-restore-... -n plane-ce` — preflight
   output appears first; a clean pass moves straight into phase 2.
4. On success, scale the Plane app deployments back up.
5. **Verify:** log into the restored Plane UI, confirm recent issues are
   present, open an issue with a known attachment and confirm the file
   downloads (this is the check that actually proves Postgres references
   and MinIO objects are consistent with each other — see §8 timing note).

Note on cross-environment restore: if the new instance's
`AWS_ACCESS_KEY_ID`/bucket name differ from the backed-up one (different
`plane-app-doc-store-secrets`), either reuse the original values at install
time via `--set minio.root_user=...` etc., or point the job's `mc` target
alias at whatever the new creds are — bucket *contents* (object keys) don't
encode the bucket name, so this is purely a destination-alias concern, not
a data-rewrite concern.

## 8. Consistency between Postgres and MinIO backups

The driver script runs `pg_dump` and `mc mirror` back-to-back in the same
job (§6), not on independent schedules — this bounds the skew between "what
Postgres thinks exists" and "what MinIO actually has" to the runtime of one
job (seconds to low minutes for a personal-scale instance), rather than
risking hours/days of drift from separately-scheduled backups. Not
transactionally perfect (a file uploaded between the two steps could be
referenced by Postgres but missing from that day's MinIO mirror, or
vice versa) but adequate for a personal system — flagged here so it's a
known, accepted gap rather than an oversight.

## 9. Monitoring / failure detection

A silently-failing nightly CronJob is worse than no backup (false
confidence). Options, cheapest first:
- Minimum viable: periodically (weekly) manually check
  `kubectl get cronjob plane-backup -n plane-ce` and `kubectl get jobs -n
  plane-ce` for recent failures.
- Better: if there's already an existing scheduled email/notification
  mechanism elsewhere (e.g. this operator runs a `task-tracker` project with
  its own daily digest CronJob and email-sending script — see that
  project's own docs/`digest.py` if so), extend it to also report the last
  backup job's status/timestamp, rather than building new notification
  infrastructure from scratch just for this. This is an explicit cross-repo
  integration point — whoever implements this plan needs to go find that
  mechanism (if it still exists) rather than expect it to be documented
  here.
- Best (later, optional): restic supports post-backup hooks; could `curl` a
  dead-man's-switch service (e.g. healthchecks.io) on success — flags
  *silence* (job didn't run at all) in addition to explicit failure.

## 10. Verification cadence

- `restic check` (metadata-only) every run (§6, cheap).
- `restic check --read-data-subset=5%` monthly — catches silent B2-side
  corruption without re-downloading the entire repository every night.
- Full restore drill (§7) at a longer cadence (e.g. quarterly) — the only
  real proof the backup is usable. Worth setting up whatever recurring
  reminder mechanism this operator normally uses (e.g. a recurring task in
  their own tracker, a calendar entry) once implemented — this plan doesn't
  prescribe a specific one.

## 11. Implementation checklist

- [x] Decide final home for this capability — this repo (`plane-backup`).
- [x] Write the backup container image (`image/Dockerfile`: alpine + restic
      + mc + postgresql15-client + `backup.sh`/`restore-preflight.sh`/
      `restore.sh` driver scripts). Builds clean; `pg_dump`/`pg_restore`
      client version (15.18) matches the assumed server major version (15)
      — still needs re-confirming against the live StatefulSet per §2.
- [x] Write `setup-backup-secret.sh` (repo root, alongside where the k8s
      manifests will live). Defaults `--namespace` to `plane-ce` per §5's
      revised decision. Validated: fails fast with no partial secret when
      required args are missing, and the `create --dry-run=client -o yaml |
      apply` idempotent pattern was exercised against a stub `kubectl`.
- [x] Write k8s manifests (`manifests/cronjob.yaml`, `manifests/restore-job.yaml`;
      Secret is intentionally not a committed manifest — created only by
      `setup-backup-secret.sh`). No RBAC needed (plan §5.5: the jobs talk to
      Postgres/MinIO via Service ClusterIPs + creds, not the k8s API).
      `restore-job.yaml` is a template — copied and edited per restore
      attempt (`generateName`, not a fixed name), matching the plan's "plain
      Job manifest applied directly" option from §7 rather than the
      `--from=cronjob` trick, since a Job needs no CronJob wrapper to serve
      as a reusable template. Structurally validated (YAML parses, secretRefs
      match, preflight/restore SNAPSHOT_ID stay in sync) but **not yet
      applied against a real cluster** — no kubectl/cluster access from this
      environment.
- [ ] Create the B2 bucket + application key (scoped to that bucket only,
      not a master key) in the Backblaze console.
- [ ] Run `setup-backup-secret.sh` once to bootstrap.
- [ ] Trigger the CronJob manually (`kubectl create job --from=cronjob/...`)
      and confirm a restic snapshot lands in B2.
- [ ] Write the `plane-restore` Job manifest, including the preflight
      `initContainer` (§7) and its driver script.
- [ ] Do one full restore drill against a scratch namespace/cluster,
      including deliberately running it once against a *non-empty* target
      DB to confirm the preflight guard (§7, step 3) actually blocks it,
      before trusting either the backup schedule or the restore path.
- [ ] Wire failure visibility into the digest email (§9), or set a minimum
      manual-check cadence if deferring that.
