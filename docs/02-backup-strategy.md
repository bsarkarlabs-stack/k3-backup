# 02 — Backup Strategy

Built on the facts confirmed in [01 — Discovery Baseline](01-discovery-baseline.md).

**What we're aiming for:**
> If the server dies: get a fresh Ubuntu server → install the matching K3s version → restore our
> backup → bring the apps and data back → check everything actually works.

**How we get there: two backup jobs plus one lightweight verification timer.**

| | Job 1 — K3s server backup | Job 2 — Velero |
|---|---|---|
| Runs where | systemd timer on `k3-master` | Inside the cluster |
| Runs when | 02:15 UTC daily | 03:30 UTC: daily Monday–Saturday, weekly Sunday |
| Backs up | The SQLite datastore, the cluster's identity, and the config K3s starts with | Every Kubernetes object in every namespace, plus all PVC data |
| Restores | **This server**, rebuilt from bare metal | Objects and PVC data into a source-compatible cluster; cross-version recovery is a tested migration, not guaranteed portability |
| Lands in | `s3://k3-master-dr/k3s/` | `s3://k3-master-dr/velero/` |
| Produces | Archive + checksum + manifest + last-written completion marker | A Kopia repository Velero manages itself |

They overlap a little, and that's deliberate — the overlap is the fallback, not waste. Job 1 alone
can rebuild this exact server. Job 2 alone can rebuild the workloads anywhere, and it's the only
thing that brings PVC data back.

---

## 1. Two numbers to agree on first — **still open**

Everything downstream is arbitrary without these. "Daily" is only the right answer if losing up to
a day of cluster state is acceptable.

| | Meaning | Working assumption | Agreed? |
|---|---|---|---|
| **RPO** — recovery point objective | How much recent change we accept losing | **24 hours** | ⏳ not signed off |
| **RTO** — recovery time objective | How long a rebuild may take before it's a business problem | **2–4 hours** | ⏳ not signed off |

The whole design below is written against those two assumptions. If they turn out to be wrong,
here is exactly what changes — so this is a cheap decision to revisit, not a redesign:

| If the answer is | What changes |
|---|---|
| RPO stays 24 h | Nothing. Job 1 daily, Job 2 daily. |
| RPO under 6 h | Job 1 runs 4× a day into a third prefix with its own lifecycle rule. Job 2 gets a second Schedule. Roughly 4× the objects and 4× the failure surface. |
| RTO under 1 h | Daily backups are no longer the constraint — a warm standby host is. That is a different project. |
| RTO 8 h+ | The runbook can stay a manual document and never needs automating. |

