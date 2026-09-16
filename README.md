# k3-backup

This repo explains how we back up our server `k3-master` and how we would bring it back to life if
it ever broke, got deleted, or had to move to a new machine.

`k3-master` runs **K3s** (a lightweight version of Kubernetes) and everything on it is important:
our production apps, our monitoring (Prometheus, Grafana, Loki), and ArgoCD (which deploys our apps
from Git).

> **This is a private repo.** It has server IP addresses, folder paths, and how our system is laid
> out. It does **not** contain any passwords, tokens, or keys, and it never should.

## The one-line goal

> If the server dies: get a fresh Ubuntu server → install the same version of K3s → restore our
> backup → check everything works.

## Before you run anything

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws   # before the bucket exists
sudo /usr/local/sbin/k3s-backup-preflight.sh            # after Job 1's credential is in place
```

[`scripts/k3s-backup-preflight.sh`](scripts/k3s-backup-preflight.sh) checks everything the backup
depends on and **tells you what's missing before you run it**, with the exact command to fix each
thing. It changes nothing — read-only against the cluster.

It covers: required tools · the config file and its permissions · whether the backup credential can
write, and confirms it **can't** read or delete backups · every file the backup reads · a
namespace-by-namespace inventory · and a plain list of what today's backup does **not** recover.

Exit `0` = ready, `2` = ready with warnings, `1` = don't run the backup yet.

## The whole design, in one table

Two backup jobs, plus one host-side Velero verification timer. One bucket.

| | Job 1 — K3s server backup | Job 2 — Velero |
|---|---|---|
| Runs | 02:15 UTC daily, systemd timer on the node | 03:30 UTC: daily Monday–Saturday, weekly Sunday |
| Backs up | SQLite datastore, cluster identity (`tls/` `cred/` `token` `manifests/`), K3s config and start flags, a plain-text host fact sheet | Every Kubernetes object in every namespace, **plus all PVC data** |
| Produces | One `.tar.gz` + checksum + manifest + last-written completion marker | A Kopia repository Velero manages itself |
| Restores | This server, rebuilt from bare metal | Objects/PVC data into a source-compatible cluster |
| Lands in | `s3://k3-master-dr-sep-07/k3s/` | `s3://k3-master-dr-sep-07/velero/` |
| Retention | S3 lifecycle: 7 daily + 4 weekly | Velero TTL: 6 weekday (168 h) + 4 Sunday (720 h) |

The bucket is private, versioned, and encrypted with **SSE-S3**. Job 1 and Velero use separate
credentials: Job 1 cannot read/delete or access `velero/`; only the Velero credential can
read/delete its Kopia prefix because TTL and restore require it. Restores use a normal AWS
admin/SSO login. Full detail: [02 — Backup Strategy](docs/02-backup-strategy.md).

The K3s binary is also kept in the bucket, once per version, so a restore years from now doesn't
depend on that release still being downloadable.

## Read the docs in this order

| # | Document | In plain words |
|---|----------|-----------------|
| 01 | [Discovery Baseline](docs/01-discovery-baseline.md) | Everything we checked and confirmed about the server as it is today. This is the "facts" document — nothing is guessed. |
| 02 | [Backup Strategy](docs/02-backup-strategy.md) | The design: what the two jobs cover, what they protect against, where it goes, how long it's kept, and how we'd know it broke. |
| 03 | [Restore Runbook](docs/03-restore-runbook.md) | Four flows — full rebuild, one-object/PVC recovery, restore testing, and clean-cluster fallback. |
| 04 | [Implementation TODO](docs/04-implementation-todo.md) | The build plan, in five phases. Matches our GitHub Issues. |
| 05 | [Gaps & Open Questions](docs/05-gaps-and-open-questions.md) | What we still don't know or haven't decided. Read this first if something is unclear. |
| 06 | [Developer Access](docs/06-developer-access.md) | How a new developer gets permission to clone and push to this repo. |
| 07 | [Setup](docs/07-setup.md) | The commands to actually build it: five stages, 35 numbered steps, each with a check before you move on. Starts with an index of every step. |
| — | [Issues Tracker](docs/ISSUES-TRACKER.md) | Every open issue in one place, with a box to paste the answer into as each is resolved. |

## Where things stand right now

