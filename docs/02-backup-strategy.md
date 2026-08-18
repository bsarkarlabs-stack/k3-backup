# 02 — Backup Strategy

This builds on the facts we confirmed in [01 — Discovery Baseline](01-discovery-baseline.md).

**What we're aiming for:**
> If the server dies: get a fresh Ubuntu server → install the matching K3s version → restore our
> backup → bring the apps and data back → double-check everything actually works.

---

## 1. What could go wrong, and what fixes it

Every bad scenario we can think of maps to one or more of the three "recovery tracks" explained
in section 4 below.

| If this happens... | We need... | What has to exist for it to work |
|----------|-------|-----------------|
| The whole server fails | Tracks A + B + C | Everything: server identity, database, config, Velero backup, and our Git/ArgoCD setup |
| The operating system gets corrupted | Track A | A fresh OS + our restored server folder, config, and app data |
| K3s itself breaks (program or database) | Track A | Reinstall the matching K3s version + restore the database, certificates, and keys |
| Someone accidentally deletes a Kubernetes resource | Track B or C | Restore that one object from Velero, or let ArgoCD re-create it from Git |
| A bad app deployment goes out | Track C | Revert the Git change + roll back in ArgoCD |
| A data volume gets lost or corrupted | Track B | Restore it from Velero's backup |
| The K3s database gets corrupted | Track A | Restore a clean snapshot of the database files |
| Certificates or config get lost | Track A | Restore the certificate folders + K3s config |
| ArgoCD's own settings get lost | Track C | Re-import ArgoCD's latest exported settings |
| Monitoring setup gets lost | Track C or B | Redeploy from Git if it's stored as code; otherwise restore from Velero |
| We move to a brand new server | Tracks A + B + C | Follow the full [restore runbook](03-restore-runbook.md), carefully, step by step |
| Full disaster recovery to a new machine | Tracks A + B + C | Same as above, plus pointing DNS/network at the new machine |

---

## 2. The one correction that changes everything

> ### `/etc/rancher/k3s` is just a config file. It is **not** the cluster's real identity.

Early on, we treated the SQLite database and the server's secret token as two separate things to
back up. In reality, K3s keeps the **entire identity** of the cluster — its certificates, its
passwords, everything — inside one folder: `/var/lib/rancher/k3s/server/`. And two important
sub-folders inside it were **never actually checked** during our first pass:

| Folder | What's inside | What happens if we lose it |
|-----------|----------|---------------------|
| `server/tls/` | The cluster's master certificate + every certificate used for secure connections | A restored server can't be trusted by anything that used to connect to it — every connection would need to be re-issued from scratch |
| `server/cred/` | The password/key used when other machines join this cluster | We'd have to rebuild the server's identity from zero, even if the database itself is fine |

**Rule to remember:** treat `/var/lib/rancher/k3s/server/` as **one single thing to back up** —
its `db/`, `tls/`, `cred/`, `token`, and `manifests/` folders travel together, always. Don't think
of them as four separate backup jobs that just happen to be near each other.

`/etc/rancher/k3s/` is real and still needs backing up, but it's secondary — it's a tiny 12 KB
file that just points to the real thing, not the real thing itself.

---

## 3. The 9 things we back up

We split our backup into 9 categories. Each one is backed up differently and restored
differently. **How urgent something is reflects how bad it would be to lose it — not how big the
file is.**

### 1 — The K3s database
**How urgent: Highest**

This is the live, constantly-changing state of the whole cluster. It's a SQLite database that's
actively being written to — so just copying the file while K3s is running risks grabbing it
mid-write and ending up with a broken copy.

```text
/var/lib/rancher/k3s/server/db/
├── state.db
├── state.db-wal
└── state.db-shm
```

| | |
|---|---|
| **How we back it up** | Using SQLite's proper "online backup" feature — never a plain file copy |
| **How often** | Every 6 hours |
| **Where it goes** | `s3://k3-master-dr/cluster-state/db/` |

> ⚠️ The `sqlite3` command-line tool isn't installed on `k3-master`. We can either install it, or
> just use Python's built-in `sqlite3` module, which has the exact same safe backup feature
> already built in. Either way — never write a script that just does a plain file copy.

---

### 2 — The cluster's identity & certificates
**How urgent: Highest — and very sensitive**

This is the part our early planning underestimated. This isn't just "config" — it's the actual
cryptographic identity of the cluster.

