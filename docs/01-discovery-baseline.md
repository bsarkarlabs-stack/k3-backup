# 01 — Discovery Baseline (Verified Facts)

**Server:** `k3-master`
**How sure are we:** Very. Every number below was actually checked on the real server — nothing
here is a guess.
**What this document is:** Just the facts, as they are right now. Any advice or decisions based on
these facts live in [02 — Backup Strategy](02-backup-strategy.md), not here.

---

## 1. The server itself

| Thing | Value |
|----------|-------|
| Server name | `k3-master` |
| Operating system | Ubuntu 24.04.3 LTS ("Noble") |
| Kernel version | `6.8.0-137-generic` |
| Chip type | 64-bit (x86_64) |
| CPU | 8 cores |
| Memory (RAM) | 22 GB total, about 9.7 GB in use, about 13 GB free |
| Swap space | Turned off |
| How long it's been running | About 3 days at the time we checked |

### Network addresses

| Address | What it's for |
|---------|------|
| `45.90.98.51` | The main public address — how the internet reaches this server |
| `10.10.10.103` | An internal/private address |
| `172.17.0.1` | Docker's internal networking |
| `10.42.1.0`, `10.42.1.1` | Used internally by K3s for pod networking |

---

## 2. Disk space

### The main disk

| Thing | Value |
|----------|-------|
| Device name | `/dev/mapper/ubuntu--vg-ubuntu--lv` |
| Format | ext4 |
| Total size | 97 GB |
| Used | 59 GB |
| Free | **34 GB** |
| % full | 64% |

### The boot disk

| Thing | Value |
|----------|-------|
| Device name | `/dev/vda2` |
| Total size | 2.0 GB |
| Used | About 200 MB |

### File count limit (inodes)

Every filesystem has a limit on how many files it can hold, separate from how much space they
take up. Here's where we stand:

| Thing | Value |
|----------|-------|
| Total allowed | About 6.2 million |
| Used | About 2.5 million |
| Free | About 3.7 million |
| % used | 41% |

**Bottom line:** Plenty of room, no problems. **34 GB free** is the number to keep in mind when
deciding how much backup data we can temporarily store on this server before sending it to S3.

---

## 3. K3s (our Kubernetes)

```text
k3s version v1.34.5+k3s1
go version   go1.24.13
```

| Thing | Value |
|----------|-------|
| Program location | `/usr/local/bin/k3s` |
| Program size | About 72 MB |
| Managed by | systemd, unit file `/etc/systemd/system/k3s.service` |
| Currently | Running, and set to start automatically on boot |
| Runs as | The `root` user |
| Start command | `/usr/local/bin/k3s server` |
| If it crashes | Restarts automatically after 5 seconds |

We checked — there's no sign that K3s is pointed at some separate external database. It manages
its own data.

---

## 4. How the cluster is set up

```text
NAME        STATUS   ROLES           VERSION
k3-master   Ready    control-plane   v1.34.5+k3s1
```

| Thing | Value |
|----------|-------|
| Type of cluster | Single server only |
| Main/control server | `k3-master` |
| Other worker servers | None — this is the only one |
| Can it survive this server going down? | **No** — there's no backup server to take over |
| Current health | `Ready` (healthy) |

---

## 5. Where K3s stores its data — **SQLite**

### Location

```text
/var/lib/rancher/k3s/server/db/
├── state.db        ~64 MB
├── state.db-wal    ~27 MB
├── state.db-shm    ~160 KB
└── etcd/           (basically empty, just a name file)
```

We confirmed this is a **SQLite database** — a lightweight, single-file type of database (not a
big separate database server). All together it's about **91 MB**.

### The "etcd" backup feature — turned off

Kubernetes clusters sometimes use something called `etcd` as their database, which comes with its
own built-in snapshot/backup tool. We checked, and it's turned off here:

```console
$ sudo k3s etcd-snapshot ls
Error: etcd datastore disabled
```

