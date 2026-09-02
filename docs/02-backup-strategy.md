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
| Produces | One `.tar.gz` + its `.sha256` + `MANIFEST.json` | A Kopia repository Velero manages itself |

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
| A bad backup overwrites a good one | ✅ | Bucket versioning |
| `k3-master` is compromised and the attacker tries to delete the backups | ✅ | The credential on the server has **no delete** outside `velero/` |
| `k3-master` is compromised and the attacker tries to *read* the backups | ✅ | The same credential has **no read** outside `velero/` — see §3 |
| The AWS credential leaks and someone re-encrypts or tampers with objects | ⚠️ Partly | They cannot delete, and versioning keeps the originals — but noncurrent versions expire after 2 days |
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
│   ├── daily/YYYY-MM-DD/     job 1 writes here every day
│   └── weekly/YYYY-MM-DD/    job 1 writes here on Sundays too
├── k3s-release/<version>/    the k3s binary, written once per version (§8)
└── velero/                   Velero owns this — we never touch it by hand
```

Each `k3s/` folder holds three objects, and that is the whole restore set:

```text
k3s-YYYY-MM-DD.tar.gz          ~20 MB — the entire backup, one file
k3s-YYYY-MM-DD.tar.gz.sha256   verify this before trusting the archive
MANIFEST.json                  which K3s version to install. Read this first
```

`MANIFEST.json` is also *inside* the archive. It sits outside as well so a restore can learn the
K3s version and the archive's checksum without downloading the archive first.

Inside the archive:

```text
./MANIFEST.json
./state.db          the datastore — placed by hand at restore time
./root/…            extract onto / : token, tls/, cred/, manifests/,
                    /etc/rancher/k3s, /etc/systemd/system/k3s.service
