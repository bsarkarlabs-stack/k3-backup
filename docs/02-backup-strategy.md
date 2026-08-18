# 02 — Backup Strategy

Built on the verified [Discovery Baseline](01-discovery-baseline.md).

**Recovery goal:**
> Fresh Ubuntu Server → Install compatible K3s → Restore backup → Restore workloads/data → Validate production.

---

## 1. Scenario → recovery track

Every failure mode maps to one or more of the three recovery tracks defined in §4.

| Scenario | Track | What must exist |
|----------|-------|-----------------|
| Complete server failure | A + B + C | Full stack: server identity, datastore, config, Velero backup, Git/ArgoCD state |
| OS corruption | A | Fresh OS + restored `server/` directory, config, PVC data |
| K3s corruption (binary or DB) | A | Reinstall matching K3s version + restore `db/`, `tls/`, `cred/` |
| Accidental Kubernetes resource deletion | B or C | Velero object-level restore, or ArgoCD re-sync from Git |
| Application deployment failure | C | Git revert + ArgoCD rollback |
| Persistent-volume / data loss | B | Velero + node-agent snapshot of the affected PVC |
| K3s datastore corruption | A | Consistent snapshot of `state.db` / `-wal` / `-shm` |
| Certificate / configuration loss | A | Restore `tls/`, `cred/`, `/etc/rancher/k3s` |
| ArgoCD configuration loss | C | `argocd admin import` from latest export |
| Monitoring configuration loss | C / B | Redeploy from Git if IaC; else restore ConfigMaps via Velero |
| Migration to fresh Ubuntu server | A + B + C | Full [restore runbook](03-restore-runbook.md), executed deliberately |
| Disaster recovery to a new VM | A + B + C | Full restore runbook + DNS / network cutover |

---

## 2. The correction that changes the whole plan

> ### `/etc/rancher/k3s` is configuration. It is **not** the cluster's identity.

The discovery baseline treated the SQLite datastore and the server token as separate line items.
In practice, K3s keeps the entire cryptographic identity of the control plane inside
`/var/lib/rancher/k3s/server/` — and **two of its subdirectories were never captured in
discovery at all**:

| Directory | Contains | Consequence of loss |
|-----------|----------|---------------------|
| `server/tls/` | Cluster CA + every serving / client certificate | A restored node cannot be trusted by existing kubeconfigs or rejoining agents without a full re-issue |
| `server/cred/` | Node password / IPSec key used for node registration | Node identity must be rebuilt from scratch even if the datastore is intact |

**Treat `/var/lib/rancher/k3s/server/` as a single recovery unit** — `db/`, `tls/`, `cred/`,
`token`, and `manifests/` together — not four separate backup line items that happen to live
near each other.

`/etc/rancher/k3s/` is real but secondary: 12 KB of pointers, not the thing being pointed to.

---

## 3. Backup components

Nine categories. Each is backed up differently and restored differently. **Priority reflects how
bad it is to lose, not how large it is.**

### Component 1 — K3s Datastore
**Priority: P0 critical**

The live cluster state. SQLite, actively using WAL — a raw `cp` while K3s runs can capture a
torn write.

```text
/var/lib/rancher/k3s/server/db/
├── state.db
├── state.db-wal
└── state.db-shm
```

| | |
|---|---|
| **Method** | SQLite online backup API (`.backup`) — **not** a raw file copy |
| **Frequency** | Every 6 hours |
| **Destination** | `s3://k3-master-dr/cluster-state/db/` |

> ⚠️ The `sqlite3` CLI is **not installed** on `k3-master`. Install it, or use Python 3's built-in
> `sqlite3` module, which exposes the same backup API. Do not script around `file` output — script
> around the actual backup call.

---

### Component 2 — Node Identity & Certificates
**Priority: P0 critical / sensitive**

The part discovery under-weighted. Not configuration — cryptographic identity.

```text
/var/lib/rancher/k3s/server/
├── tls/     (cluster CA + serving certs)
├── cred/    (node password / IPSec key)
└── token
```

| | |
|---|---|
| **Method** | Full `tar` of the directory, taken alongside the datastore snapshot |
| **Frequency** | Daily, plus on any manual certificate rotation |
| **Destination** | `s3://k3-master-dr/cluster-state/server-identity/` |

> 🔒 Must be encrypted at rest in S3, with access scoped to a single restore role.

---

### Component 3 — K3s Configuration
**Priority: P1**

Small, but it is what tells the restored binary how to behave.

```text
/etc/rancher/k3s/
├── k3s.yaml
└── registries.yaml
/etc/systemd/system/k3s.service
```

| | |
|---|---|
| **Method** | Plain `tar` (~12 KB) — cheap enough to version on every run |
| **Frequency** | Daily, or on change if git-tracked |
| **Destination** | `s3://k3-master-dr/config/` |

---

### Component 4 — Static Manifests
**Priority: P1**

Auto-deployed addons K3s installs on boot: CoreDNS, Traefik, metrics-server, CCM.

