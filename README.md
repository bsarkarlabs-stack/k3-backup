# k3-backup

This repo explains how we back up our server `k3-master` and how we would bring it back to life
if it ever broke, got deleted, or had to move to a new machine.

`k3-master` runs **K3s** (a lightweight version of Kubernetes) and everything on it is important:
our production apps, our monitoring (Prometheus, Grafana, Loki), and ArgoCD (which deploys our
apps from Git).

> **This is a private repo.** It has server IP addresses, folder paths, and how our system is
> laid out. It does **not** contain any passwords, tokens, or keys, and it never should.

## Before you run anything

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh
```

[`scripts/k3s-backup-preflight.sh`](scripts/k3s-backup-preflight.sh) checks everything the backup
depends on and **tells you what's missing before you run it**, with the exact command to fix each
thing. It changes nothing — read-only against the cluster.

It covers: required tools · the config file and its permissions · the S3 bucket, KMS key and login
(**including a real 64 MB upload**, which is what catches the most likely permission problem) ·
every file the backup reads · a namespace-by-namespace inventory · and a plain list of what today's
backup does **not** recover.

Exit `0` = ready, `2` = ready with warnings, `1` = don't run the backup yet.

## The one-line goal

> If the server dies: get a fresh Ubuntu server → install the same version of K3s → restore our
> backup → check everything works.

## The whole design, in one table

Two jobs. One bucket. Two folders. Daily. Nothing else runs on a schedule.

| | Job 1 — K3s server backup | Job 2 — Velero |
|---|---|---|
| Runs | 02:15 UTC daily, systemd timer on the node | 03:00 UTC daily (+ 04:00 Sunday), inside the cluster |
| Backs up | SQLite datastore, cluster identity (`tls/` `cred/` `token` `manifests/`), K3s config, host OS config | Every Kubernetes object in every namespace, **plus all PVC data** |
| Restores | This server, rebuilt from bare metal | Any cluster — and it's the only thing that brings PVC data or a single deleted object back |
| Lands in | `s3://k3-master-dr/k3s/` | `s3://k3-master-dr/velero/` |
| Retention | S3 lifecycle: 7 daily + 4 weekly | Velero TTL: 7 daily + 4 weekly |

Full detail: [02 — Backup Strategy](docs/02-backup-strategy.md).

## Read the docs in this order

| # | Document | In plain words |
|---|----------|-----------------|
| 01 | [Discovery Baseline](docs/01-discovery-baseline.md) | Everything we checked and confirmed about the server as it is today. This is the "facts" document — nothing is guessed. |
| 02 | [Backup Strategy](docs/02-backup-strategy.md) | The two jobs: what they back up, when, where it goes, and how long it's kept. |
| 03 | [Restore Runbook](docs/03-restore-runbook.md) | Two flows — full server rebuild, and restoring one PVC or one deleted object. |
| 04 | [Implementation TODO](docs/04-implementation-todo.md) | The build plan, broken into phases. Matches our GitHub Issues. |
| 05 | [Gaps & Open Questions](docs/05-gaps-and-open-questions.md) | Things we still don't know for sure. Don't assume — read this first if something is unclear. |
| 06 | [Developer Access](docs/06-developer-access.md) | How a new developer gets permission to clone and push to this repo. |
| 07 | [Phase 0 & 1 Execution](docs/07-phase-0-1-execution.md) | The commands to actually build Phases 0 and 1, one at a time, with a check after each. Covers job 1 only. |
| — | [Issues Tracker](docs/ISSUES-TRACKER.md) | Every open issue in one place, with a box to paste the answer into as each is resolved. |

In a hurry? [QUICK_START.md](QUICK_START.md) is the day-by-day version of 07 plus the Velero install.

## Where things stand right now

| Task | Status |
|------|--------|
| Checked and wrote down everything about the server | ✅ Done |
| Decided how backups should work | ✅ Done — simplified to two jobs |
| Wrote both restore flows | ✅ Done (written down, **not yet tested**) |
| Job 1 script + systemd timer | ✅ Written, ⏳ not deployed |
| Job 2 Velero install + schedules | ✅ Written, ⏳ not installed |
| Created the S3 bucket + permissions | ⏳ Not done yet |
| Auto-delete old backups (7 daily + 4 weekly) | ⏳ Not set up yet |
| Alert us if a backup fails | ⏳ Not set up yet |
| Actually testing a restore | ⏳ **Never done yet** |

## Where the work is tracked

We track the actual work as GitHub Issues. (The issue numbers don't follow the phase order below —
they were created at different times.)

