# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository state

Implementation is in progress. `image/` has the backup/restore container image and its three driver scripts; `setup-backup-secret.sh` (repo root) creates/rotates the B2/restic credentials Secret. The k8s manifests (Namespace, Secret, CronJob, restore Job) are not yet written — see §11 of `PLAN_plane_backup.md` for the live checklist.

### Building and testing the image

```bash
cd image
docker build -t plane-backup:test .
docker run --rm plane-backup:test sh -c 'restic version; pg_dump --version; mc --version'
```

There's no k8s cluster access from this environment, so the CronJob/Job manifests and the scripts' behavior against real Postgres/MinIO/B2 endpoints are unverified — they need a real test run against the cluster (or a scratch namespace) before being trusted. `bash -n <script>.sh` is a fast local syntax check for the driver scripts in `image/`.

The plan document itself notes it was originally drafted for convenience inside another project (`task-tracker`, which has visibility into the deployed `plane-ce` Helm chart) and has since been moved into this repo, `plane-backup`, which is its permanent home — the Dockerfile, scripts, and k8s manifests described below belong directly in this repo, not in `task-tracker` or elsewhere.

## What this project is

A backup/restore capability for a self-hosted **Plane CE** instance (namespace `plane-ce`, Helm release `plane-app`, single-node MicroK8s), backing up to Backblaze B2 via **restic**. Full design detail — read `PLAN_plane_backup.md` before implementing anything, it is the source of truth — but the shape is:

- **In scope for backup:** Postgres (`plane-app-pgdb-wl` StatefulSet, all app data) and MinIO (`plane-app-minio-wl` StatefulSet, file/attachment object store).
- **Out of scope:** Redis and RabbitMQ — no durable state worth recovering (cache/session/broker only).
- **Backup mechanism:** a k8s CronJob runs `pg_dump -Fc` and `mc mirror` into a shared scratch volume, then `restic backup` that volume to a B2 repository, then `restic forget --prune` for retention. Postgres and MinIO are dumped back-to-back in the same job run (not on independent schedules) to bound skew between what Postgres references and what MinIO actually has (§8 of the plan).
- **Restore mechanism:** a one-shot k8s Job with a fail-fast preflight `initContainer` (checks B2/restic reachability, target snapshot exists, target Postgres is reachable and not already populated unless `RESTORE_FORCE=1`, target MinIO bucket exists, sufficient disk space) followed by a main container that actually restores. If any preflight check fails, the main container never starts — no partial-impact restores.
- **Credentials:** the backup CronJob reads existing Plane-chart-managed secrets (`plane-app-pgdb-secrets`, `plane-app-doc-store-secrets`) directly via `envFrom.secretRef` rather than duplicating them. The B2/restic credentials live in a separate `plane-backup-restic-creds` Secret, created only via a bootstrap script (`setup-backup-secret.sh`, not yet written) — never committed to git, and deliberately not owned by Helm so a `helm upgrade plane-app` can never touch or wipe it.
- **Namespace placement:** the CronJob and its restic Secret run in `plane-ce` itself (not a separate `plane-backup` namespace) — this was a deliberate revision in the plan (§5) because cross-namespace `secretRef` isn't possible in k8s, and co-locating avoids mirroring the Plane chart's own secrets elsewhere.

## Key facts about the target cluster (verify before implementing — see plan §2)

These were gathered from a point-in-time dump of the `plane-ce` Helm chart and may drift:

- Both Postgres and MinIO are single-replica StatefulSets with `ReadWriteOnce` hostpath-backed PVCs, implicitly node-pinned — but no NetworkPolicy ships with the chart, so the backup/restore jobs can operate purely over the network (Service ClusterIPs) without needing to run on the same node or mount the same volumes.
- In-cluster DNS: `plane-app-pgdb.plane-ce.svc.cluster.local:5432`, `plane-app-minio.plane-ce.svc.cluster.local:9000`.
- Postgres image is `postgres:15.7-alpine` at time of writing — the backup image's `pg_dump`/`pg_restore` client major version must match the live server's major version; re-check `kubectl get statefulset plane-app-pgdb-wl -n plane-ce -o jsonpath='{.spec.template.spec.containers[0].image}'` rather than trusting this file.

## Working conventions for this repo

- Treat `PLAN_plane_backup.md` §2's cluster facts as "true when written," not guaranteed — re-verify against the live cluster (`kubectl`, `helm get values`) before writing manifests that depend on them.
- Never commit actual B2 keys or the restic repository password. They only ever go into the cluster via `setup-backup-secret.sh` (or its equivalent once written) run manually.
- The plan's implementation checklist (§11) is the current task list for this repo until it's superseded by real code/manifests.