```text
/var/lib/rancher/k3s/server/
├── tls/     (master certificate + all connection certificates)
├── cred/    (password/key used when other machines join)
└── token
```

| | |
|---|---|
| **How we back it up** | A complete archive (`tar`) of the whole folder, taken at the same time as the database backup |
| **How often** | Every day, plus any time a certificate gets manually renewed |
| **Where it goes** | `s3://k3-master-dr/cluster-state/server-identity/` |

> 🔒 This must be encrypted while stored in S3, and only accessible to a very limited, dedicated
> restore-only account.

---

### 3 — K3s's own settings
**How urgent: Medium**

Small, but it tells the K3s program how to behave when it starts up.

```text
/etc/rancher/k3s/
├── k3s.yaml
└── registries.yaml
/etc/systemd/system/k3s.service
```

| | |
|---|---|
| **How we back it up** | A plain archive (~12 KB) — cheap enough to save every single time |
| **How often** | Every day, or whenever it changes |
| **Where it goes** | `s3://k3-master-dr/config/` |

---

### 4 — K3s's built-in setup files
**How urgent: Medium**

These are extra add-ons that K3s automatically installs when it starts: CoreDNS (internal DNS),
Traefik (routing traffic), metrics-server, and cloud-controller.

```text
/var/lib/rancher/k3s/server/manifests/
├── traefik-helmchartconfig.yaml  ← someone edited this by hand, older timestamp
├── coredns.yaml
├── ccm.yaml
├── local-storage.yaml
└── metrics-server/*
```

| | |
|---|---|
| **How we back it up** | A plain archive (~68 KB) |
| **How often** | Every day, or whenever it changes |
| **Where it goes** | `s3://k3-master-dr/manifests/` |

> `traefik-helmchartconfig.yaml` has an older "last modified" date than the rest — meaning
> someone edited it by hand at some point. Worth comparing it carefully before ever overwriting
> it during a restore, rather than just blindly copying over it.

---

### 5 — Everything running inside Kubernetes
**How urgent: Highest**

Every single thing the Kubernetes API server manages, across every section (namespace) of the
cluster. This is a different thing from the SQLite file above — this backs things up at the
"object" level, meaning it can be restored into any cluster, even a different K3s version.

```text
Deployments · Services · ConfigMaps · Secrets
Permissions (RBAC) · Custom resource types · Routing rules
(every namespace, not just the ones with our apps)
```

| | |
|---|---|
| **How we back it up** | Velero (a Kubernetes backup tool), saving to S3 |
| **How often** | Every day |
| **Where it goes** | `s3://k3-master-dr/velero/` |

> This is the piece that makes it possible to move to a different server or a different K3s
> version. **The SQLite database backup only helps if we rebuild the exact same server.** Moving
> to a new machine, or recovering onto a totally fresh machine, depends on this Velero backup —
> not on the database backup.

---

### 6 — App data stored on disk
**How urgent: Medium**

This covers the six monitoring data volumes. Useful and worth keeping, but it's historical data
(old metrics/logs) — not something our business directly depends on minute-to-minute.

```text
/var/lib/rancher/k3s/storage/
Prometheus ~5.5 GB · Loki/MinIO ~2.2 GB
Grafana ~50 MB · Loki Write/Backend · Alertmanager
```

| | |
|---|---|
| **How we back it up** | Velero, using its "node-agent" feature to copy files off disk |
| **How often** | Every day, at the same time as item 5 |
| **Where it goes** | `s3://k3-master-dr/velero/` (bundled together with item 5) |

> The type of storage we use (`local-path`) doesn't support the fancy "snapshot" feature some
> cloud disks have. Copying the actual files through Velero's node-agent is the only reliable way
> to back this up. See section 6 below for why a plain file copy doesn't work here.

---

### 7 — Secrets & login credentials
**How urgent: Highest — and very sensitive**

Things like image-pull credentials, HTTPS certificates stored as Kubernetes Secrets, ArgoCD's
Git login details, and any app-specific secrets.

```text
kind: Secret  (across every namespace)
— this gets captured automatically as part of the
  Velero backup, not as a separate job
```

| | |
|---|---|
| **How we back it up** | Automatically included in the Velero backup — but the S3 bucket **must** be encrypted |
| **How often** | Every day, together with item 5 |

> 🔒 A Velero backup literally contains real, readable secret values. Encrypting the bucket and
> locking down who can access it isn't a nice-to-have here — it's required.

---

