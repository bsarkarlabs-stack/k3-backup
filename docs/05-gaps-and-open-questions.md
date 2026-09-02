# 05 — Gaps & Open Questions

Things we **don't know for sure yet**, or haven't decided. Don't assume an answer — each has a
GitHub Issue.

The design itself is settled ([02 — Backup Strategy](02-backup-strategy.md)); what's below is what
could still make that design wrong on this particular server.

| # | Gap | Serious? | Blocks | Issue |
|---|-----|----------|--------|-------|
| 1 | RPO and RTO are not signed off | **Blocking** | Knowing whether "daily" is the right answer | [#3](../../../issues/3) |
| 2 | The two external heartbeats have nowhere to report yet | **Blocking** | Job 1 or Velero failure being noticed | [#2](../../../issues/2) |
| 3 | Nothing has ever been restored | **Blocking** | Knowing any of this works | [#12](../../../issues/12) |
| 4 | Where Traefik's HTTPS certificates come from | **Blocking** | A clean restore — silently | [#4](../../../issues/4) |
| 5 | Who can actually perform a restore | High | The whole plan, if one person has the AWS access | [#16](../../../issues/16) |
| 6 | Whether Velero's node-agent can read our volumes | High | All PVC and single-object restores | [#11](../../../issues/11) |
| 7 | Application consistency of live Prometheus / Loki / MinIO files | Medium | Trusting monitoring history | [#12](../../../issues/12) |
| 8 | Is K3s encrypting Secrets inside its own database? | Medium | How loudly the runbook flags `cred/` | [#22](../../../issues/22) |
| 9 | One region, one bucket, no backup-of-the-backup | Low | A whole-region outage | [#15](../../../issues/15) |

---

## 1. RPO and RTO are not signed off

**Blocking, and it's a conversation rather than a command.**

The design runs on two assumptions: we can lose up to **24 hours** of cluster state, and a rebuild
may take **2–4 hours**. Daily backups are the right answer *if those numbers are right* and the
wrong answer otherwise. Without them, "daily" is arbitrary.

[02 §1](02-backup-strategy.md#1-two-numbers-to-agree-on-first--still-open) sets out exactly what
changes for each answer, so this is cheap to revisit — but it should be a decision on the record,
not a default nobody examined.

**To close:** [07 step 1.7](07-setup.md#17--agree-an-rpo-and-an-rto-decision) — get the two numbers
agreed, write them into 02 §1, and mark them signed off.

---

## 2. The external heartbeats have nowhere to report yet

**Blocking.** Job 1 pings `HEARTBEAT_URL` after its committed set lands. The separate Velero
verifier pings `VELERO_HEARTBEAT_URL` only after a fresh scheduled Backup and its
PodVolumeBackups pass. Nothing is listening yet, so stopped backups remain silent.

This is the **only** alert that still works when `k3-master` is dead, which is the failure that
matters most. Prometheus and Alertmanager run inside the cluster we're protecting; they go down with
it.

Three realistic channels:

| Option | Effort | Notes |
|--------|--------|-------|
| Hosted dead-man's switch (healthchecks.io, Cronitor) | ~5 min | Free tier is enough. One URL, no infrastructure |
| AWS-native: EventBridge rule on S3 `ObjectCreated` under `k3s/daily/` → CloudWatch alarm treating missing data as breaching | ~1 hour | No third party. More moving parts, and it watches the bucket rather than the script |
| An Alertmanager or push gateway hosted **outside** this cluster | varies | Only worth it if one already exists |

**To close:** [07 steps 5.1–5.3](07-setup.md#51--choose-the-two-dead-man-checks-local) create the two
checks and set both URLs; [07 step 5.5](07-setup.md#55--break-every-alert-on-purpose) proves each one
fires when only its own timer stops.

---

## 3. Nothing has ever been restored

**Blocking.** All four flows in the [restore runbook](03-restore-runbook.md) are written but
unproven, and the ~2 hour RTO in it is a guess.

*A backup that has never been restored is a hope, not a plan.*

**To close:** [03 §C](03-restore-runbook.md#c--the-restore-test) on a throwaway VM, driven from
[07 step 5.7](07-setup.md#57--prove-a-restore-works), then correct the runbook to match what
actually happened rather than what we expected.

---

## 4. Where Traefik's HTTPS certificates come from

**Blocking. This is the gap most likely to produce a restore that looks successful and isn't.**

No certificate manager (cert-manager or similar) was found during discovery. So Traefik's
certificates are one of:

- **Kubernetes Secrets** → already covered by Velero, and this gap closes immediately
- **Issued by Traefik itself via ACME**, stored in `acme.json` — which might live on a PVC (covered)
  or in an `emptyDir` (**covered by nothing at all**)
- **Terminated upstream of this server** → nothing to back up, but it needs writing down

**Why it matters:** in the `emptyDir` case, every restore comes back with broken HTTPS and no
warning beforehand. Nothing in the current design would catch it until users do.

**To close:** [07 stage 1.5](07-setup.md#15--where-do-the-https-certificates-come-from-node).

---

## 5. Who can actually perform a restore

The design deliberately has **no stored restore credential** — restores use a normal AWS admin or
SSO login, which is better than keeping a permanent read key in a vault on a rotation schedule.

That trade only holds if the access itself is not a single point of failure. Right now nobody has
confirmed it isn't.

**To close, and it takes five minutes** —
[07 step 2.7](07-setup.md#27--write-down-who-can-restore-local):

- Name **at least two people** who can log into AWS and read `s3://k3-master-dr`.
- Write the **bucket name and region** somewhere that survives losing AWS access to that account —
  this repo counts, and it already says both.
- Name the owner and rotation interval for both workload keys (Job 1 and Velero).
- Record where the recovery kit (this repo, cloned off `k3-master`) actually lives.

---

## 6. Whether Velero's node-agent can actually read our volumes

> **First, the blunter fact this gap can obscure: Velero is not installed at all yet.** Phrased as
> "can the node-agent read our volumes", this reads like Job 2 exists and might be misconfigured.
> It doesn't. **Today, nothing backs up PVC data**, and an accidental `kubectl delete pvc` is
> permanent — see [02 §5](02-backup-strategy.md#5-job-2--velero). That is a bigger exposure than
> everything else on this page combined, and installing Velero is what closes it.

Once it *is* installed, this is the failure mode to watch for. File-system backup reads pod volumes
through a hostPath into the kubelet root directory, and K3s does not always use the stock
`/var/lib/kubelet`. If the path doesn't match, **the node-agent starts cleanly and backs up
nothing** — the result looks like an empty backup rather than an error, and the backup is still
marked `Completed`.

**To close:** [07 step 4.3](07-setup.md#43--prove-the-node-agent-actually-reads-the-volumes-local) —
after installing Velero, run a backup and check it directly:

```bash
velero backup describe <name> --details      # all six PVCs must appear under "Pod Volume Backups"
```

An empty *Pod Volume Backups* section is the failure. Volume copy-back is proven later by the
controller-aware PVC procedure in restore runbook §B, on the restore-test VM — not by deleting a
live production claim during setup.

**Then make it permanent:** this exact failure is why
[02 §7 alert 3](02-backup-strategy.md#7-knowing-it-works) alerts on the *number of pod volumes* in
the last backup rather than on its status. Checking once at install proves it worked once; the alert
is what notices the day a K3s upgrade moves the kubelet root.

---

## 7. Application consistency of the monitoring volumes

File-system backup scans a **running** filesystem over time. It is neither application-consistent
nor a point-in-time crash-consistent block snapshot; different files can represent different
moments.

- **Prometheus** normally replays its WAL and recovers cleanly.
- **MinIO** and **Loki's boltdb-shipper** are less forgiving.

**To close:** decide whether monitoring history is explicitly best-effort, and record the decision
during [07 step 5.7](07-setup.md#57--prove-a-restore-works) when you can see what actually came
back. If it is required data, add and test an application-native export or quiesce hook; a
successful live FSB restore alone does not establish consistency.

---

## 8. Is K3s encrypting Secrets inside its own database?

Either answer is fine — we back up all of `cred/` regardless, so the key file is covered. What
changes is the runbook: if it's **on**, then restoring `cred/encryption-config.json` becomes a hard
precondition before starting K3s, and
[step 4](03-restore-runbook.md#step-4--restore-the-identity-and-the-datastore) should say so in bold
rather than as a footnote.

```bash
sudo k3s secrets-encrypt status
```

---

## 9. One region, one bucket

Reasonable given a single server with no failover — the server is a far bigger single point of
failure than a whole AWS region. But it should be **a decision on the record**, not a default nobody
examined. Versioning plus a credential that cannot delete or read is the meaningful protection here,
not a second region.

Related and already decided: we protect against host loss and a compromised `k3-master`, **not**
against a compromised AWS account. If that changes, the answer is S3 Object Lock or a separate
account — see [02 §9](02-backup-strategy.md#9-the-immutability-decision--made-and-on-the-record).

---

## Closed by the simplified design

These were real gaps against earlier versions of the plan. The current design resolves them — kept
here so the reasoning isn't lost.

| Was | Now |
|-----|-----|
| **Host OS settings weren't backed up** — restore step 2 was reconstruction from memory | Captured as a plain-text fact sheet inside the one archive: addresses, routes, firewall, timezone, disk layout, packages, netplan, the K3s start command ([#5](../../../issues/5), [#6](../../../issues/6)) |
| **`/etc/ssh` and `authorized_keys` were in the backup** | **Removed.** Host private keys don't belong in the bucket, and restoring a dead host's SSH identity onto a new machine is the wrong move |
| **Backups didn't record which K3s version made them** | `MANIFEST.json`, uploaded beside the archive *and* inside it, with the version, the raw version string and the real start command ([#17](../../../issues/17)) |
| **The exact K3s release might not be downloadable years later** | The binary is uploaded once per version to `k3s-release/<version>/`, never expired, with a `RESTORE.txt` ([02 §8](02-backup-strategy.md#8-future-proofing-a-restore)) |
| **A customer-managed KMS key, its alias, rotation, four IAM actions, a key-ARN bucket policy, and a 64 MB test upload to catch the non-obvious `kms:Decrypt` requirement** | **Removed.** SSE-S3 by default, plus a credential with no read access to `k3s/*` — simpler *and* a tighter blast radius ([#14](../../../issues/14), [#21](../../../issues/21), [#24](../../../issues/24)) |
| **A second permanent restore-reader key on a 90-day rotation** | **Removed.** Restores use an admin/SSO login. What replaced it is gap 5 above: two named people, written down |
| **One credential exposed both Job 1 and the readable/deletable Kopia repository** | Separate Job 1 and Velero identities; Job 1 cannot access `velero/*` |
| **Four artifacts and four checksums per run** | One archive, one checksum, one manifest, and one completion marker uploaded last ([#23](../../../issues/23)) |
| **Alerting was built on a node-exporter textfile metric nobody had confirmed was read** | **Removed.** Replaced by a heartbeat pinged after the objects are verified in S3 — which also works when the server is dead (gap 2) |
| **"Check it by hand every day for a week" was the monitoring plan** | Watch two or three runs, then rely on the alerts |
| **Two parallel runbooks (a 4,100-line day-by-day and a 1,300-line stage-by-stage) describing the same setup** | One: [07 — Setup](07-setup.md) |
| **The runbook told you to use tools that didn't exist** | Every flow names what must be installed first ([#18](../../../issues/18)) |
| **Nobody had written down how K3s certificates expire** | The "normal kind vs. real problem" table in [restore step 6](03-restore-runbook.md#step-6--start-k3s-and-verify-the-control-plane) ([#19](../../../issues/19)) |
| **Do we need a daily ArgoCD export?** | **No.** Velero backs up the `argocd` namespace including Secrets, Applications and AppProjects; Git holds the app definitions. Verify once in phase 3 ([#20](../../../issues/20), [#1](../../../issues/1)) |
| **Who hosts this server** | Datalix, treated as on-premise. No hosting-level snapshot available ([#13](../../../issues/13)) |
| **This documentation could live only on the server** | This repo is the one true copy ([#7](../../../issues/7)) |

---

## Adding a new gap

1. Add a row to the table at the top
2. Add a section explaining **why it matters** and **how we plan to find out** — not just what's
   missing
3. Open a GitHub Issue and link it
