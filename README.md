# k3-backup

Disaster-recovery documentation, backup strategy, and implementation tracking for the
single-node K3s cluster **`k3-master`**.

> **Private repository.** These documents contain server IP addresses, filesystem paths,
> and infrastructure topology. They contain **no secrets, tokens, or key material** — and
> must never be made to.

## Goal

> Fresh Ubuntu Server → Install compatible K3s → Restore backup → Restore workloads/data → Validate production.

## Documents

| # | Document | What it covers |
|---|----------|----------------|
| 01 | [Discovery Baseline](docs/01-discovery-baseline.md) | Verified state of `k3-master` — host, K3s, datastore, storage, workloads. The authoritative fact base. |
| 02 | [Backup Strategy](docs/02-backup-strategy.md) | The nine backup components, three recovery tracks, S3 layout, retention, alerting. |
| 03 | [Restore Runbook](docs/03-restore-runbook.md) | Ordered fresh-server → production recovery procedure. |
| 04 | [Implementation TODO](docs/04-implementation-todo.md) | Phased build plan. Mirrored into GitHub Issues. |
| 05 | [Gaps & Open Questions](docs/05-gaps-and-open-questions.md) | What discovery did not establish and must not be assumed. |
| 06 | [Developer Access](docs/06-developer-access.md) | SSH deploy-key setup for cloning and pushing to this repo. |
| 07 | [Phase 0 & 1 Execution Runbook](docs/07-phase-0-1-execution.md) | Copy-paste commands to build Phases 0 and 1 on the live server, with a per-stage downtime risk register, verification after every step, and rollback. |

## Scripts

| Path | Purpose |
|------|---------|
| [`scripts/k3s-track-a-backup.sh`](scripts/k3s-track-a-backup.sh) | Track A backup — SQLite online-backup snapshot, server identity, config, manifests, node OS config, image manifest. Read-only against K3s; never restarts it. |
| [`scripts/systemd/`](scripts/systemd/) | `k3s-backup@.service` plus the 6-hourly `db` and daily `full` timers. |

## Current status

| Area | Status |
|------|--------|
| Discovery baseline | ✅ Verified |
| Backup strategy design | ✅ Documented |
| Restore runbook | ✅ Documented (untested) |
| S3 bucket + IAM | ⏳ Not created |
| Cluster-state backup automation | ⏳ Not built |
| Velero (K8s resources + PVC data) | ⏳ Not installed |
| ArgoCD export automation | ⏳ Not built |
| Retention lifecycle rules | ⏳ Not configured |
| Failure alerting | ⏳ Not configured |
| Restore drill | ⏳ Never performed |

## Issue index

Work is tracked as GitHub Issues. **Issue numbers are not sequential by phase** — they were
created out of order.

### Implementation phases

| Phase | Issue | Priority |
|-------|-------|----------|
| 0 — Foundations: S3 bucket, IAM, sqlite3 | [#9](../../issues/9) | P0 |
| 1 — Track A: node & cluster-state backup | [#10](../../issues/10) | P0 |
| 2 — Track B: Velero resources + PVC data | [#11](../../issues/11) | P0 |
| 3 — Track C: ArgoCD export & GitOps audit | [#1](../../issues/1) | P1 |
| 4 — Retention rules & failure alerting | [#2](../../issues/2) | P1 |
| 5 — Full restore drill | [#12](../../issues/12) | P1 |
| 6 — Close known gaps | [#3](../../issues/3) | P2 |

### Gaps

| Gap | Issue | Priority |
|-----|-------|----------|
| Backups contain plaintext Secrets; bucket must be SSE-KMS encrypted | [#14](../../issues/14) | **P0** |
| Ingress TLS certificate source unverified | [#4](../../issues/4) | P1 |
| Node-level OS config not captured | [#5](../../issues/5) | P1 |
| `server/tls/` and `server/cred/` never enumerated | [#8](../../issues/8) | P1 |
| ~~Hosting provider unconfirmed~~ → Datalix, on-premise, **no snapshot fallback** | [#13](../../issues/13) | ✅ Resolved |
| OS package list not captured | [#6](../../issues/6) | P2 |
| Single-region S3, no replication | [#15](../../issues/15) | P2 |
| Keep DR docs in Git, never only on the server | [#7](../../issues/7) | P2 |
| No owner for credential rotation | [#16](../../issues/16) | P2 |

**Start here:** [#9](../../issues/9) → [#10](../../issues/10) / [#11](../../issues/11) → [#1](../../issues/1) → [#2](../../issues/2) → [#12](../../issues/12)

Issues #9 and #10 have a command-by-command runbook: [07 — Phase 0 & 1 Execution](docs/07-phase-0-1-execution.md).

## Cluster at a glance

```text
Host          k3-master
OS            Ubuntu 24.04.3 LTS (Noble), kernel 6.8.0-137-generic, x86_64
K3s           v1.34.5+k3s1
Topology      Single node, control-plane only, no HA
Datastore     SQLite  (embedded etcd DISABLED, no external datastore)
Storage       local-path provisioner → /var/lib/rancher/k3s/storage
GitOps        ArgoCD (SBE / COW workloads)
Monitoring    Prometheus, Loki, Grafana, Alertmanager, MinIO
```

## The single most important correction

`/etc/rancher/k3s` is **configuration**, not the cluster's identity. Full recovery requires
`/var/lib/rancher/k3s/server/` as one unit — including `tls/` and `cred/`, which the original
discovery pass did not capture. See [Backup Strategy §2](docs/02-backup-strategy.md#2-the-correction-that-changes-the-whole-plan).

## Working agreement

- This documentation **must not live only on `k3-master`** — it would disappear in exactly
  the scenario it exists to solve. This repository is the canonical copy.
- Backup scripts, once written, live in `scripts/` in this repo and are deployed from here.
- Every phase in the TODO has a corresponding GitHub Issue. Close the issue, tick the doc.
