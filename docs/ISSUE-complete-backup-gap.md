# GitHub issue draft — copy Title + Body into a new issue

Repo: `bsarkarlabs-stack/k3-backup`  
Labels (if they exist): `P0`, `enhancement`  
Do **not** paste secrets, AWS keys, cert bodies, or token contents into the issue.

---

## Title

```
Add Velero — current backup script has no Velero; K8s resources + PVC data are not backed up the standard way
```

---

## Body (copy from here)

### Problem

`scripts/k3s-track-a-backup.sh` **does not include Velero**.

Today the script only does **Track A** (K3s node files → S3):

- SQLite `state.db`
- `tls/` / `cred/` / token
- `/etc/rancher/k3s`
- manifests, node config, image list

There is **no Velero install, no Velero schedule, no Velero backup of Secrets / Deployments / DaemonSets / PVCs**.

That is not Kubernetes best practice. A tar of disk + SQLite can rebuild **this same node**. It is not the standard way to back up what is **running inside the cluster** (workloads, hand-made SSL/AWS Secrets, monitoring PVC data) onto the same server **or** a new server.

---

### Goal

Keep the existing script for **K3s itself**. Add **Velero** for everything that is running:

- Secrets (hand-created SSL, hand-attached AWS creds, registry, ArgoCD)
- Deployments, DaemonSets, StatefulSets, Services, Ingress, ConfigMaps
- PVC data (Prometheus, Loki, Grafana, Alertmanager)
- Restore from S3 onto **same server** or **new server**

Two pieces only. Same S3 bucket. No extra “tracks” in the docs, no second backup product besides Velero.

| Layer | Tool | Status now |
|-------|------|------------|
| K3s brain (db + cluster identity) | `k3s-track-a-backup.sh` | Script exists |
| Running cluster (resources + PVC data) | **Velero** | **Missing — this issue** |

---

### Why Velero (not only the script)

- Kubernetes-standard backup for objects + volumes.
- Hand-made SSL Secrets and AWS Secrets are captured as Kubernetes Secrets (Git does not have them).
- `local-path` has no CSI snapshots. Velero **node-agent** (restic/kopia) is the supported PVC path. A raw tar of `/var/lib/rancher/k3s/storage/` only works if PV folder names stay the same (same `state.db`). On a **fresh empty** K3s, names change and tar does not land correctly.
- One deleted Secret/Deployment can be restored without rolling back the whole SQLite file.
- ArgoCD objects restore with Velero; then Git sync brings apps. Same on old or new server.

The script is still required. **Velero cannot back up K3s `tls/` / `cred/` / SQLite.** Both are needed.

---

### What the current script already covers (keep this)

File: `scripts/k3s-track-a-backup.sh` — do not replace it.

| Already backed up | Why |
|-------------------|-----|
| K3s SQLite (`state.db` via online backup API) | Control-plane datastore |
| `server/tls`, `server/cred`, `token` | Cluster identity |
| `/etc/rancher/k3s` + `k3s.service` | K3s config |
| Static manifests | Addons |
| Node OS config | New Ubuntu box (IP, SSH, UFW) |
| Image list | What to pull |
| S3 upload with KMS + checksums | Off-server copy |

---

### What to do in this issue

#### 1. Install Velero — **must have**

- Velero + AWS S3 plugin, same bucket as the script (prefix e.g. `velero/`).
- Enable **node-agent** (restic or kopia). Required because StorageClass is `local-path` (no CSI snapshot).
- Daily schedule, **all namespaces** (not only app namespaces).
- Bucket must stay **SSE-KMS + private**. Velero backups contain plaintext Secrets.

#### 2. Prove it actually backs up what we care about

- Confirm TLS Secrets and AWS-related Secrets are in the backup (names only in logs/docs — never secret values).
- Confirm all six monitoring PVCs are included.
- Confirm Deployments / DaemonSets across namespaces are restorable.
- One small test restore of a non-critical object (not production wipe).

#### 3. Restore: same server and new server (from S3)

**Same server**

1. Restore K3s from script backup if the datastore/identity is damaged.
2. Velero restore for resources + PVC data as needed.
3. ArgoCD starts / Git-syncs apps.

**New server**

1. Fresh Ubuntu.
2. Install **exact same** K3s version (`v1.34.5+k3s1`).
3. Restore script backup (db + identity + config) **or** install empty K3s and Velero-restore workloads — prefer documenting one primary path and testing it.
4. Install Velero pointed at the same bucket; restore the backup.
5. ArgoCD Git-syncs apps. SSL + AWS Secrets must be present (from Velero / datastore).

#### 4. Optional

Keep last 1–2 local copies of the **script** artifacts under `/var/backups/k3s`. S3 remains the DR copy. Velero backups stay in S3.

---

### Out of scope (still skip — over-engineering)

- A third backup system besides script + Velero
- Required `argocd admin export` job (ArgoCD is in the datastore + Velero; apps are in Git)
- Backing up `/var/lib/rancher/k3s/agent/` (~43 GB image cache)
- Replacing the existing Track A script with Velero (Velero does not replace K3s identity backup)

---

### Implementation notes

- Do not stop/restart K3s to install Velero if it can be avoided; install as in-cluster components.
- Reuse existing S3 bucket + IAM; do not invent a second bucket unless access must be split.
- Update restore docs in plain language: script = K3s, Velero = running workloads + disks.

---

### Acceptance criteria

- [ ] Issue and docs state clearly: **current script has no Velero**
- [ ] Velero installed on the cluster, S3 backend, node-agent enabled
- [ ] Daily scheduled backup of all namespaces + monitoring PVCs
- [ ] Hand-created SSL Secrets and hand-attached AWS creds appear in Velero backup
- [ ] Deployments, DaemonSets, and other running objects are in the backup
- [ ] Restore from S3 documented for **same server** and **new server**
- [ ] After restore, ArgoCD syncs apps from Git
- [ ] Monitoring history present after Velero PVC restore (Grafana/Prometheus not empty)
- [ ] Existing `k3s-track-a-backup.sh` still runs (K3s db + identity still backed up)

---

### Why this issue exists

The script is a **K3s file backup**. It is not Velero.

Without Velero we do not have a standard Kubernetes backup of Secrets, Deployments, DaemonSets, and PVC data. That gap must be closed so restore on the same server or a new server brings back the same running cluster.