```text
/var/lib/rancher/k3s/server/manifests/
├── traefik-helmchartconfig.yaml  ← hand-modified, older timestamp
├── coredns.yaml
├── ccm.yaml
├── local-storage.yaml
└── metrics-server/*
```

| | |
|---|---|
| **Method** | `tar` (~68 KB) |
| **Frequency** | Daily, or on change |
| **Destination** | `s3://k3-master-dr/manifests/` |

> `traefik-helmchartconfig.yaml` has an older timestamp than the rest — someone edited it by hand.
> Worth a diff before every restore, not a blind overwrite.

---

### Component 5 — Kubernetes Resource State
**Priority: P0**

Every object the API server manages, across all namespaces. **Distinct from the SQLite file**
because it restores at the object level, into any cluster, at any K3s version.

```text
Deployments · Services · ConfigMaps · Secrets
RBAC · CRDs · IngressRoutes
(all namespaces, not just application namespaces)
```

| | |
|---|---|
| **Method** | Velero, S3 backend, cluster-wide schedule |
| **Frequency** | Daily |
| **Destination** | `s3://k3-master-dr/velero/` |

> This is what makes a version-migrated or genuinely fresh cluster recoverable. **The SQLite file
> only helps if you rebuild the same node.** Migration and DR-to-new-VM both depend on this
> component, not on component 1.

---

### Component 6 — Persistent Application Data
**Priority: P1**

The six monitoring-stack PVCs. Operationally valuable, but it is history — not primary business
data.

```text
/var/lib/rancher/k3s/storage/
Prometheus ~5.5 GB · Loki MinIO ~2.2 GB
Grafana ~50 MB · Loki Write/Backend · Alertmanager
```

| | |
|---|---|
| **Method** | Velero + node-agent (restic / kopia filesystem backup) |
| **Frequency** | Daily, alongside the resource backup |
| **Destination** | `s3://k3-master-dr/velero/` (bundled) |

> `local-path` has no CSI snapshot capability. Filesystem backup via Velero's node-agent is the
> only supported path. See §6.

---

### Component 7 — Secrets & Registry Credentials
**Priority: P0 sensitive**

`imagePullSecrets`, ingress TLS secrets, ArgoCD repository credentials, application secrets.

```text
kind: Secret  (across all namespaces)
— captured automatically inside the Velero
  resource backup, not as a separate job
```

| | |
|---|---|
| **Method** | Covered by Velero — but the bucket **must** be SSE-KMS encrypted |
| **Frequency** | Daily (with Velero) |

> 🔒 A Velero backup is, among other things, a bundle of plaintext Kubernetes Secrets. Bucket
> encryption and tight IAM are load-bearing here, not optional hardening.

---

### Component 8 — Container Registry Dependency
**Priority: P1**

Nothing above backs up the images themselves. **A perfect resource restore still fails if
upstream images cannot be pulled.**

```text
image manifest: every unique image reference
in use, regenerated on each run
+ registries.yaml (mirror configuration)
```

| | |
|---|---|
| **Method** | Generate image list from live pods each run; consider mirroring critical images to a private registry |
| **Frequency** | Every backup run — cheap to regenerate |
| **Destination** | `s3://k3-master-dr/image-manifest/` |

---

### Component 9 — Git / ArgoCD Recoverability
**Priority: P0 for (b), P2 for (a)**

Two different things:

**(a) The Git repositories** — already durable via GitHub. No additional backup required, but the
remotes and credentials must be documented.

**(b) ArgoCD's own state that Git does not hold:**

```text
argocd-cm · argocd-rbac-cm · argocd-secret
Applications / AppProjects created outside
the app-of-apps pattern
```

| | |
|---|---|
| **Method** | `argocd admin export` → single importable YAML |
| **Frequency** | Daily |
| **Destination** | `s3://k3-master-dr/argocd-export/` |

> Monitoring recoverability splits the same way: configuration-as-code collapses into this
> component; historical metrics and logs are component 6.

---

## 4. Three recovery tracks

Every component belongs to exactly one track. **Recovery never depends on all three succeeding at
once** — that is the point of separating them.

### Track A — Node-level (files on disk)
- Server identity: `tls/`, `cred/`, `token`
- SQLite datastore
- K3s configuration + static manifests
- Node OS configuration *(see [Gaps](05-gaps-and-open-questions.md))*

### Track B — Kubernetes-level (Velero, S3 backend)
- All resources, all namespaces
- Secrets & RBAC
- PVC data via node-agent
- **Works into a fresh cluster or a different K3s version**

### Track C — GitOps-level (Git + ArgoCD)
- SBE / COW application manifests (Git, already durable)
- `argocd admin export`
- Fastest path for application-only recovery

```text
    Track A              Track B              Track C
  Node files          Velero / S3          Git + ArgoCD
      │                    │                    │
      └────────────────────┼────────────────────┘
                           ▼
                 k3-master — recovered
```

---