### 8 — Which container images we depend on
**How urgent: Medium**

None of the items above back up the actual container images. **Even a perfect backup of
everything else is useless if we can't re-download the images afterward.**

```text
A list of every unique image currently in use,
regenerated fresh every time we run a backup
+ registries.yaml (where to download images from)
```

| | |
|---|---|
| **How we back it up** | Generate a fresh list from whatever's actually running, every time |
| **How often** | Every single backup run — it's cheap to redo |
| **Where it goes** | `s3://k3-master-dr/image-manifest/` |

---

### 9 — Git and ArgoCD recoverability
**How urgent: Highest for part (b) below, Low for part (a)**

This splits into two very different things:

**(a) The actual Git repositories** — these already live safely on GitHub. Nothing extra needed
here, other than making sure we've written down which Git repos and login credentials ArgoCD
depends on.

**(b) ArgoCD's own internal settings, which Git does *not* have a copy of:**

```text
Its config + permissions + internal secrets
Any Apps or Projects that were created by hand,
outside of our normal "one Git repo defines everything" setup
```

| | |
|---|---|
| **How we back it up** | Run `argocd admin export`, which produces one file we can re-import later |
| **How often** | Every day |
| **Where it goes** | `s3://k3-master-dr/argocd-export/` |

> Our monitoring setup splits the same way: if it's defined as code in Git, that recovers through
> this item. The actual historical metrics/logs data is a separate concern — that's item 6 above.

---

## 4. Three separate ways we can recover

Every one of the 9 items above belongs to exactly one of these three groups, which we call
"tracks." **We never need all three to succeed at once — that's the whole point of keeping them
separate.**

### Track A — The server's own files
- Its identity: `tls/`, `cred/`, `token`
- The SQLite database
- K3s's config + built-in setup files
- The server's OS-level settings *(see [Gaps](05-gaps-and-open-questions.md) — this part isn't fully covered yet)*

### Track B — What's running inside Kubernetes (via Velero, saved to S3)
- Every object, in every namespace
- Secrets and permissions
- App data on disk
- **Works even if we're restoring into a brand new cluster or a different K3s version**

### Track C — Git + ArgoCD
- Our SBE / COW app definitions (already safe in Git)
- ArgoCD's exported settings
- The fastest way to recover if it's *only* our apps that broke, nothing else

```text
    Track A              Track B              Track C
  Server files        Velero / S3          Git + ArgoCD
      │                    │                    │
      └────────────────────┼────────────────────┘
                           ▼
                 k3-master — back up and running
```

---

## 5. How we organize things inside S3

One S3 bucket, with folders (called "prefixes") separating each track and layer. **We rely on S3's
automatic lifecycle rules to delete old backups on schedule**, so nothing depends on a script
remembering to clean up after itself.

```text
s3://k3-master-dr/
├── cluster-state/
│   ├── db/                  SQLite database snapshots, every 6 hours
│   └── server-identity/     tls/, cred/, token — encrypted
├── config/                  Copy of /etc/rancher/k3s
├── manifests/               K3s's built-in setup files
├── velero/                  Everything Velero manages: apps + app data
├── argocd-export/           ArgoCD's exported settings
├── image-manifest/          List of container images in use, saved every run
├── node-config/             Network settings, firewall rules, SSH, etc.
└── run-manifests/           Which K3s version made each backup + file fingerprints
```