./host-facts/…      plain text. Reference for rebuilding the host. Never extracted onto /
```

### Bucket settings

| Setting | Value | Why |
|---------|-------|-----|
| Block all public access | on | Non-negotiable for a bucket holding the cluster CA |
| Versioning | on | The cheapest protection against a bad backup overwriting a good one |
| Default encryption | **SSE-S3** | S3 encrypts every object on arrival, with nothing to configure, rotate or lose. See below |
| Lifecycle rules | on `k3s/daily/`, `k3s/weekly/`, `_preflight/` — **never on `velero/`** | §6 |

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
> **The real fix was cheaper and stronger: take read access away from the server.** With SSE-S3
> plus a write-only credential, a compromised `k3-master` can neither read nor delete the backups.
> S3 encrypts every new object at rest by default either way.
>
> Switch to SSE-KMS only if a client or a compliance requirement specifically demands a
> customer-managed key. It is a one-line bucket setting plus two IAM actions — not a redesign.

### One credential, and what it deliberately cannot do

| Allowed | On |
|---------|-----|
| `s3:ListBucket`, `s3:GetBucketLocation` | the bucket |
| `s3:PutObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts` | `k3s/*`, `k3s-release/*`, `_preflight/*` |
| `s3:PutObject`, `s3:GetObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload` | `velero/*` **only** |

Read the gaps in that table, because they are the point:

- **No `GetObject` on `k3s/*`.** The server can write backups and never read one back. It confirms
  its own uploads by *listing* them and comparing sizes, which needs no read permission.
- **No `DeleteObject` on `k3s/*`.** Expiry there is entirely S3's job, via lifecycle rules.
- **`velero/*` is the exception, and it has to be.** Velero expires its own backups using each
  Schedule's `ttl` — TTL expiry *is* Velero issuing deletes. Without that permission nothing under
  `velero/` ever expires and the retention policy in §6 becomes fiction. Do not "harden" it away.

**Restores use your normal AWS admin or SSO login**, not a stored key. There is no second
long-lived credential to keep in a vault and rotate — the previous design had one and it was pure
operational burden. What this *does* require, and it is written down as a gap rather than assumed:
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
| `server/tls/` | in `root/` | The cluster CA and every cert issued from it. |
| `server/cred/` | in `root/` | Join credentials + the secret-encryption key if that's enabled. |
| `server/token` | in `root/`, permissions preserved (`0600 root:root`) | K3s unlocks bootstrap data in the datastore with it. |
| `server/manifests/` | in `root/` | The bundled add-ons — including `traefik-helmchartconfig.yaml`, which someone edited by hand and which cannot be regenerated. |
| `/etc/rancher/k3s/` | in `root/` | `registries.yaml` holds our registry mirrors and pull credentials — images won't pull without it. |
| `/etc/systemd/system/k3s.service` (+ `.env`) | in `root/` | The start flags: `--tls-san`, disabled components, node labels. Reinstalling with defaults silently produces a *different* cluster. |
| `MANIFEST.json` | generated each run | The exact K3s version and start command. Nothing else in the backup records them: `uname` is the kernel, and K3s isn't a dpkg package. Restoring at the wrong version is the most common self-inflicted restore failure. |
| Host fact sheet | plain text in `host-facts/` | *Optional* (`INCLUDE_HOST_FACTS=0` to skip). Addresses, routes, firewall rules, timezone, disk layout, package list, netplan. ~50 KB. |

### Why one archive instead of four files

The previous design uploaded `state.db`, `k3s-identity.tar.gz`, `node-config.tar.gz` and
`MANIFEST.json` as four separate objects with four checksums. Nothing was wrong with it — but there
was nothing to gain from it either, because all four are always restored together. One archive
means one checksum, one download, one thing that cannot be half-matched, and gzip takes the ~64 MB
datastore down to roughly 20 MB on the way past.

The one thing that stayed outside the archive is `MANIFEST.json`, because you read it *before*
deciding to download anything.

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

File System Backup is documented by Velero as beta for some volume types, which is exactly why the
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
| 02:15 daily | Job 1. On Sundays it uploads the same three objects a second time under `k3s/weekly/`. | `k3s-backup.timer` |
| 03:00 daily | Job 2, daily tier | `Schedule/daily`, `ttl: 168h` |
| 04:00 Sunday | Job 2, weekly tier | `Schedule/weekly`, `ttl: 720h` |

The 45-minute gap keeps Velero's node-agent off the disk while the SQLite reader is running, and
the Sunday runs are staggered so the weekly Velero backup never overlaps the daily one.

**Retention is 7 daily + 4 weekly**, expressed twice: as S3 lifecycle rules for Job 1, as Velero
TTL for Job 2.

| Location | Written | Expiry mechanism | Keeps |
|----------|---------|------------------|-------|
| `k3s/daily/` | Daily | S3 lifecycle — expire **8 days** after creation | 7–8 restore points |
| `k3s/weekly/` | Sundays | S3 lifecycle — expire **31 days** after creation | 4–5 restore points |
| `k3s-release/` | Once per K3s version | **No rule.** Never expires | Every version we ever ran |
| `velero/` daily | Daily | Velero `ttl: 168h` | 7 backups |
| `velero/` weekly | Sundays | Velero `ttl: 720h` | 4 backups |

Two prefixes exist under `k3s/` for one reason: an S3 lifecycle rule can only say *"expire N days
after creation"*, so anything kept for a different length of time needs its own prefix. Job 1 knows
whether it's Sunday, so it just uploads the same files twice that day.

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

**A backup nobody watches fails silently for months.** Three alerts, and only three.

| # | Alert | Where it runs | Threshold |
|---|-------|---------------|-----------|
| 1 | **No Job 1 backup arrived** | Off-server dead-man's switch | 26 hours |
| 2 | Velero's last backup isn't `Completed` | Prometheus/Alertmanager, in-cluster | 26 hours stale |
| 3 | Root disk free space low | Prometheus/Alertmanager, in-cluster | under 10% |

### Alert 1 is the important one, because it survives the server

Alerts 2 and 3 run inside the cluster we are trying to protect. If `k3-master` dies, they die with
it — and the failure that matters most goes unreported. Alert 1 has to live somewhere else.

It works as a **heartbeat**: the backup script pings a URL, and something outside this server raises
the alarm when the ping stops arriving. Critically, the script pings *after* it has confirmed the
three objects are actually in S3 at the right size — so the heartbeat means "the backup arrived",
not "the script is pleased with itself". Set `HEARTBEAT_URL` in `/etc/k3s-backup/backup.env`; the
script warns loudly if it is missing.

> ⏳ **Open decision: which service receives the heartbeat.**
> The script is channel-agnostic — any URL that expects a periodic GET works. Three realistic
> options: a hosted dead-man's-switch (healthchecks.io, Cronitor — free tier, ~5 minutes to set
> up); AWS-native (an EventBridge rule on S3 `ObjectCreated` under `k3s/daily/` feeding a
> CloudWatch alarm that treats missing data as breaching); or an Alertmanager push gateway hosted
> *outside* this cluster. Tracked as
> [gap 2](05-gaps-and-open-questions.md#2-the-heartbeat-has-nowhere-to-report-to-yet). Until it is
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
itself to `k3s-release/<version>/k3s`, **once per version** — the daily run after that is a no-op
that costs one list call. About 70 MB per version we ever run, never expired.

`install.sh` is not needed alongside it: that script's real job is writing the systemd unit, and the
unit is already in the archive. A restore is copy the binary, `chmod`, symlink `kubectl`/`crictl`/
`ctr`, restore the unit, start. The prefix carries a `RESTORE.txt` saying exactly that.

**2. Nobody remembers how this server was started.** `MANIFEST.json` records `k3s_version`,
`k3s_version_raw`, the full `k3s_start_command` reconstructed from the systemd unit, the OS release,
the kernel, the architecture, the hostname, and the archive's size and SHA-256.

---

## 9. The immutability decision — made, and on the record

**Scope: we protect against hardware failure, host loss, accidental deletion, and a compromised
`k3-master`. We do not currently protect against a compromised AWS account.**

What we have is enough for that scope: versioning is on, the server's credential cannot delete or
read anything under `k3s/`, and expiry is S3's job rather than the server's. An attacker on
`k3-master` can stop future backups from being written — they cannot destroy or read the existing
ones.

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
   → restore Job 1: root/, state.db, no -wal/-shm
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
| 2 | **The heartbeat has nowhere to report to yet** — §7 alert 1 is designed, not wired |
| 3 | **Nothing has ever been restored** — §10 |
| 4 | **Where Traefik's TLS certificates come from.** If Traefik issues them itself and keeps `acme.json` in an `emptyDir`, nothing here backs it up and a restore comes back with broken HTTPS and no warning |
| 5 | **Velero's node-agent vs. K3s's kubelet root.** A path mismatch starts cleanly and backs up *nothing* — it looks like an empty backup, not an error |
