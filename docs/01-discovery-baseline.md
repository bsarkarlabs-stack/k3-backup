# 01 — Discovery Baseline (Verified)

**Host:** `k3-master`
**Status:** Authoritative. Every value below was observed directly on the server.
**Scope note:** This document records *what is*. It makes no recommendations — those live in
[02 — Backup Strategy](02-backup-strategy.md).

---

## 1. Host

| Property | Value |
|----------|-------|
| Hostname | `k3-master` |
| OS | Ubuntu 24.04.3 LTS (Noble) |
| Kernel | `6.8.0-137-generic` |
| Architecture | `x86_64` |
| CPU | 8 vCPU |
| Memory | 22 GiB total / ~9.7 GiB used / ~13 GiB available |
| Swap | Disabled |
| Uptime at discovery | ~3 days |

### Network addresses

| Address | Role |
|---------|------|
| `45.90.98.51` | Primary public / server IP |
| `10.10.10.103` | Private / server-side IP |
| `172.17.0.1` | Docker bridge |
| `10.42.1.0`, `10.42.1.1` | K3s pod CIDR / CNI |

---

## 2. Disk & filesystem

### Root filesystem

| Property | Value |
|----------|-------|
| Device | `/dev/mapper/ubuntu--vg-ubuntu--lv` |
| Type | ext4 |
| Size | 97 G |
| Used | 59 G |
| Available | **34 G** |
| Usage | 64 % |

### Boot

| Property | Value |
|----------|-------|
| Device | `/dev/vda2` |
| Size | 2.0 G |
| Used | ~200 M |

### Inodes

| Property | Value |
|----------|-------|
| Total | ~6.2 M |
| Used | ~2.5 M |
| Free | ~3.7 M |
| Usage | 41 % |

**Conclusion:** No disk pressure, no inode pressure. **34 GB free** is the working constraint
for any local backup staging or retention design.

---

## 3. K3s

```text
k3s version v1.34.5+k3s1
go version   go1.24.13
```

| Property | Value |
|----------|-------|
| Binary | `/usr/local/bin/k3s` |
| Binary size | ~72 MB |
| Systemd unit | `/etc/systemd/system/k3s.service` |
| Service state | `active`, `enabled` |
| Runs as | `root` |
| Start command | `/usr/local/bin/k3s server` |
| Restart policy | `Restart=always`, `RestartSec=5s` |

No external-datastore argument was present in the observed service command.

---

## 4. Cluster topology

```text
NAME        STATUS   ROLES           VERSION
k3-master   Ready    control-plane   v1.34.5+k3s1
```

| Property | Value |
|----------|-------|
| Cluster type | Single-node K3s |
| Control plane | `k3-master` |
| Worker nodes | None discovered separately |
| High availability | **No** |
| Node status at discovery | `Ready` |

---

## 5. Datastore — **SQLite**

### Location

```text
/var/lib/rancher/k3s/server/db/
├── state.db        ~64 MB
├── state.db-wal    ~27 MB
├── state.db-shm    ~160 KB
└── etcd/           (contains only: name)
```

`file state.db` → **SQLite 3.x database**. Total datastore footprint ≈ **91 MB**.

### Embedded etcd — DISABLED

```console
$ sudo k3s etcd-snapshot ls
Error: etcd datastore disabled
```

The snapshot directory does not exist. **`k3s etcd-snapshot` is therefore not an applicable
backup mechanism on this server.**

### External datastore — none

No evidence of PostgreSQL, MySQL, or external etcd serving as the K3s datastore.

### WAL implication

SQLite is actively using write-ahead logging. `state.db` alone is **not** a complete backup —
the `-wal` and `-shm` files are part of the consistent state. The entire
`/var/lib/rancher/k3s/server/db/` directory is the recovery unit.

---

## 6. K3s configuration files

```text
/etc/rancher/k3s/          (12 K total)
├── k3s.yaml               ~2.9 K
└── registries.yaml        ~180 B
```

**`/etc/rancher/k3s/config.yaml` does not exist** on this server.

---

## 7. Server token

| Property | Value |
|----------|-------|
| Path | `/var/lib/rancher/k3s/server/token` |
| Size | 109 bytes |
| Owner / group | `root:root` |
| Permissions | `0600` (`-rw-------`) |
| Classification | **P0 / Critical, sensitive** |

Token *content* has never been displayed, logged, or exported during discovery, and must not be.

---

## 8. K3s directory usage