The honest position today: this cluster runs no application database
([01 §12](01-discovery-baseline.md#12-databases-running-inside-our-apps)) and SBE/COW are redeployed
from Git, so a few hours of rewound cluster state costs very little. The datastore's real risk is
total loss, not a short gap. That's why the assumption above is 24 hours — but it is an assumption
until someone signs it off. Tracked as
[gap 1](05-gaps-and-open-questions.md#1-rpo-and-rto-are-not-signed-off).

---

## 2. What this protects against — and what it doesn't

Writing this down is what stops the design drifting into either paranoia or false comfort.

| Threat | Covered? | By what |
|--------|----------|---------|
| Disk failure, host loss, theft, fire | ✅ | Everything is off-server in S3, in another country |
| Someone deletes a PVC or a Secret by accident | ✅ | Job 2 (Velero). **Job 1 cannot do this** |
| A normal rerun partially uploads or overwrites a set | ✅ | Unique run prefix, checksum, and `COMPLETE.json` uploaded last |
| The Job 1 credential leaks | ⚠️ Partly | It cannot read/delete or access `velero/`, but it **can overwrite** Job 1 keys. Version history lasts 31 days |
| The Velero credential leaks | ⚠️ Partly | Object access is confined to `velero/`, which is readable/deletable because Kopia and TTL require it. It can also list key *names* bucket-wide |
| Full ransomware / AWS account compromise | ❌ | **Deliberately out of scope.** See §9 for what it would take |
| A whole AWS region going down | ❌ | Out of scope. One server with no failover is a far bigger single point of failure than a region |

> **The bucket is a more valuable target than the server it protects.** `state.db` holds every
> Kubernetes Secret in readable form (unless K3s secret encryption is on), and the archive holds
> the cluster CA and its private key. That single fact drives every choice in §3.

---

## 3. Where it all goes

One bucket. Three prefixes that we write, one that Velero owns.

```text
s3://k3-master-dr/
├── k3s/
│   ├── daily/YYYY-MM-DDTHHMMSSZ/     one unique committed run
│   └── weekly/YYYY-MM-DDTHHMMSSZ/    Sunday copy
├── k3s-release/<version>/    the k3s binary, written once per version (§8)
└── velero/                   Velero owns this — we never touch it by hand
```

Each successful `k3s/` folder holds four objects:

```text
k3s-<run-id>.tar.gz            ~20 MB — the entire backup, one file
k3s-<run-id>.tar.gz.sha256     convenience copy of the digest
MANIFEST.json                  which K3s version to install. Read this first
COMPLETE.json                  uploaded last; ignore a prefix without it
```

Verification runs **marker → manifest → archive**: `COMPLETE.json` carries the manifest's digest and
`MANIFEST.json` carries the archive's, so one authenticated file leads to the next. The sidecar
`.sha256` is convenience only — anyone able to alter the archive could alter a checksum sitting
loose beside it, so a restore compares against the manifest instead
([03 §A step 1](03-restore-runbook.md#step-1--pick-a-backup-and-read-its-manifest)).

`MANIFEST.json` is also *inside* the archive. It sits outside as well so a restore can learn the
K3s version and the archive's checksum without downloading the archive first.

Inside the archive:

```text
./MANIFEST.json
./state.db          the datastore — placed by hand at restore time
./fs-root/…         cp -a fs-root/. /  : token, tls/, cred/, manifests/,
                    /etc/rancher/k3s, /etc/systemd/system/k3s.service
./host-facts/…      plain text. Reference for rebuilding the host. Never extracted onto /
```

### Bucket settings

| Setting | Value | Why |
|---------|-------|-----|
| Block all public access | on | Non-negotiable for a bucket holding the cluster CA |
| Versioning | on | The cheapest protection against a bad backup overwriting a good one |
| Default encryption | **SSE-S3** | S3 encrypts every object on arrival, with nothing to configure, rotate or lose. See below |
| Lifecycle rules | current expiry on Job 1; noncurrent-only expiry on `velero/` and releases | §6 |

> ### Why SSE-S3 and not a customer-managed KMS key
>
> An earlier version of this design used a dedicated KMS key. It cost us a key to create, an alias,
> a rotation setting, four KMS IAM actions, a bucket policy comparing the exact key ARN, a
> `KMS_KEY_ID` in the server's config, a non-obvious `kms:Decrypt` requirement for multipart
> uploads, and a 64 MB test upload that existed purely to catch that requirement. It also added a
> hard dependency: delete the key and every backup becomes permanently unreadable, including the
> one you're trying to restore from.
>
> What it bought was a second authorization gate — a leaked S3 credential alone couldn't decrypt
> the backups. But the credential on the server held `kms:Decrypt` *and* `s3:GetObject`, so that
> gate was already open to the one credential most likely to leak.
>
> **The practical fix is to take read access away from Job 1.** Its environment credential cannot
> read or delete Job 1 backups. This does not make a root-compromised Kubernetes node immutable:
> root can reach the Velero Secret, and any PutObject credential can overwrite keys it owns.
> Versioning limits that risk; Object Lock or a separate account is the stronger control.
>
> Switch to SSE-KMS only if a client or a compliance requirement specifically demands a
> customer-managed key. It is a one-line bucket setting plus two IAM actions — not a redesign.

### Two workload credentials, separated by failure domain

| Identity | Allowed actions | Scope |
|----------|-----------------|-------|
| Job 1 | put/multipart only; list restricted by `s3:prefix` | `k3s/*`, `k3s-release/*`, `_preflight/*` |
| Velero | put/get/delete/multipart; list is **bucket-wide** | objects: `velero/*` only |

> This table must match [07 §2.5](07-setup.md) exactly. A summary that under-states the policy is an
> invitation to "tighten" the real one to match it — and Velero's PVC uploads are multipart, so
> dropping `ListMultipartUploadParts` from `velero/*` breaks Job 2 for every volume over 8 MB.

Read the gaps in that table, because they are the point:

- **No `GetObject` on `k3s/*`.** The server can write backups and never read one back. It confirms
  its own uploads by *listing* them and comparing sizes, which needs no read permission.
- **No `DeleteObject` on `k3s/*`.** Expiry there is entirely S3's job, via lifecycle rules.
- **Job 1 has no access to `velero/*`.** Leaking `/etc/k3s-backup/backup.env` does not expose Kopia.
- **Isolation is on objects, not on key names — for Velero.** Velero's `s3:ListBucket` has no
  `s3:prefix` condition, because Velero's and Kopia's listing patterns are not a stable contract and
  a wrong condition breaks backup or TTL expiry silently. That key can therefore *enumerate* keys
  outside `velero/`; it cannot read, write or delete any of them. Job 1's listing is prefix-scoped,
  since every list call it makes names a prefix we control ([07 §2.5](07-setup.md#25--create-separate-job-1-and-velero-credentials)).
- **The Velero credential is the exception, and it has to be.** Velero expires backups using each
  Schedule's `ttl` — TTL expiry *is* Velero issuing deletes. Without that permission nothing under
  `velero/` ever expires and the retention policy in §6 becomes fiction. Do not "harden" it away.

**Restores use your normal AWS admin or SSO login**, not a stored restore key. What this requires:
**at least two named people must have AWS access, and the bucket name and region must be recorded
somewhere outside AWS** ([gap 5](05-gaps-and-open-questions.md#5-who-can-actually-perform-a-restore)).

---

## 4. Job 1 — the K3s server backup

Script: [`scripts/k3s-server-backup.sh`](../scripts/k3s-server-backup.sh).
Schedule: [`scripts/systemd/k3s-backup.timer`](../scripts/systemd/k3s-backup.timer).

Everything in this table is load-bearing except the last row.

| What | How it's captured | Why a restore fails without it |
|------|-------------------|--------------------------------|
| `server/db/state.db` | SQLite **online backup API** via Python, on a read-only connection → one consistent file | It *is* the cluster state. A plain `cp` of a live WAL database can copy a torn page and restore into a corrupt cluster. |
| `server/tls/` | in `fs-root/` | The cluster CA and every cert issued from it. |
| `server/cred/` | in `fs-root/` | Join credentials + the secret-encryption key if that's enabled. |
| `server/token` | in `fs-root/`, permissions preserved (`0600 root:root`) | K3s unlocks bootstrap data in the datastore with it. |
| `server/manifests/` | in `fs-root/` | The bundled add-ons — including `traefik-helmchartconfig.yaml`, which someone edited by hand and which cannot be regenerated. |
| `/etc/rancher/k3s/` | in `fs-root/` | `registries.yaml` holds our registry mirrors and pull credentials — images won't pull without it. |
| `/etc/systemd/system/k3s.service` (+ `.env`) | in `fs-root/` | The start flags: `--tls-san`, disabled components, node labels. Reinstalling with defaults silently produces a *different* cluster. |
| `MANIFEST.json` | generated each run | The exact K3s version and start command. Nothing else in the backup records them: `uname` is the kernel, and K3s isn't a dpkg package. Restoring at the wrong version is the most common self-inflicted restore failure. |
| Host fact sheet | plain text in `host-facts/` | *Optional* (`INCLUDE_HOST_FACTS=0` to skip). Addresses, routes, firewall rules, timezone, disk layout, package list, netplan. ~50 KB. |

The script fingerprints `token`, `tls/` and `cred/` before taking the database snapshot and again
after staging identity. If K3s rotates any of them during the run, the job aborts rather than
uploading a mixed cryptographic restore set.

### Why one archive instead of four files

The previous design uploaded `state.db`, `k3s-identity.tar.gz`, `node-config.tar.gz` and
`MANIFEST.json` as four separate objects with four checksums. Nothing was wrong with it — but there
was nothing to gain from it either, because all four are always restored together. One archive
means one checksum, one download, one thing that cannot be half-matched, and gzip takes the ~64 MB
datastore down to roughly 20 MB on the way past.

`MANIFEST.json` stays outside because you read it first. `COMPLETE.json` is the commit marker: it
is uploaded only after the other objects pass size verification. Unique run prefixes mean a failed
retry cannot leave an old marker pointing at a newly overwritten archive.

### The host fact sheet is facts, not config

The previous design copied `/etc/ssh`, `authorized_keys`, `/etc/ufw` and more into the backup, to
be extracted during a rebuild. **That was the wrong shape.** `/etc/ssh` contains the host's private
keys, which makes the bucket a bigger target and which you should not restore onto a different
machine anyway. Blanket-restoring an old host's networking and firewall config over a fresh install
creates more problems than it solves.

So the job captures the same information as **plain text you read**, not config you extract:
`ip addr`, `ip route`, `ufw status verbose`, `timedatectl`, `lsblk`, `df`, the enabled unit list,
`dpkg --get-selections`, `/etc/hosts`, `/etc/fstab`, the netplan YAML, and the exact K3s start
command. Restore step 2 stays a file you read instead of memory you search — without shipping host
private keys off-site.

Anything that genuinely belongs in version control — hostname, addressing, open ports, firewall
requirements, install method — belongs in Git or your IaC, not in a nightly backup payload.

### What Job 1 deliberately does not back up

| | Size | Why |
|---|---|---|
| `state.db-wal`, `state.db-shm` | ~27 MB | The online backup already folds the WAL in. Copying stale sidecar files over a restored database is **actively harmful** — delete them at restore time. |
| `/var/lib/rancher/k3s/agent/` | ~43 GB | Container image cache. Re-pulled from the registries in `registries.yaml`. |
| `/var/lib/rancher/k3s/data/` | ~233 MB | K3s's own extracted binaries. Recreated from the `k3s` binary itself. |
| `/etc/ssh`, `authorized_keys` | tiny | Host private keys. See above. |

---

## 5. Job 2 — Velero

Install: [`scripts/velero/install-velero.sh`](../scripts/velero/install-velero.sh).
Schedules: [`schedule-daily.yaml`](../scripts/velero/schedule-daily.yaml),
[`schedule-weekly.yaml`](../scripts/velero/schedule-weekly.yaml).

**This is not optional and not a "phase 2 nice-to-have."** Job 1 cannot restore a deleted PVC or a
single deleted Secret. Until Velero exists, an accidental `kubectl delete pvc` is permanent.

| Covered | How |
|---------|-----|
| Every namespaced object in every namespace — Deployments, Services, ConfigMaps, **Secrets**, Ingress, Traefik IngressRoute/Middleware, ArgoCD Applications and AppProjects, monitoring CRs | Default scope. **No include/exclude list to maintain** — a new namespace can never appear unprotected. |
| Cluster-scoped objects — CRDs, ClusterRoles, ClusterRoleBindings, StorageClass, PVs | `includeClusterResources: true` |
| All six monitoring PVCs — Prometheus, Loki, MinIO, Loki write/backend, Grafana, Alertmanager | node-agent **file-system backup**, `defaultVolumesToFsBackup: true` |

Install flags that matter, and why:

```text
--use-volume-snapshots=false      there is no CSI snapshot driver here; local-path cannot snapshot
--default-volumes-to-fs-backup    opt *out* per pod if ever needed — never opt in, or a new PVC
                                  ships silently unprotected
--use-node-agent --uploader-type kopia
```

The installer pins Velero `v1.18.0` with AWS plugin `v1.14.1`, a compatible pair tested against
Kubernetes 1.34-era clusters, and requires the verified kubelet root through
`--kubelet-root-dir`. File System Backup is exactly why the
restore test in §10 is mandatory rather than advisory.

### Why PVC data has to go through Velero

> **Copying `/var/lib/rancher/k3s/storage/` does not work as a backup.**

`local-path-provisioner` names each volume directory after a randomly generated ID. Restore a PVC
and it gets a **brand new** ID and directory — so a copied folder has nowhere matching to land.
Velero's node-agent restores the files *after* the new volume exists and tracks which files belong
where. That's the whole reason this job exists in this shape.

It matters more than it sounds. Our StorageClass reclaim policy is **`Delete`** (confirmed in
[01 §9](01-discovery-baseline.md#9-where-app-data-files-are-stored)): the moment someone deletes a
PVC, the files on disk are gone immediately. No grace period, no orphan, no recycle bin.

---

## 6. Schedule and retention

| Time (UTC) | What runs | Configured in |
|---|---|---|
| 02:15 daily | Job 1. On Sundays it uploads the same four-object committed set under `k3s/weekly/`. | `k3s-backup.timer` |
| 03:30 Monday–Saturday | Job 2, daily tier | `Schedule/daily`, `ttl: 168h` |
| 03:30 Sunday | Job 2, weekly tier (replaces daily that day) | `Schedule/weekly`, `ttl: 720h` |

Job 1's latest possible timeout is before 03:30. Sunday has one Velero schedule, not two, so the
daily and weekly FSB jobs cannot overlap.

These jobs are **not one transaction or one recovery point**. Job 1 records cluster state near
02:15; Velero starts later and reads each live volume over an interval. During recovery, record the
exact Job 1 `run_id`, Velero backup name, start/completion timestamps, and the reason that pair was
chosen. The conservative default is the newest Velero backup whose creation time is not newer than
Job 1's `run_timestamp`; using a later volume image is a deliberate application-specific decision.

Velero FSB is not crash-consistent or application-consistent: files can change while the scan is
running. Monitoring history is therefore best-effort unless the owner explicitly requires a
tested application-native export or quiesce hook.

**Retention target: one restore point for each of the last 7 days, plus 4 Sundays.** Job 1 expresses
it with S3 lifecycle rules; Job 2 expresses it with Velero TTL.

| Location | Written | Expiry mechanism | Keeps |
|----------|---------|------------------|-------|
| `k3s/daily/` | Daily | S3 lifecycle — expire **8 days** after creation | 7–8 restore points |
| `k3s/weekly/` | Sundays | S3 lifecycle — expire **31 days** after creation | 4–5 restore points |
| `k3s-release/` | Once per K3s version | **No rule.** Never expires | Every version we ever ran |
| `velero/` daily | Monday–Saturday | Velero `ttl: 168h` | 6 weekday backups |
| `velero/` weekly | Sundays | Velero `ttl: 720h` | 4 Sunday backups |
| noncurrent versions under `velero/` | overwrite/delete history | S3 noncurrent-only expiry | 35 days |
| noncurrent versions under `k3s-release/` | overwrite history | S3 noncurrent-only expiry | 365 days |

Two prefixes exist under `k3s/` for one reason: an S3 lifecycle rule can only say *"expire N days
after creation"*, so anything kept for a different length of time needs its own prefix. Job 1 knows
whether it's Sunday, so it just uploads the same files twice that day.

Velero's counts differ from Job 1's on purpose. Sunday runs the weekly schedule *instead of* the
daily one, so the daily tier holds six backups rather than seven. The last seven calendar days are
still covered — six weekday backups plus that week's Sunday backup — and the Sunday copy is the one
retained for a month. Two schedules firing at the same hour would put two concurrent file-system
scans on one disk, which is a worse trade than an unevenly-named tier.

> ### Never put a current-version lifecycle rule on `velero/`
>
> Velero's file-system backups live in a Kopia repository whose objects reference each other. An S3
> expiry rule will delete chunks that a still-valid backup depends on, and the corruption only
> surfaces when you try to restore. If you want a safety net there, use a *noncurrent version*
> expiry, never a current-version one.

**Why no monthly tier.** Restoring three-month-old cluster state restores a cluster nobody wants
back — by then every workload has moved on. 7 + 4 covers "yesterday broke" and "it broke a while
ago and nobody noticed."

**Cost:** roughly 200 MB for `k3s/` plus 10–15 GB for Velero once Kopia deduplicates the monitoring
volumes, plus ~70 MB per K3s version. Single-digit dollars a month.

---

## 7. Knowing it works

**A backup nobody watches fails silently for months.** Four alerts, and only four.

| # | Alert | Where it runs | Threshold |
|---|-------|---------------|-----------|
| 1 | **No Job 1 backup arrived** | Off-server dead-man's switch | 26 hours |
| 2 | **No verified Velero heartbeat** | Off-server dead-man's switch | 30 hours |
| 3 | Latest scheduled Backup/PVB set is failed or incomplete | Host verifier; suppresses alert 2 heartbeat | any failure or fewer than configured minimum |
| 4 | Root disk free space low | Prometheus/Alertmanager, in-cluster | under 10% |

Commands for all four: [07 steps 5.1–5.4](07-setup.md#51--choose-the-two-dead-man-checks-local).
None of them counts as working until it has been broken on purpose
([07 step 5.5](07-setup.md#55--break-every-alert-on-purpose)).

### Alert 3 exists because `Completed` is not the same as "it backed something up"

This is the failure this design predicts about itself: if the node-agent cannot reach the kubelet
root, it backs up **nothing** and the backup still finishes `Completed`
([gap 6](05-gaps-and-open-questions.md#6-whether-veleros-node-agent-can-actually-read-our-volumes)). Alert 2 would stay green through it, every night, until a
restore discovered the truth.

So the assertion has to be about **volume count, not backup status**. Each volume the node-agent
handles produces a `PodVolumeBackup` object:

[`check-last-backup.sh`](../scripts/velero/check-last-backup.sh) selects the newest `daily` or
`weekly` scheduled backup by timestamp, verifies freshness and phase, then requires every
PodVolumeBackup to be `Completed` and at least `MIN_EXPECTED_PVBS` to exist. It pings a dedicated
external URL only after all checks pass. A raw PVC count is not used: unmounted claims and multiple
pod mounts mean PVC count and PodVolumeBackup count are not a reliable one-to-one invariant.

The ping is **edge-triggered on a backup it has not reported before.** The verifier records the UID
of the backup it last reported (`/var/lib/k3s-backup/velero-last-reported`) and refuses to ping the
same one twice. Without that, a single skipped 03:30 schedule would still be "verified" from
yesterday's backup, which is inside the 30 h freshness window — the dead-man timer would reset and
the missed run would never surface. The UID is written only after the ping succeeds, so a failed
ping is retried on the next run instead of being silently swallowed.

### Both backup-success heartbeats survive server loss

Alerts 1 and 2 terminate outside the cluster. The verification for alert 2 runs on the host, but a
host outage stops its ping and therefore still raises the external dead-man alert.

It works as a **heartbeat**: the backup script pings a URL, and something outside this server raises
the alarm when the ping stops arriving. Critically, the script pings *after* it has confirmed the
archive, checksum and manifest are verified and `COMPLETE.json` is in S3 — so the heartbeat means "the backup arrived",
not "the script is pleased with itself". Set `HEARTBEAT_URL` in `/etc/k3s-backup/backup.env`; the
script warns loudly if it is missing.

> ⏳ **Open decision: which service receives the two heartbeats.**
> Both scripts are channel-agnostic — any URL that expects a periodic GET works. Use two checks,
> so one job cannot hide failure of the other. Three realistic
> options: a hosted dead-man's-switch (healthchecks.io, Cronitor — free tier, ~5 minutes to set
> up); AWS-native (an EventBridge rule on S3 `ObjectCreated` under `k3s/daily/` feeding a
> CloudWatch alarm that treats missing data as breaching); or an Alertmanager push gateway hosted
> *outside* this cluster. Tracked as
> [gap 2](05-gaps-and-open-questions.md#2-the-external-heartbeats-have-nowhere-to-report-yet). Until it is
> decided, a missing backup is only visible to someone who goes looking.

### What we deliberately stopped doing

The previous design wrote a node-exporter textfile metric and planned to alert on it. We never
confirmed anything read that directory, the metric only proved the script's own opinion of itself,
and it required host-level Prometheus plumbing to be useful. It's gone; the heartbeat replaces it
with something both simpler and more honest.

Also gone: "check it manually every day for a week." Do watch the first two or three runs — a new
job deserves that. But a design whose monitoring is a human remembering to look is not a design.

---

## 8. Future-proofing a restore

Two things make a restore harder the older the backup gets. Both are handled cheaply.

**1. The matching K3s release might not be downloadable.** A restore wants the same version that
made the backup, and `get.k3s.io` is not a promise about 2030. So the job uploads the `k3s` binary
itself plus `k3s.sha256` to `k3s-release/<version>/`, **once per version** — later runs are no-ops
that cost one list call. About 70 MB per version we ever run; current objects are never expired.

`install.sh` is not needed alongside it: that script's real job is writing the systemd unit, and the
unit is already in the archive. A restore is copy the binary, `chmod`, symlink `kubectl`/`crictl`/
`ctr`, restore the unit, start. The prefix carries a `RESTORE.txt` saying exactly that.

**2. Nobody remembers how this server was started.** `MANIFEST.json` records `k3s_version`,
`k3s_version_raw`, the full `k3s_start_command` reconstructed from the systemd unit, the OS release,
the kernel, architecture, hostname, archive size/SHA-256, and K3s binary SHA-256.

---

## 9. The immutability decision — made, and on the record

**Scope: we protect against hardware failure, host loss and accidental deletion. A compromised
node is only partly covered; a compromised AWS account is not covered.**

Job 1 cannot read or delete `k3s/`, but it can overwrite keys and root on the node can retrieve the
Velero Secret. Versioning preserves overwritten Job 1 versions for 31 days; that is rollback
history, not immutability.

If ransomware or AWS credential compromise ever comes into scope, the answer is **S3 Object Lock in
compliance mode** (or a separate AWS account holding the bucket), decided once and applied to a new
prefix or a new bucket. **Don't add it speculatively** — Object Lock cannot be turned off, and
locked objects cannot be deleted by anyone, including you, before their retention expires.

---

## 10. The restore test is part of the design, not homework

*A backup that has never been restored is a hope, not a plan.* This is the single most important
operational control in this document, and the one thing the previous version of it never actually
did — its final stage downloaded the artifacts and inspected them, which is validation, not a
restore.

A real test is:

```text
fresh Ubuntu VM
   → install the matching K3s (from k3s-release/ if needed)
   → restore Job 1: fs-root/, state.db, no -wal/-shm
   → cluster starts, node Ready
   → install Velero read-only, restore PVC data
   → Prometheus answers a query over PRE-INCIDENT data
   → Ingress and HTTPS actually work
   → write down how long it took — that number is the real RTO
```

Run it: **once now**, then **every 3–6 months**, and **after any K3s upgrade or change to this
design**. Full steps in [§C of the restore runbook](03-restore-runbook.md#c--the-restore-test).

---

## 11. What was removed from the previous design, and why

Kept because it earns its place: the SQLite online backup, token/identity travelling with the
datastore, off-server S3, versioning, lifecycle retention, the systemd timer, Velero with
file-system backup, the SHA-256, `MANIFEST.json`, and the restore test.

| Removed | Why |
|---|---|
| Customer-managed KMS key, its alias, rotation, IAM actions and the "wrong key" bucket policy | §3. Replaced by SSE-S3 plus a credential that cannot read `k3s/` — simpler *and* a tighter blast radius |
| The 64 MB multipart test upload, in the runbook and the preflight | It existed solely to catch the missing `kms:Decrypt`. No KMS, no failure mode, no test |
| The second, permanent restore-reader IAM user and its 90-day rotation | Restores use an admin/SSO login. One less long-lived key holding the cluster CA, one less rotation chore |
| Four separate artifacts and four checksums | One archive, one checksum. They were only ever restored together (§4) |
| `/etc/ssh`, `authorized_keys` and blanket `/etc` copies | Host private keys don't belong in the bucket, and blanket-restoring them onto a new host is wrong (§4) |
| The node-exporter textfile success metric | Nothing was confirmed to read it, and it proved the wrong thing (§7) |
| "Check manually every day for a week" as the monitoring plan | Replaced by the heartbeat (§7) |
| Bucket-configuration checks from the on-node preflight | That credential cannot read bucket settings, and shouldn't. Verified once at setup with an admin login instead |
| The parallel 4,100-line day-by-day runbook | Two documents describing the same setup drift apart. There is now one: [07 — Setup](07-setup.md) |

---

## 12. Gaps that still need closing

The design is only as good as these answers. See
[05 — Gaps & Open Questions](05-gaps-and-open-questions.md) for the full list; the blocking ones are:

| # | Gap |
|---|-----|
| 1 | **RPO/RTO are not signed off** — §1 is written against an assumption |
| 2 | **The two heartbeats have nowhere to report yet** — scripts exist, endpoints are not wired |
| 3 | **Nothing has ever been restored** — §10 |
| 4 | **Where Traefik's TLS certificates come from.** If Traefik issues them itself and keeps `acme.json` in an `emptyDir`, nothing here backs it up and a restore comes back with broken HTTPS and no warning |
| 5 | **Who can actually perform a restore** — no stored restore key means two named people with AWS access |
| 6 | **Velero's node-agent vs. K3s's kubelet root.** A path mismatch starts cleanly and backs up *nothing* — it looks like an empty backup, not an error |
