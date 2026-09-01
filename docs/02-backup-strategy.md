# 02 — Backup Strategy

Built on the facts confirmed in [01 — Discovery Baseline](01-discovery-baseline.md).

**What we're aiming for:**
> If the server dies: get a fresh Ubuntu server → install the matching K3s version → restore our
> backup → bring the apps and data back → check everything actually works.

**How we get there: two jobs. Nothing else runs on a schedule.**

| | Job 1 — K3s server backup | Job 2 — Velero |
|---|---|---|
| Runs where | systemd timer on `k3-master` | Inside the cluster |
| Runs when | 02:15 UTC daily | 03:00 UTC daily (+ 04:00 Sunday) |
| Backs up | The SQLite datastore, the cluster's identity, and the config K3s starts with | Every Kubernetes object in every namespace, plus all PVC data |
| Restores | **This server**, rebuilt from bare metal | **Any cluster** — object-level, portable across K3s versions |
| Lands in | `s3://k3-master-dr/k3s/` | `s3://k3-master-dr/velero/` |

They overlap a little, and that's deliberate — the overlap is the fallback, not waste. Job 1 alone
can rebuild this exact server. Job 2 alone can rebuild the workloads anywhere, and it's the only
thing that brings PVC data back.

> **This document replaces an earlier plan** built around three "tracks", nine components and seven
> S3 folders. Everything genuinely needed for a restore survived the simplification; §7 lists what
> was dropped and why.

---

## 1. The thing to understand before anything else

> ### `/etc/rancher/k3s` is just a config file. It is **not** the cluster's identity.

K3s keeps the entire identity of the cluster — its certificate authority, its keys, its token —
inside one folder: `/var/lib/rancher/k3s/server/`.

| Folder | What's inside | What happens if we lose it |
|-----------|----------|---------------------|
| `server/tls/` | The cluster CA + every certificate issued from it | A restored server isn't trusted by anything that used to connect to it. Every kubeconfig and every node join breaks. |
| `server/cred/` | Join credentials, and `encryption-config.json` if secret encryption is on | Without it the cluster identity has to be rebuilt from zero — and if secret encryption is on, every Secret in the restored database is unreadable. |
| `server/token` | The key K3s derives everything else from | A restored `state.db` with the wrong token will not start. |

**Rule:** `db/`, `tls/`, `cred/`, `token` and `manifests/` travel together, always. Job 1 backs
them up as one archive plus one database file, into one folder, for exactly this reason.

---

## 2. Where it all goes

One bucket. Two folders. That's the whole layout.

```text
s3://k3-master-dr/
├── k3s/
│   ├── daily/YYYY-MM-DD/     job 1 writes here every day
│   └── weekly/YYYY-MM-DD/    job 1 writes here on Sundays too
└── velero/                   Velero owns this — we never touch it by hand
```

Each `k3s/` folder holds one complete, self-contained restore set:

```text
state.db              the datastore
k3s-identity.tar.gz   tls/ cred/ token manifests/ /etc/rancher/k3s + the systemd unit
node-config.tar.gz    the host's own settings (network, firewall, ssh, packages)
MANIFEST.json         K3s version, OS version, and the SHA-256 of each file above
*.sha256              one per file
```

### Bucket security — not optional

A Velero backup contains real, readable Kubernetes Secrets, and `k3s-identity.tar.gz` contains the
cluster CA. **This bucket is a more valuable target than the server it protects.**

- **Default encryption on, from the moment the bucket is created**, using our own dedicated KMS
  key — not the shared AWS default. Encryption is not retroactive; anything uploaded before it was
  turned on stays unencrypted.
- **Block all public access.**
- **Versioning on.** The cheapest protection there is against a bad backup overwriting a good one.
- **Two separate logins**, below.

| Login | Can do | Lives |
|-------|--------|-------|
| **Backup writer** | `PutObject`, `GetObject`, `AbortMultipartUpload` across the bucket; `ListBucket` on the bucket; **`DeleteObject` on `velero/*` only**; `kms:GenerateDataKey` + `kms:Decrypt` on our one key | On the server in `/etc/k3s-backup/backup.env` (0600), and as a Secret in the `velero` namespace |
| **Restore reader** | `GetObject`, `ListBucket`, `kms:Decrypt` | Offline, in the password manager. **Never on the server** — if the server is compromised, the backups must not be. |