| Path | Size | Notes |
|------|------|-------|
| `/var/lib/rancher/k3s/agent` | ~43 GB | Container images, runtime cache — **not DR data** |
| `/var/lib/rancher/k3s/storage` | ~7.8 GB | local-path PVC data |
| `/var/lib/rancher/k3s/data` | ~233 MB | Extracted K3s binaries |
| `/var/lib/rancher/k3s/server` | ~92 MB | Control-plane state — **the critical part** |
| **Total** | **~51 GB** | |
| ↳ `/var/lib/rancher/k3s/server/db` | ~91 MB | |

**Conclusion:** `tar` of the whole `/var/lib/rancher/k3s` tree is the wrong design. 43 GB of the
51 GB is reproducible agent/runtime cache. The genuinely irreplaceable control-plane state is
under 100 MB.

---

## 9. Persistent storage backend

| Property | Value |
|----------|-------|
| StorageClass | `local-path` (default) |
| Provisioner | `rancher.io/local-path` |
| Reclaim policy | **`Delete`** |
| Volume binding mode | `WaitForFirstConsumer` |
| Physical path | `/var/lib/rancher/k3s/storage` |
| Provisioner pod | Running |

⚠️ Reclaim policy `Delete` means PVC deletion destroys the underlying data. This shapes the
accidental-deletion recovery scenario.

---

## 10. PVC inventory

Six bound PVCs, all in namespace `monitoring`, all `RWO` / `local-path` / `Filesystem` / `Bound`.
Six corresponding PVs exist, all `Bound`, all reclaim policy `Delete`.

| PVC | Provisioned | Actual usage |
|-----|------------:|-------------:|
| Prometheus | 20 Gi | ~5.5 GB |
| Loki MinIO | 20 Gi | ~2.2 GB |
| Loki Backend | 10 Gi | ~264 KB |
| Loki Write | 10 Gi | ~9.6 MB |
| Grafana | 5 Gi | ~50 MB |
| Alertmanager | 2 Gi | ~12 KB |
| *(Traefik, non-PVC)* | — | ~28 KB |
| **Total** | **67 Gi provisioned** | **~7.8 GB actual** |

Prometheus and Loki MinIO together account for almost all persistent local data.

---

## 11. Workload → PVC mapping

| Workload group | PVC | Implication |
|----------------|-----|-------------|
| Monitoring stack (6 above) | Yes | Data recovery matters |
| `cow-dev`, `cow-staging` | **`<none>`** | Stateless — GitOps-recoverable |
| `sbe-dev`, `sbe-staging`, `sbe-uat` | **`<none>`** | Stateless — GitOps-recoverable |

**Conclusion:** Application recovery and monitoring-history recovery are cleanly separable
concerns and should be handled by different mechanisms.

---

## 12. Databases inside the cluster

Pod images were searched for PostgreSQL, MySQL, MariaDB, Redis, MongoDB, Elasticsearch, OpenSearch.

| Found | Detail |
|-------|--------|
| ArgoCD Redis | `public.ecr.aws/docker/library/redis:8.2.3-alpine` — **no persistent PVC mapped** |
| PostgreSQL / MySQL / MariaDB / MongoDB | **None found** |

No application database runs inside K3s.

---

## 13. ArgoCD

Namespace exists. All core pods `Running`:

```text
argocd-application-controller
argocd-applicationset-controller
argocd-dex-server
argocd-notifications-controller
argocd-redis
argocd-repo-server
argocd-server
```

### Application health at discovery

**Synced / Healthy** — primary workloads:

```text
cow-dev-cow-product-service      sbe-dev-admin-api
cow-dev-cow-service              sbe-dev-background-worker
cow-staging-cow-web              sbe-staging-bridge-api
                                 sbe-uat-admin-api
                                 sbe-uat-pulse-broker-api
```

**Pre-existing unhealthy state** — demo/non-primary apps:

| Application | State |
|-------------|-------|
| `demo-app` | OutOfSync / Missing |
| `nginx-app` | Synced / Degraded |
| `nginx-app-dev` | OutOfSync / Degraded |
| `nginx-app11` | OutOfSync / Degraded |

> ⚠️ **These conditions existed before any backup work began.** During a restore drill they must
> not be mistaken for restore failures.

---

## 14. K3s static manifests

```text
/var/lib/rancher/k3s/server/manifests/     (~68 K)
├── coredns.yaml
├── runtimes.yaml
├── metrics-server/*
├── local-storage.yaml
├── traefik-helmchartconfig.yaml    ← older timestamp than the rest
├── ccm.yaml
├── traefik.yaml
└── rolebindings.yaml
```