| Task | Status |
|------|--------|
| Checked and wrote down everything about the server | ✅ Done |
| Decided how backups should work | ✅ Done — two jobs, one committed archive set, SSE-S3, split credentials |
| Wrote all four restore flows | ✅ Done (written down, **not yet tested**) |
| Job 1 script + systemd timer | ✅ Written, ⏳ not deployed |
| Job 2 Velero install + schedules | ✅ Written, ⏳ not installed |
| Created the S3 bucket + two scoped credentials | ⏳ Not done yet |
| Auto-delete old backups (a week of dailies + 4 weeklies) | ⏳ Not set up yet |
| Alert us if either backup doesn't arrive | ✅ Verifiers written, ⏳ two external checks not configured |
| RPO / RTO agreed | ⏳ Assumed 24 h / 2–4 h, **not signed off** |
| Actually testing a restore | ⏳ **Never done yet** |

## Where the work is tracked

We track the actual work as GitHub Issues. (The issue numbers don't follow the phase order — they
were created at different times.)

| Phase | What it covers | How urgent | Issue |
|-------|----------------|------------|-------|
| 1 | Validate the server and the assumptions | Highest | [#9](../../issues/9) |
| 2 | Job 1: bucket, credential, backup script + timer | Highest | [#10](../../issues/10) |
| 3 | Job 2: install Velero + the two schedules | Highest | [#11](../../issues/11) |
| 4 | Alerting — including one that works when the server is dead | Medium | [#2](../../issues/2) |
| 5 | Actually test a restore | Medium | [#12](../../issues/12) |

### The four things that could still make this design wrong

| What we don't know | Why it blocks | Issue |
|------|------------|-------|
| **RPO and RTO aren't agreed.** "Daily" is only right if losing a day is acceptable | Whether the schedule is correct at all | [#3](../../issues/3) |
| **The two heartbeats have nowhere to report.** A stopped Job 1 or Velero backup is currently silent | A failure being noticed | [#2](../../issues/2) |
| **Where our HTTPS certificates come from.** If Traefik keeps `acme.json` in temporary storage, nothing backs it up and a restore silently comes back with broken HTTPS | A clean restore | [#4](../../issues/4) |
| **Nothing has ever been restored** | Knowing any of this works | [#12](../../issues/12) |

The rest are in [05 — Gaps](docs/05-gaps-and-open-questions.md).

**Where to start:** [#9](../../issues/9) → [#10](../../issues/10) → [#11](../../issues/11) →
[#2](../../issues/2) → [#12](../../issues/12)

## Our server, in short

```text
Server name    k3-master
Operating system   Ubuntu 24.04.3 LTS, 64-bit
K3s version    capture live: k3s --version   (discovery snapshot was v1.34.5+k3s1; do not require that string)
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

**Rule:** always back up `/var/lib/rancher/k3s/server/` as one complete unit, including its `tls`
and `cred` subfolders (some earlier notes forgot these two). See
[Backup Strategy §4](docs/02-backup-strategy.md#4-job-1--the-k3s-server-backup).

**The other half:** Job 1 cannot restore a deleted PVC or a deleted Secret. Our storage runs a
`Delete` reclaim policy, so `local-path` destroys a volume's files the instant its PVC goes away —
no grace period, no orphan, nothing to recover from. **Velero is the only thing standing between an
accidental `kubectl delete pvc` and permanent loss**, which is why phase 3 is not optional.

On the node, Velero is a **client**: it does not magically find K3s. It uses
`/etc/rancher/k3s/k3s.yaml` (`server: https://127.0.0.1:6443`) via
`sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero …`. `velero backup get` lists backups;
`Completed` is not proof that PVC data was copied. Beginner walkthrough (what the kubeconfig is,
what each `get` column means): [07 — Stage 4](docs/07-setup.md#velero-for-someone-new-to-it).
Hands-on steps stay in that same file — do not skip safety checks.

## Ground rules for this repo

- **Never keep this documentation only on the server.** If the server dies, we'd lose the very
  instructions we need to bring it back. This GitHub repo is the one true copy.
- Backup scripts live in the `scripts/` folder here, and get copied onto the server from here — not
  written directly on the server.
- Every phase of work has a matching GitHub Issue. When the work is done: close the issue, and tick
  the box in the TODO doc.
- **One document per job.** If you're about to write a second runbook covering the same setup,
  edit [07](docs/07-setup.md) instead — two copies drift apart, and during an outage you won't know
  which one is right.