## 5. S3 storage design

One bucket, prefixed by track and layer. **Lifecycle rules do the retention work** so nothing
depends on a script remembering to delete old backups.

| Setting | Value | Why |
|---------|-------|-----|
| Bucket | `k3-master-dr` | Globally unique names — add a suffix if taken |
| Region | `ap-south-1` (Mumbai) by default | Any region works — ~320 MB/day makes latency a non-factor. Choose on cost and where the team sits. **Cannot be changed after creation.** See [07 Stage C.0](07-phase-0-1-execution.md#c0--pick-a-region-one-line-any-of-these-work). |
| Encryption | SSE-KMS, customer-managed key | [Gap 5](05-gaps-and-open-questions.md#5-secrets-reach-s3-unencrypted-unless-sse-kms-is-configured) — load-bearing, not hardening |
| Versioning | Enabled | Protects against bad overwrites and a compromised write credential |

Created and verified in [07 — Phase 0 & 1 Execution, Stage C](07-phase-0-1-execution.md#stage-c--aws-foundations-local).

```text
s3://k3-master-dr/
├── cluster-state/
│   ├── db/                  SQLite snapshots, every 6h
│   └── server-identity/     tls/, cred/, token — encrypted
├── config/                  /etc/rancher/k3s
├── manifests/               static manifests
├── velero/                  Velero-managed: resources + PVC data
├── argocd-export/           argocd admin export dumps
├── image-manifest/          image inventory, per run
└── node-config/             netplan, ufw, ssh, systemd overrides
```

### Retention matrix

| Layer | Frequency | Retention | Tool |
|-------|-----------|-----------|------|
| Datastore + server identity | every 6 h | 7 daily + 4 weekly + 3 monthly | custom script |
| Config + manifests | daily | 14 daily | custom script |
| Kubernetes resources + PVC data | daily | 14 daily + 8 weekly | Velero |
| ArgoCD export | daily | 14 daily | `argocd admin export` |
| Image manifest | per run | 30 days | custom script |
| Node config | weekly / on change | 4 copies | custom script |

### Bucket hygiene — not an afterthought

- **Least-privilege IAM.** A dedicated user or role scoped only to this bucket:
  `PutObject` / `GetObject` / `ListBucket` on `arn:aws:s3:::k3-master-dr/*`, nothing broader.
- **Block all public access.**
- **Default encryption via SSE-KMS** with a customer-managed key. Velero backups contain
  plaintext Secrets — this is not optional.
- **Versioning on, unconditionally.** Cheapest protection against a bad overwrite or a
  compromised write credential.
- **Separate credentials.** The write credential lives on the server and is used by the systemd
  timers. The read credential is used only during a restore and is held offline.

---

## 6. The persistent-volume gotcha

> ### `tar`-and-copy does **not** restore a `local-path` PVC.

`local-path-provisioner` names each volume's directory after the **PV's generated name**. A fresh
PVC created during restore gets a new PV, a new name, and therefore a new directory — a raw `tar`
of `/var/lib/rancher/k3s/storage/` has nowhere matching to land.

Two ways this actually works:

1. **Velero's node-agent** restores the filesystem data *after* the new PVC/PV is bound; it
   tracks the mapping for you. ← supported path
2. Pre-create PVs with pinned names before the PVC is recreated. ← fragile, manual

This is why component 6 routes through Velero rather than a cron-and-`tar` script like
components 1–4.

Related: the `local-path` StorageClass reclaim policy is **`Delete`**. PVC deletion destroys the
underlying data immediately — there is no orphaned-PV grace period to recover from.

---

## 7. Alerting & verification

**A backup nobody watches is a backup that fails silently.** The monitoring stack already exists
— reuse it instead of adding a new tool.

| Control | Detail |
|---------|--------|
| **Checksum every archive** | SHA-256 each tar/snapshot before upload; store the checksum alongside it. A corrupt upload should fail loud, not surface during an actual restore. |
| **Feed Alertmanager** | Push a `backup_last_success_timestamp` metric from each job. Alert if any track's timestamp is stale by more than 1.5× its own frequency. |
| **Quarterly restore drill** | Run the full [runbook](03-restore-runbook.md) against a throwaway VM every quarter. *A backup that has never been restored is a hypothesis, not a plan.* |
| **Track RTO, not just success/fail** | Time each drill end-to-end. If restore takes longer than the business can tolerate being down, that is a finding — not a footnote. |

---

## 8. What is explicitly **not** backed up

| Path | Size | Why excluded |
|------|------|--------------|
| `/var/lib/rancher/k3s/agent/` | ~43 GB | Container images and runtime cache. Fully reproducible from registries — see component 8 for the manifest that makes that possible. |
| `/var/lib/rancher/k3s/data/` | ~233 MB | Extracted K3s binaries. Recreated by reinstalling the matching K3s version. |

Backing these up would multiply storage cost and backup duration by roughly 500× for no recovery
benefit. This exclusion is a deliberate decision, not an oversight.