> **Always start a restore by looking in `run-manifests/`.** Every backup run drops a small file
> there recording the K3s version that produced it, plus the fingerprint of every file in that
> run. Without it, the K3s version only exists as text in
> [01](01-discovery-baseline.md) — which goes stale the moment we upgrade K3s — and working out
> which files belong together means comparing timestamps across seven folders by hand, during an
> outage. See [#17](../../issues/17).

### How long we keep each type of backup

| What | How often we back it up | How long we keep copies | Tool used |
|-------|-----------|-----------|------|
| Database + server identity | Every 6 hours | 7 daily + 4 weekly + 3 monthly copies | Our own script |
| Config + built-in setup files | Every day | 14 days | Our own script |
| Kubernetes objects + app data | Every day | 14 daily + 8 weekly | Velero |
| ArgoCD export | Every day | 14 days | `argocd admin export` |
| Container image list | Every run | 30 days | Our own script |
| Server OS settings | Weekly, or when changed | Last 4 copies | Our own script |
| Run manifests | Every run | **At least as long as any file it describes** | Our own script |

> Run manifests are only a few KB each. If we ever expired one *sooner* than the backup files it
> describes, those files would become unidentifiable — we'd no longer know which K3s version they
> came from. Set its lifecycle rule to outlive the longest-kept backup, not to whatever round
> number looks tidy.

### Keeping the bucket itself secure — not optional, not an afterthought

- **Least access possible.** A dedicated login that can *only* touch this one bucket, and can
  *only* add or read files, list the bucket — nothing more, nothing broader.
- **Block all public access.** No one outside our team should ever be able to reach this bucket.
- **Turn on default encryption** using our own dedicated encryption key (not Amazon's shared
  default one). Since a Velero backup contains real secret values, this really isn't optional.
- **Turn on versioning, no matter what.** This is the cheapest possible protection against
  accidentally overwriting a good backup with a bad one, or against a compromised login being used
  to tamper with backups.
- **Use two separate logins.** One login (that can only *write*) lives on the server and is used
  by the automatic backup schedule. A completely different login (that can only *read*) is used
  only during an actual restore, and is kept somewhere safe offline — never on the server itself.

---

## 6. The tricky part about app data on disk

> ### Just copying files does **not** properly restore app data volumes.

The way our storage system (`local-path-provisioner`) works, it names each data folder after a
randomly generated ID. If we create a fresh data volume during a restore, it gets a **brand new**
random ID and folder name — so a plain copy-and-paste of the old
`/var/lib/rancher/k3s/storage/` folder has nowhere matching to land in.

There are two ways to actually make this work:

1. **Use Velero's node-agent feature** — it restores the actual files *after* the new data volume
   is created, and it automatically tracks which files go where. ← This is the approach we use.
2. Manually pre-create data volumes with the exact same names as before, ahead of time. ← Works,
   but fragile and manual — easy to get wrong.

### One more thing that makes this worse: our storage deletes itself

Our storage setup uses a reclaim policy of **`Delete`** (confirmed in
[01 §9](01-discovery-baseline.md)). In plain terms: **the moment someone deletes a data volume
request (a PVC), the actual files on disk are destroyed immediately.**

There's no grace period, no orphaned copy left sitting around, no recycle bin to fish it back out
of. This is why "someone accidentally deleted the wrong thing" is genuinely dangerous here, and
why [#11](../../issues/11) (Velero) matters more than its priority label suggests — right now it
is the *only* thing that would stand between an accidental `kubectl delete pvc` and permanent loss
of that data.

This is exactly why app data backup (item 6 above) goes through Velero instead of a simple
copy-and-schedule script like items 1–4 do.

One more thing worth knowing: if a data volume gets deleted, its underlying files are deleted
**immediately** — there's no grace period where the old data just sits around waiting to be
reconnected.

---

## 7. Making sure backups actually work, and knowing if one fails

**A backup that nobody's watching is a backup that can quietly fail for months without anyone
noticing.** We already have a monitoring stack (Prometheus/Grafana/Alertmanager) — we should
reuse it instead of adding some brand new tool just for this.

| What we do | Why |
|---------|--------|
| **Checksum every backup file** | Before uploading, calculate a SHA-256 fingerprint for every archive/snapshot and save it alongside the file. That way a corrupted upload fails loudly right away — not silently, only discovered during an actual emergency restore. |
| **Feed our monitoring system** | Each backup job reports a timestamp of "when did I last succeed." We get alerted if any track's timestamp is older than 1.5× how often it's supposed to run. |
| **Test a full restore every 3 months** | Actually run through the entire [restore runbook](03-restore-runbook.md) on a throwaway test server. *A backup that's never actually been restored is just a hope, not a real plan.* |
| **Track how long a restore takes, not just pass/fail** | Time every practice restore from start to finish. If it takes longer than the business can tolerate being down, that's a real problem we need to fix — not just a footnote. |

---

## 8. What we deliberately do **not** back up

| Folder | Size | Why we skip it |
|------|------|--------------|
| `/var/lib/rancher/k3s/agent/` | ~43 GB | Just downloaded container images and cache. Fully replaceable by re-downloading from our registries — see item 8 above for the list that makes that possible. |
| `/var/lib/rancher/k3s/data/` | ~233 MB | K3s's own extracted program files. Recreated automatically just by reinstalling the matching K3s version. |

Backing these up would multiply how much storage we use and how long backups take by roughly
500×, for zero actual benefit during a restore. Skipping them is a deliberate choice, not
something we overlooked.