> ### Two permissions people get wrong
>
> **Velero needs `s3:DeleteObject`.** TTL expiry *is* Velero deleting its own objects. Without it,
> nothing ever expires and the retention policy below is fiction. Scope the delete to `velero/*` so
> the server still cannot delete a single K3s artifact.
>
> **The writer needs `kms:Decrypt`.** Any file over 8 MB uploads as a *multipart* upload, and
> multipart to a KMS-encrypted bucket requires Decrypt as well as GenerateDataKey. `state.db` is
> ~64 MB, so a policy that looks correctly write-only fails on the first real backup — and passes
> every small test file you try it with. Test with a 64 MB file. See [#21](../../../issues/21).

---

## 3. Job 1 — the K3s server backup

Script: [`scripts/k3s-server-backup.sh`](../scripts/k3s-server-backup.sh).
Schedule: [`scripts/systemd/k3s-backup.timer`](../scripts/systemd/k3s-backup.timer).

Everything in this table is load-bearing. Nothing here is optional except the last row.

| What | How it's captured | Why a restore fails without it |
|------|-------------------|--------------------------------|
| `server/db/state.db` | SQLite **online backup API** via Python, on a read-only connection → one consistent file | It *is* the cluster state. A plain `cp` of a live WAL database can copy a torn page and restore into a corrupt cluster. |
| `server/tls/` | tar | The cluster CA and every cert issued from it. |
| `server/cred/` | tar | Join credentials + the secret-encryption key if that's enabled. |
| `server/token` | tar, permissions preserved (`0600 root:root`) | K3s unlocks bootstrap data in the datastore with it. |
| `server/manifests/` | tar | The bundled add-ons — including `traefik-helmchartconfig.yaml`, which someone edited by hand and which cannot be regenerated. |
| `/etc/rancher/k3s/` | tar | `registries.yaml` holds our registry mirrors and pull credentials — images won't pull without it. |
| `/etc/systemd/system/k3s.service` (+ `.env`) | tar | The server's start flags: `--tls-san`, disabled components, node labels. Reinstalling with defaults silently produces a *different* cluster. |
| `MANIFEST.json` | Generated each run | Records the exact K3s version to install. Nothing else in the backup does: `uname` is the kernel, and K3s isn't a dpkg package. Restoring at the wrong version is the most common self-inflicted restore failure. |
| Host OS config | tar — network, firewall, SSH, timezone, package list | *Optional* (`INCLUDE_NODE_CONFIG=0` to skip). Not needed to bring K3s back, but it's the difference between restore step 2 being a file extraction and being reconstruction from memory during an outage. ~1 MB, same job, same folder. |

### What Job 1 deliberately does not back up

| | Size | Why |
|---|---|---|
| `state.db-wal`, `state.db-shm` | ~27 MB | The online backup already folds the WAL in. Copying stale sidecar files over a restored database is **actively harmful** — delete them at restore time. |
| `/var/lib/rancher/k3s/agent/` | ~43 GB | Container image cache. Re-pulled from the registries in `registries.yaml`. |
| `/var/lib/rancher/k3s/data/` | ~233 MB | K3s's own extracted binaries. The installer recreates them. |

Backing up the first two would multiply our storage and runtime by ~500× for nothing.

---

## 4. Job 2 — Velero

Install: [`scripts/velero/install-velero.sh`](../scripts/velero/install-velero.sh).
Schedules: [`schedule-daily.yaml`](../scripts/velero/schedule-daily.yaml),
[`schedule-weekly.yaml`](../scripts/velero/schedule-weekly.yaml).

| Covered | How |
|---------|-----|
| Every namespaced object in every namespace — Deployments, Services, ConfigMaps, **Secrets**, Ingress, Traefik IngressRoute/Middleware, ArgoCD Applications and AppProjects, monitoring CRs | Default scope. **No include/exclude list to maintain** — a new namespace can never appear unprotected. |
| Cluster-scoped objects — CRDs, ClusterRoles, ClusterRoleBindings, StorageClass, PVs | `includeClusterResources: true` |
| All six monitoring PVCs — Prometheus, Loki, MinIO, Loki write/backend, Grafana, Alertmanager | node-agent **file-system backup**, `defaultVolumesToFsBackup: true` |

### Why PVC data has to go through Velero

> **Copying `/var/lib/rancher/k3s/storage/` does not work as a backup.**

`local-path-provisioner` names each volume directory after a randomly generated ID. Restore a PVC
and it gets a **brand new** ID and directory — so a copied folder has nowhere matching to land.
Velero's node-agent restores the files *after* the new volume exists and tracks which files belong
where. That's the whole reason this job exists in this shape.

It matters more than it sounds. Our StorageClass reclaim policy is **`Delete`** (confirmed in
[01 §9](01-discovery-baseline.md)): the moment someone deletes a PVC, the files on disk are gone
immediately. No grace period, no orphan, no recycle bin. **Velero is the only thing standing
between an accidental `kubectl delete pvc` and permanent loss.**

Use `defaultVolumesToFsBackup: true` rather than annotating pods one at a time. Opt *out* per pod
if something ever needs excluding — never opt in, or a new PVC ships silently unprotected.

---

## 5. Schedule

| Time (UTC) | What runs | Configured in |
|---|---|---|
| 02:15 daily | Job 1. On Sundays it uploads the same files a second time under `k3s/weekly/`. | `k3s-backup.timer` |
| 03:00 daily | Job 2, daily tier | `Schedule/daily`, `ttl: 168h` |
| 04:00 Sunday | Job 2, weekly tier | `Schedule/weekly`, `ttl: 720h` |

The 45-minute gap keeps Velero's node-agent off the disk while the SQLite reader is running, and
the Sunday runs are staggered so the weekly Velero backup never overlaps the daily one.

**Why daily and not more often.** There is no application database in this cluster
([01 §12](01-discovery-baseline.md)) and SBE/COW are redeployed from Git, so a six-hour rewind of
the K3s datastore buys very little. The datastore's real risk is total loss, not a six-hour gap.
Daily is the honest requirement; four runs a day was four times the objects and four times the
failure surface for a window nobody asked for.

---

## 6. Retention — 7 daily + 4 weekly

Expressed twice: as S3 lifecycle rules for Job 1, as Velero TTL for Job 2.

**Our backup script never deletes anything**, and the credential it uses has no delete permission
on `k3s/*` at all — expiry there is entirely S3's job. Velero is the one exception, and it has to
be: TTL expiry *is* Velero deleting its own objects, which is why the credential grants
`s3:DeleteObject` on `velero/*` and nowhere else ([§2](#bucket-security--not-optional)).

| Location | Written | Expiry mechanism | Keeps |
|----------|---------|------------------|-------|
| `k3s/daily/` | Daily | S3 lifecycle — expire **8 days** after creation | 7–8 restore points |
| `k3s/weekly/` | Sundays | S3 lifecycle — expire **31 days** after creation | 4–5 restore points |
| `velero/` daily | Daily | Velero `ttl: 168h` | 7 backups |
| `velero/` weekly | Sundays | Velero `ttl: 720h` | 4 backups |

> ### Never put an S3 lifecycle rule on `velero/`
>
> Velero's file-system backups live in a Kopia repository whose objects reference each other. An S3
> expiry rule will delete chunks that a still-valid backup depends on, and the corruption only
> surfaces when you try to restore. Lifecycle rules apply to `k3s/` **only**. If you want a safety
> net on `velero/`, use a *noncurrent version* expiry, never a current-version one.

Two prefixes exist under `k3s/` for one reason: an S3 lifecycle rule can only say *"expire N days
after creation"*, so anything kept for a different length of time needs its own prefix. Job 1 knows
whether it's Sunday, so it just uploads the same files twice that day.

**Why no monthly tier.** Restoring three-month-old cluster state restores a cluster nobody wants
back — by then every workload has moved on. For a K3s datastore the realistic recovery window is
days. 7 + 4 covers "yesterday broke" and "it broke a while ago and nobody noticed."

**Cost:** roughly 1 GB for `k3s/` plus 10–15 GB for Velero once Kopia deduplicates the monitoring
volumes. Single-digit dollars a month. Retention here is about the bucket staying comprehensible,
not about the bill.

---

## 7. What we removed from the earlier plan

Nothing below was needed to restore the cluster safely.

| Was in the plan | Now | Why |
|---|---|---|
| Track A / B / C, 9 numbered components | **Removed** | Vocabulary, not coverage. Two jobs describe the same system and one engineer can hold it in their head. |
| 6-hourly datastore snapshots | **Removed** | 4× the runs and objects for a window nobody needs — see §5. |
| `cluster-state/db/{6hourly,daily}` tiers | **Replaced** | Same trick (one prefix per retention period), now serving the actual retention target. |
| Separate `cluster-state/`, `config/`, `manifests/`, `server-identity/` prefixes | **Folded into one** | Four prefixes for files that are always restored together. One archive, one folder, nothing to correlate during an outage. |
| `run-manifests/` prefix + its 365-day rule | **Folded in** | The *information* is required and kept — as `MANIFEST.json` inside each day's folder, where it can neither outlive nor predecease the files it describes. The separate prefix and its "must expire last" rule are gone, and with them the `pairs_with_full_run` field: one run per day means one folder holds the whole set. |
| `image-manifest/` job | **Removed** | Velero stores every workload spec and each spec names its image; `registries.yaml` is in Job 1. It re-derived data both jobs already hold. |
| Daily `node-config/` job and prefix | **Folded into Job 1** | Real value, wrong shape — it changes maybe twice a year. Same job, same folder, no separate schedule or retention rule. Set `INCLUDE_NODE_CONFIG=0` to drop it entirely. Closes gaps 3 and 4. |
| Daily `argocd admin export` | **Removed** | Velero backs up the whole `argocd` namespace including Secrets, Applications and AppProjects; Git holds the app definitions. Verify this once during the restore test, then let it go. Settles [#20](../../../issues/20). |
| Monthly tier, 90-day and 365-day rules | **Removed** | See §6. |

Kept, deliberately: the SHA-256 per artifact (three lines of script; turns a corrupt upload into a
loud failure now rather than a silent one mid-outage), the offline restore-only credential, and the
quarterly restore test.

---

## 8. Knowing it works

**A backup nobody watches fails silently for months.** We already run
Prometheus/Grafana/Alertmanager — reuse it rather than adding a tool.

| What | Why |
|------|-----|
| Alert on the **age of the newest object** under `k3s/daily/` | Proves the backup *arrived*, rather than trusting the script's opinion of itself. This is the alert that matters. |
| Alert on Velero's `velero_backup_last_successful_timestamp` | Velero exports it natively; no extra plumbing. |
| Threshold: 1.5× the interval (so ~36 hours) | Long enough to survive one missed run, short enough to notice. |
| SHA-256 verified locally before every upload | A corrupted artifact fails now, not during a restore. |
| **Full restore test every 3 months** | See the [restore runbook](03-restore-runbook.md). *A backup that has never been restored is a hope, not a plan.* |

The script also writes a node-exporter textfile metric if that directory exists. Treat it as a
bonus, not the alert — we never confirmed anything reads it ([#22](../../../issues/22)).

---

## 9. Gaps that still need validating

The design is only as good as these answers. The first three are **blocking**.

| # | Gap | Why it blocks | Issue |
|---|-----|---------------|-------|
| 1 | **Where Traefik's TLS certificates come from.** No cert-manager was found. If Traefik issues them itself and keeps `acme.json` in an `emptyDir`, **nothing here backs it up** and a restore comes back with broken HTTPS and no warning. | If it's a Secret, Velero already covers it and this closes. If it's ephemeral, either move it to a PVC or document re-issuance as a restore step. | [#4](../../../issues/4) |
| 2 | **Velero node-agent vs. K3s's kubelet root.** File-system backup reads pod volumes through a hostPath into the kubelet root directory, and K3s does not always use the stock `/var/lib/kubelet`. A mismatch starts cleanly and backs up **nothing** — it looks like an empty backup, not an error. | Confirm the path, then prove it: `velero backup describe <name> --details` must list all six PVCs under *Pod Volume Backups*. | [#11](../../../issues/11) |
| 3 | **Nothing has ever been restored.** Both flows in the runbook are unproven, and the RTO is an estimate. | Run the full flow once on a throwaway host and the PVC flow once against a scratch namespace. | [#12](../../../issues/12) |
| 4 | **Crash-consistency of the Prometheus / Loki / MinIO volumes.** File-system backup of a running TSDB is crash-consistent, not application-consistent. Prometheus usually replays its WAL fine; MinIO and Loki's boltdb-shipper are less forgiving. | Verify each restored pod reaches Ready with pre-incident data queryable. Add a Velero pre-backup hook **only if** the test shows you need one. | [#12](../../../issues/12) |
| 5 | **Is K3s encrypting Secrets in its own database?** (`k3s secrets-encrypt status`) | Either answer is fine — `cred/` is backed up regardless. But if it's on, restoring `cred/encryption-config.json` becomes a hard precondition before starting K3s. | [#22](../../../issues/22) |
| 6 | **Backup-arrived alerting isn't wired up yet.** | Until §8 exists, a silently broken backup stays silent. | [#2](../../../issues/2) |
| 7 | **Single region, single bucket.** Reasonable for one server with no failover — but it should be a decision on the record, not a default. | Versioning plus locked-down delete permissions is the meaningful protection here, not a second region. | [#15](../../../issues/15) |