`traefik-helmchartconfig.yaml` carries an older timestamp than the auto-generated defaults,
indicating manual modification. It is the one file here that is genuinely irreplaceable.

---

## 15. Existing backup automation — **none**

| Check | Result |
|-------|--------|
| Root crontab | None |
| K3s backup cron | None |
| K3s snapshot timer | None |
| Backup-related systemd timer | Only `dpkg-db-backup.timer` (OS package DB — **not** K3s) |
| K3s service | `enabled` |

```text
K3s automated backup   NOT configured
SQLite backup          NOT configured
PVC backup             NOT configured
Offsite backup         NOT configured
Restore test           NEVER performed
```

---

## 16. Installed tooling

| Tool | Present |
|------|:-------:|
| `rsync` | ✅ |
| `aws` (CLI) | ✅ |
| `tar` | ✅ |
| `gzip` | ✅ |
| `rclone` | ❌ |
| `sqlite3` (CLI) | ❌ |

The absent `sqlite3` CLI matters — a consistent SQLite backup requires the `.backup` API, not a
file copy. See [Backup Strategy §3, component 1](02-backup-strategy.md#component-1--k3s-datastore).

---

## 17. Hosting provider — **Datalix, treated as on-premise**

```console
$ curl http://169.254.169.254/latest/meta-data/instance-id
AWS EC2 metadata not available
```

Confirmed by the operator: the server is hosted with **Datalix**, on a public IP, and is to be
treated operationally as an **on-premise / bare-metal server**. The AWS CLI being installed does
not imply the server runs on AWS — it does not.

| Property | Value |
|----------|-------|
| Provider | Datalix |
| Treat as | On-premise / bare metal |
| Hypervisor snapshot fallback | **None available** |
| S3 as a remote destination | Still valid — needs only credentials and outbound HTTPS |

> ⚠️ **This is the most consequential fact in this document.** There is no provider-level snapshot,
> no EBS volume backup, no console "restore VM" button. If this box is lost, the *only* path back
> is the S3 backup set plus [03 — Restore Runbook](03-restore-runbook.md). Every "belt and
> suspenders" assumption elsewhere in these docs should be read as absent here.

---

## 18. Discovery completeness

| Item | Status |
|------|--------|
| Host / OS / CPU / RAM / disk | ✅ Complete |
| K3s version / service / topology | ✅ Complete |
| Control-plane health | ✅ Complete |
| Datastore type | ✅ SQLite |
| Embedded etcd | ✅ Confirmed disabled |
| External datastore | ✅ No evidence |
| SQLite path / size / WAL | ✅ Complete |
| Server token + permissions | ✅ Complete |
| K3s config + static manifests | ✅ Complete |
| PVC / PV / StorageClass inventory | ✅ Complete |
| PVC actual usage | ✅ Complete |
| Workload → PVC mapping | ✅ Complete |
| In-cluster database discovery | ✅ Complete |
| ArgoCD health + applications | ✅ Complete |
| Existing cron / snapshot backups | ✅ Checked — none |
| Required CLI tooling | ✅ Complete |
| Hosting provider | ✅ Confirmed — Datalix, on-premise, no snapshot fallback |
| **`server/tls/` contents** | ⚠️ **Not enumerated** |
| **`server/cred/` contents** | ⚠️ **Not enumerated** |
| **Node OS config** (netplan, UFW, SSH, NTP) | ⚠️ **Not captured** |
| **Ingress TLS certificate source** | ⚠️ **Not determined** |
| **OS package selections** | ⚠️ **Not captured** |

The remaining ⚠️ items are tracked in [05 — Gaps & Open Questions](05-gaps-and-open-questions.md).

---

## Authoritative summary

`k3-master` is a **single-node Ubuntu 24.04.3 K3s cluster running v1.34.5+k3s1 with SQLite as
its active datastore**. Embedded etcd is disabled; no external datastore exists. Cluster-state
data is small (~91 MB), while total K3s disk usage is ~51 GB because the agent directory
consumes ~43 GB and local persistent volumes ~7.8 GB. Six `local-path` PVCs serve the monitoring
stack, dominated by Prometheus (~5.5 GB) and Loki MinIO (~2.2 GB). SBE and COW application
workloads use no PVCs and are managed through ArgoCD/GitOps. **No K3s backup, SQLite backup,
snapshot schedule, or backup cron is currently configured.** The server token exists securely at
`0600 root:root`.
