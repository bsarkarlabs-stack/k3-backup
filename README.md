# k3-backup

This repo explains how we back up our server `k3-master` and how we would bring it back to life
if it ever broke, got deleted, or had to move to a new machine.

`k3-master` runs **K3s** (a lightweight version of Kubernetes) and everything on it is important:
our production apps, our monitoring (Prometheus, Grafana, Loki), and ArgoCD (which deploys our
apps from Git).

> **This is a private repo.** It has server IP addresses, folder paths, and how our system is
> laid out. It does **not** contain any passwords, tokens, or keys, and it never should.

## The one-line goal

> If the server dies: get a fresh Ubuntu server → install the same version of K3s → restore our
> backup → check everything works.

## Read the docs in this order

| # | Document | In plain words |
|---|----------|-----------------|
| 01 | [Discovery Baseline](docs/01-discovery-baseline.md) | Everything we checked and confirmed about the server as it is today. This is the "facts" document — nothing is guessed. |
| 02 | [Backup Strategy](docs/02-backup-strategy.md) | What we back up, why, how often, and where it goes in S3. |
| 03 | [Restore Runbook](docs/03-restore-runbook.md) | Step-by-step: what to do, in order, to bring the server back from a backup. |
| 04 | [Implementation TODO](docs/04-implementation-todo.md) | The build plan, broken into phases. Matches our GitHub Issues. |
| 05 | [Gaps & Open Questions](docs/05-gaps-and-open-questions.md) | Things we still don't know for sure. Don't assume — read this first if something is unclear. |
| 06 | [Developer Access](docs/06-developer-access.md) | How a new developer gets permission to clone and push to this repo. |

## Where things stand right now

| Task | Status |
|------|--------|
| Checked and wrote down everything about the server | ✅ Done |
| Decided how backups should work | ✅ Done (written down, not yet tested) |
| Wrote the step-by-step restore guide | ✅ Done (written down, not yet tested) |
| Created the S3 bucket + permissions | ⏳ Not done yet |
| Script that backs up the cluster automatically | ⏳ Not done yet |
| Velero (backs up apps, secrets, and disks) | ⏳ Not installed yet |
| Auto-delete old backups after some time | ⏳ Not set up yet |
| Alert us if a backup fails | ⏳ Not set up yet |
| Actually testing a full restore | ⏳ Never done yet |

## Where the work is tracked

We track the actual work as GitHub Issues. (The issue numbers don't follow the phase order below —
they were created at different times.)

### Build phases

| Phase | What it covers | How urgent | Issue |
|-------|-----------------|------------|-------|
| 0 — Get ready: S3 bucket, permissions, install a small tool | Highest | [#9](../../issues/9) |
| 1 — Back up the server itself (files, database, certificates) | Highest | [#10](../../issues/10) |
| 2 — Back up what's running inside K3s (apps, secrets, disks) with Velero | Highest | [#11](../../issues/11) |
| 3 — Back up ArgoCD's own settings | Medium | [#1](../../issues/1) |
| 4 — Auto-delete old backups + alert us on failure | Medium | [#2](../../issues/2) |
| 5 — Actually test a full restore | Medium | [#12](../../issues/12) |
| 6 — Fix the smaller unknowns | Low | [#3](../../issues/3) |

### Known unknowns (gaps)

| What we don't know yet | How urgent | Issue |
|------|------------|-------|
| Backups will contain real secrets — the S3 bucket must be encrypted | **Highest** | [#14](../../issues/14) |
| Where our HTTPS/SSL certificates actually come from | Medium | [#4](../../issues/4) |
| The server's network/firewall/login settings aren't backed up yet | Medium | [#5](../../issues/5) |
| Two specific certificate folders were never checked in detail | Medium | [#8](../../issues/8) |
| We're not 100% sure who hosts this server | Low | [#13](../../issues/13) |
| List of installed system software isn't saved anywhere | Low | [#6](../../issues/6) |
| All backups sit in one AWS region only, no backup-of-the-backup | Low | [#15](../../issues/15) |
| Keep this documentation in Git, never only on the server | Low | [#7](../../issues/7) |
| Nobody is assigned to rotate backup passwords/keys regularly | Low | [#16](../../issues/16) |

### Things a K3s review turned up

Found by reviewing the backup script and docs against how K3s actually behaves.

| What was wrong | How urgent | Issue | Where it stands |
|----------------|------------|-------|-----------------|
| Backups never recorded which K3s version made them — so a restore had to guess | **Highest** | [#17](../../issues/17) | Fixed in this repo, still needs deploying to the server |
| The restore runbook told you to use tools we haven't built yet | Medium | [#18](../../issues/18) | Fixed |
| Nobody had written down that K3s certificate errors after a restore usually fix themselves | Medium | [#19](../../issues/19) | Fixed |
| Do we actually need the ArgoCD settings export, or does Velero cover it? | Medium | [#20](../../issues/20) | **Open — needs a decision** |
| The backup login couldn't upload our 64 MB database — and the test wouldn't have caught it | **Highest** | [#21](../../issues/21) | Fixed |
| Our "backup succeeded" signal may be written where nothing reads it | Medium | [#22](../../issues/22) | **Open — needs a check on the server** |
| Database-only backups didn't say which full backup they pair with | Medium | [#23](../../issues/23) | Fixed |
| A bare KMS key ID instead of the full ARN would deny every upload | Low | [#24](../../issues/24) | Fixed |

**Where to start:** [#9](../../issues/9) → [#10](../../issues/10) / [#11](../../issues/11) →
[#1](../../issues/1) → [#2](../../issues/2) → [#12](../../issues/12)

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

**Rule:** always back up `/var/lib/rancher/k3s/server/` as one complete folder, including its
`tls` and `cred` subfolders (some earlier notes forgot these two). See
[Backup Strategy §2](docs/02-backup-strategy.md#2-the-correction-that-changes-the-whole-plan) for
the full explanation.

## Ground rules for this repo

- **Never keep this documentation only on the server.** If the server dies, we'd lose the very
  instructions we need to bring it back. This GitHub repo is the one true copy.
- Backup scripts live in the `scripts/` folder here, and get copied onto the server from here —
  not written directly on the server.
- Every phase of work has a matching GitHub Issue. When the work is done: close the issue, and
  tick the box in the TODO doc.