**In plain words: the normal `k3s etcd-snapshot` backup command will not work on this server**,
because we're using SQLite instead of etcd. We need a different backup method (see
[Backup Strategy §4](02-backup-strategy.md#4-job-1--the-k3s-server-backup)).

### No external database either

We checked for PostgreSQL, MySQL, or an external etcd server being used as K3s's database.
Found none. K3s manages its own SQLite file, right there on this server.

### Why this matters: the database is "live"

SQLite is actively writing to a "WAL" file (Write-Ahead Log — basically a scratchpad it uses
before saving changes permanently). That means: **just copying `state.db` with `cp` is NOT a safe
backup** — the `-wal` and `-shm` files next to it hold part of the live data, and a copy taken
mid-write can capture a torn page.

The fix is not to copy all three files. It's to use SQLite's **online backup API**, which reads a
consistent view of the database and folds the WAL into a single output file. That's what
[Job 1](02-backup-strategy.md#4-job-1--the-k3s-server-backup) does, and it's why a restore places
only `state.db` and deletes any `-wal`/`-shm` left behind.

---

## 6. K3s's configuration files

```text
/etc/rancher/k3s/          (12 KB total — tiny)
├── k3s.yaml               ~2.9 KB
└── registries.yaml        ~180 bytes
```

Note: **there is no `/etc/rancher/k3s/config.yaml` file** on this server (some setups have one,
this one doesn't).

---

## 7. The server's secret access token

| Thing | Value |
|----------|-------|
| Location | `/var/lib/rancher/k3s/server/token` |
| Size | 109 bytes |
| Who can access it | Only `root` |
| File permissions | `0600` (locked down — only the owner can read/write it) |
| How important is it | **Extremely — this is a top-priority secret** |

We have never looked inside this file, printed it, or copied its contents anywhere. That should
stay true — we only need to know *where* it is, never *what's inside it*.

---

## 8. How much disk space K3s actually uses

| Folder | Size | Notes |
|------|------|-------|
| `/var/lib/rancher/k3s/agent` | ~43 GB | Downloaded container images + cache. **Not something we need to back up** — it can be re-downloaded anytime. |
| `/var/lib/rancher/k3s/storage` | ~7.8 GB | Data saved by our apps (like Prometheus's metrics) |
| `/var/lib/rancher/k3s/data` | ~233 MB | K3s's own extracted program files — also replaceable by reinstalling |
| `/var/lib/rancher/k3s/server` | ~92 MB | **The actual important stuff** — certificates, database, keys |
| **Total** | **~51 GB** | |
| ↳ just the database inside `server` | ~91 MB | |

**Bottom line:** Backing up the *entire* `/var/lib/rancher/k3s` folder as one big archive would
be the wrong approach — 43 of the 51 GB is just downloaded container images that we don't need to
save. The stuff that's actually irreplaceable is under 100 MB.

---

## 9. Where app data files are stored

| Thing | Value |
|----------|-------|
| Storage type used | `local-path` (the default option, and it's what's active here) |
| Who manages it | A built-in tool called `rancher.io/local-path` |
| What happens if a data volume is deleted | **It's gone — deleted, not recoverable** |
| When does storage get created | Only once something actually needs to use it |
| Where the files actually live on disk | `/var/lib/rancher/k3s/storage` |
| Is the tool that manages this running | Yes |

⚠️ **Important:** because deleting a data volume permanently deletes its data (no safety net), if
someone deletes the wrong thing by accident, backups are the only way to get it back.

---

## 10. What's actually using storage right now

We found 6 data volumes in use, all in the `monitoring` namespace (the section of the cluster
where our monitoring tools live). All of them are working normally (`Bound`).

| What it's for | How much space it's allowed | How much it's actually using |
|-----|------------:|-------------:|
| Prometheus (metrics) | 20 GB | ~5.5 GB |
| Loki / MinIO (log storage) | 20 GB | ~2.2 GB |
| Loki Backend | 10 GB | ~264 KB |
| Loki Write | 10 GB | ~9.6 MB |
| Grafana (dashboards) | 5 GB | ~50 MB |
| Alertmanager (alerts) | 2 GB | ~12 KB |
| *(Traefik — no data volume)* | — | ~28 KB |
| **Total** | **67 GB allowed** | **~7.8 GB actually used** |

Prometheus and Loki/MinIO together make up almost all of the real usage.

---

## 11. Which apps use which storage

| App group | Has its own data volume? | What that means |
|----------------|-----|------------------|
| Monitoring stack (the 6 above) | Yes | We need to back up their actual data |
| `cow-dev`, `cow-staging` | **No** | These apps don't save anything to disk — they can be rebuilt just by redeploying from Git |
| `sbe-dev`, `sbe-staging`, `sbe-uat` | **No** | Same as above |

**Bottom line:** Backing up our apps and backing up monitoring data are two completely separate
problems, and we can solve them with different tools.

---

## 12. Databases running inside our apps

We checked every container image for signs of PostgreSQL, MySQL, MariaDB, Redis, MongoDB,
Elasticsearch, or OpenSearch.

| What we found | Details |
|-------|--------|
| ArgoCD's own Redis | Used internally by ArgoCD — **has no data volume**, so nothing to back up there |
| PostgreSQL / MySQL / MariaDB / MongoDB | **None found anywhere** |

**Bottom line: our apps don't run their own database inside the cluster.** We don't need to worry
about backing up an app database — there isn't one.

---

## 13. ArgoCD (deploys our apps automatically from Git)

The ArgoCD section exists and all its main pieces are running fine:

```text
argocd-application-controller
argocd-applicationset-controller
argocd-dex-server
argocd-notifications-controller
argocd-redis
argocd-repo-server
argocd-server
```

### App health, as we found it

**Working fine** — our real, important apps:

```text
cow-dev-cow-product-service      sbe-dev-admin-api
cow-dev-cow-service              sbe-dev-background-worker
cow-staging-cow-web              sbe-staging-bridge-api
                                 sbe-uat-admin-api
                                 sbe-uat-pulse-broker-api
```

**Already broken before we even started** — just demo/test apps, not real ones:

| App | State |
|-------------|-------|
| `demo-app` | Not synced / missing |
| `nginx-app` | Synced, but unhealthy |
| `nginx-app-dev` | Not synced, unhealthy |
| `nginx-app11` | Not synced, unhealthy |

> ⚠️ **Important:** these four were already broken before any backup work started. When we
> eventually test a restore, don't mistake these for something the restore broke — they were
> already like this.

---

## 14. K3s's own built-in setup files

```text
/var/lib/rancher/k3s/server/manifests/     (~68 KB total)
├── coredns.yaml
├── runtimes.yaml
├── metrics-server/*
├── local-storage.yaml
├── traefik-helmchartconfig.yaml    ← someone edited this one by hand
├── ccm.yaml
├── traefik.yaml
└── rolebindings.yaml
```

We noticed `traefik-helmchartconfig.yaml` has an older "last modified" date than the others,
which is a sign someone manually edited it at some point. That makes it the one file here that
can't just be regenerated automatically — worth double-checking before ever overwriting it.

---

## 15. Existing backups — **there are none**

| What we checked | What we found |
|-------|--------|
| Scheduled tasks for root | None set up |
| A backup job for K3s | None |
| A snapshot schedule for K3s | None |
| Any backup-related scheduled task | Only one unrelated to K3s — a routine Ubuntu package-list backup |
| Is K3s itself running | Yes, and set to start on boot |

```text
Automatic K3s backup     NOT set up
SQLite backup            NOT set up
App data backup          NOT set up
Copy stored off the server   NOT set up
Restore ever tested      NEVER
```

---

## 16. Tools already installed on the server

| Tool | Installed? |
|------|:-------:|
| `rsync` (file copying tool) | ✅ Yes |
| `aws` (Amazon's command-line tool) | ✅ Yes |
| `tar` (for making archive files) | ✅ Yes |
| `gzip` (for compressing files) | ✅ Yes |
| `rclone` (cloud file sync tool) | ❌ No |
| `sqlite3` (command-line tool for SQLite) | ❌ No |

The missing `sqlite3` tool matters: doing a safe backup of a live SQLite database requires using
its proper "backup" feature — not just copying the file. We do this using Python's built-in
`sqlite3` module instead (same feature), so nothing new needs installing. See
[Backup Strategy §4](02-backup-strategy.md#4-job-1--the-k3s-server-backup).

---

## 17. Who hosts this server — **not fully confirmed at first, later resolved**

```console
$ curl http://169.254.169.254/latest/meta-data/instance-id
AWS EC2 metadata not available
```

This told us the server is **not** an Amazon AWS virtual machine (even though the `aws` command-line
tool happens to be installed — that doesn't mean AWS hosts it). This doesn't stop us from using
Amazon S3 as our backup storage though — we can still send backups there over the internet, we
just can't use any AWS-specific shortcuts for hosting-level snapshots.

*(This was later confirmed: the actual hosting provider is Datalix, and we're treating it as an
on-premise-style server with no automatic hosting-level snapshot feature available.)*

---

## 18. How complete is this fact-finding?

| Item | Status |
|------|--------|
| Server hardware / OS / CPU / memory / disk | ✅ Fully checked |
| K3s version / service / setup | ✅ Fully checked |
| Is the control server healthy | ✅ Fully checked |
| What database K3s uses | ✅ SQLite, confirmed |
| Is etcd's snapshot feature usable here | ✅ Confirmed: no, it's disabled |
| Any external database | ✅ Confirmed: none |
| SQLite file location / size / live-write behavior | ✅ Fully checked |
| The server's secret token + who can read it | ✅ Fully checked |
| K3s's config files and built-in setup files | ✅ Fully checked |
| Data volumes in use | ✅ Fully checked |
| How much data volumes are actually using | ✅ Fully checked |
| Which apps use which data volumes | ✅ Fully checked |
| Databases running inside our own apps | ✅ Fully checked |
| ArgoCD health and app list | ✅ Fully checked |
| Existing scheduled backups | ✅ Checked — there are none |
| Required tools installed | ✅ Fully checked |
| **Who hosts this server** | ✅ Resolved — Datalix, on-premise style, no hosting-level snapshots |
| **The server's network/firewall setup** | ✅ Captured automatically by Job 1 as plain text in `host-facts/` |
| **List of installed system packages** | ✅ Same — `dpkg --get-selections` is in `host-facts/` |
| **What's inside the `server/tls/` folder** | ⚠️ **Not checked file-by-file yet** |
| **What's inside the `server/cred/` folder** | ⚠️ **Not checked file-by-file yet** |
| **Where our HTTPS certificate actually comes from** | ⚠️ **Not confirmed yet — this is the blocking one** |
| **Is K3s encrypting Secrets inside its own database?** | ⚠️ **Not checked yet** |

The ⚠️ items are tracked in [05 — Gaps & Open Questions](05-gaps-and-open-questions.md). The whole
of `tls/` and `cred/` is backed up either way — the open question is whether we've confirmed that
by looking, not whether the backup covers it.

---

## Summary, in plain words

`k3-master` is **one single server** running Ubuntu 24.04.3, using K3s version `v1.34.5+k3s1`,
with a simple built-in **SQLite** database (no separate etcd, no external database). The truly
critical data — the database plus certificates — is small, under 100 MB. The K3s folder looks
big (~51 GB) but that's mostly just downloaded container images (~43 GB) that don't need
backing up. Six data volumes hold our monitoring data (about 7.8 GB total, mostly Prometheus and
Loki). Our real apps (SBE and COW) don't store anything on disk — they're rebuilt automatically
from Git through ArgoCD. **Right now, there is no backup of any kind set up.** The server's
secret access token is stored safely, locked down to root-only access.