### Build phases

| Phase | What it covers | How urgent | Issue |
|-------|----------------|------------|-------|
| 0 | S3 bucket, encryption key, the two logins | Highest | [#9](../../issues/9), [#14](../../issues/14) |
| 1 | Job 1: deploy the K3s server backup + timer | Highest | [#10](../../issues/10) |
| 2 | Job 2: install Velero + the two schedules | Highest | [#11](../../issues/11) |
| 3 | Retention rules + "did the backup arrive?" alerting | Medium | [#2](../../issues/2) |
| 4 | Actually test both restore flows | Medium | [#12](../../issues/12) |
| 5 | Close the remaining unknowns | Low | [#3](../../issues/3) |

### Blocking unknowns — the three that could make this design wrong

| What we don't know | Why it blocks | Issue |
|------|------------|-------|
| Where our HTTPS certificates come from. If Traefik keeps `acme.json` in temporary storage, **nothing backs it up** and a restore silently comes back with broken HTTPS | A clean restore | [#4](../../issues/4) |
| Whether Velero's node-agent can actually read our volumes. A path mismatch backs up **nothing** and still looks like success | Every PVC and single-object restore | [#11](../../issues/11) |
| Nothing has ever been restored | Knowing any of this works | [#12](../../issues/12) |

The rest — crash-consistency of the monitoring volumes, K3s secret encryption, alerting, credential
rotation, single-region — are in [05 — Gaps](docs/05-gaps-and-open-questions.md).

### Decided and closed

| Question | Decision |
|----------|----------|
| Do we need a daily ArgoCD export? ([#20](../../issues/20), [#1](../../issues/1)) | **No.** Velero backs up the `argocd` namespace including its Secrets and Applications; Git holds the app definitions. Verify once in Phase 2 |
| How do we know which K3s version made a backup? ([#17](../../issues/17)) | `MANIFEST.json`, in the same folder as the files it describes |
| Which files belong to the same backup run? ([#23](../../issues/23)) | One run a day, one folder, one complete set — the question no longer arises |
| Server OS settings not backed up ([#5](../../issues/5), [#6](../../issues/6)) | Folded into Job 1 as `node-config.tar.gz` |
| The 64 MB upload failure ([#21](../../issues/21)) and bare-ARN denial ([#24](../../issues/24)) | Fixed; the preflight catches both |
| Certificate errors after a restore ([#19](../../issues/19)) | Documented — most of them fix themselves, and the runbook says which don't |

**Where to start:** [#9](../../issues/9) → [#10](../../issues/10) → [#11](../../issues/11) →
[#2](../../issues/2) → [#12](../../issues/12)

## Our server, in short

```text
Server name    k3-master
Operating system   Ubuntu 24.04.3 LTS, 64-bit
K3s version    v1.34.5+k3s1
Setup          One single server (no backup server, no high-availability)
Database       SQLite (built into K3s — no separate database server)
Storage        Files saved to local disk under /var/lib/rancher/k3s/storage
Deployments    ArgoCD watches Git and deploys our apps automatically
Monitoring     Prometheus, Loki, Grafana, Alertmanager, MinIO
```

## The most important thing to understand

People sometimes assume `/etc/rancher/k3s` is "the cluster." It is not — it's just a config file
that points somewhere else. The real identity of the cluster (its certificates, passwords, and
database) lives in `/var/lib/rancher/k3s/server/`. If we lose that folder without a backup, we
cannot cleanly bring the cluster back — every existing connection and login would need to be
re-issued from scratch.

**Rule:** always back up `/var/lib/rancher/k3s/server/` as one complete unit, including its
`tls` and `cred` subfolders (some earlier notes forgot these two). See
[Backup Strategy §1](docs/02-backup-strategy.md#1-the-thing-to-understand-before-anything-else).

**The other half:** Job 1 cannot restore a deleted PVC or a deleted Secret. Our storage runs a
`Delete` reclaim policy, so `local-path` destroys a volume's files the instant its PVC goes away —
no grace period, no orphan, nothing to recover from. **Velero is the only thing standing between an
accidental `kubectl delete pvc` and permanent loss**, which is why Phase 2 is not optional.

## Ground rules for this repo

- **Never keep this documentation only on the server.** If the server dies, we'd lose the very
  instructions we need to bring it back. This GitHub repo is the one true copy.
- Backup scripts live in the `scripts/` folder here, and get copied onto the server from here —
  not written directly on the server.
- Every phase of work has a matching GitHub Issue. When the work is done: close the issue, and
  tick the box in the TODO doc.
