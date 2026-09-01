# 05 — Gaps & Open Questions

Things we **don't know for sure yet**. Don't assume an answer — each has a GitHub Issue.

The design itself is settled ([02 — Backup Strategy](02-backup-strategy.md)); what's below is what
could still make that design wrong on this particular server.

| # | Gap | Serious? | Blocks | Issue |
|---|-----|----------|--------|-------|
| 1 | Where Traefik's HTTPS certificates actually come from | **Blocking** | A clean restore — silently | [#4](../../../issues/4) |
| 2 | Whether Velero's node-agent can actually read our volumes | **Blocking** | All PVC and single-object restores | [#11](../../../issues/11) |
| 3 | Nothing has ever been restored | **Blocking** | Knowing any of this works | [#12](../../../issues/12) |
| 4 | Crash-consistency of the Prometheus / Loki / MinIO volumes | High | Trusting a PVC restore | [#12](../../../issues/12) |
| 5 | Is K3s encrypting Secrets inside its own database? | Medium | How loudly we flag `cred/` in the runbook | [#22](../../../issues/22) |
| 6 | Does our "backup succeeded" signal go anywhere? | Medium | Alerting being real rather than decorative | [#22](../../../issues/22) |
| 7 | Nobody owns rotating the S3 credentials | Medium | Long-term security posture | [#16](../../../issues/16) |
| 8 | One region, one bucket, no backup-of-the-backup | Low | A whole-region outage | [#15](../../../issues/15) |

---

## 1. Where Traefik's HTTPS certificates come from

**Blocking. This is the gap most likely to produce a restore that looks successful and isn't.**

No certificate manager (cert-manager or similar) was found during discovery. So Traefik's
certificates are one of:

- **Kubernetes Secrets** → already covered by Velero, and this gap closes immediately
- **Issued by Traefik itself via ACME**, stored in `acme.json` — which might live on a PVC (covered)
  or in an `emptyDir` (**covered by nothing at all**)
- **Terminated upstream of this server** → nothing to back up, but it needs writing down

**Why it matters:** in the `emptyDir` case, every restore comes back with broken HTTPS and no
warning beforehand. Nothing in the current design would catch it until users do.

**To close:** inspect the Traefik deployment for an `acme.json` path and find out what backs that
path.

```bash
sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -iA3 'acme\|certresolver'
sudo k3s kubectl -n kube-system get ingressroute,secret -o wide
```

---

## 2. Whether Velero's node-agent can actually read our volumes

**Blocking.**

File-system backup reads pod volumes through a hostPath into the kubelet root directory. K3s does
not always use the stock `/var/lib/kubelet`. If the path doesn't match, **the node-agent starts
cleanly and backs up nothing** — the result looks like an empty backup rather than an error.

**To close:** after installing Velero, run a backup and check it directly:

```bash
velero backup describe <name> --details      # all six PVCs must appear under "Pod Volume Backups"
```

An empty *Pod Volume Backups* section is the failure. Then prove it the other way, by restoring one
PVC into a scratch namespace.

---

## 3. Nothing has ever been restored

**Blocking.** Both flows in the [restore runbook](03-restore-runbook.md) are written but unproven,
and the ~2 hour RTO in it is a guess.

**To close:** [Phase 4](04-implementation-todo.md#phase-4--prove-a-restore-works). Run §A on a
throwaway host and §B against a scratch namespace, then correct the runbook to match what actually
happened rather than what we expected.

---

## 4. Crash-consistency of the monitoring volumes

File-system backup of a **running** database is crash-consistent, not application-consistent —
equivalent to pulling the power cord.

- **Prometheus** normally replays its WAL and recovers cleanly.
- **MinIO** and **Loki's boltdb-shipper** are less forgiving.

**To close:** during the restore test, confirm each restored pod reaches Ready *and* returns
pre-incident data. Only if that fails do we add a Velero pre-backup hook to flush the store —
adding one pre-emptively is complexity bought on speculation.

---

## 5. Is K3s encrypting Secrets inside its own database?

Either answer is fine — we back up all of `cred/` regardless, so the key file is covered. What
changes is the runbook: if it's **on**, then restoring `cred/encryption-config.json` becomes a hard
precondition before starting K3s, and [step 4](03-restore-runbook.md#step-4--restore-the-cluster-identity-and-the-datastore)
should say so in bold rather than as a footnote.

```bash
sudo k3s secrets-encrypt status
```

---

## 6. Does our "backup succeeded" signal go anywhere?

Job 1 writes a metric into `/var/lib/node_exporter/textfile_collector`. If that directory doesn't
exist, the script skips it silently — and discovery never confirmed node-exporter is installed on
the host at all.

**This is why [02 §8](02-backup-strategy.md#8-knowing-it-works) makes the primary alert *object age
in S3* instead.** That proves the backup actually arrived; the textfile metric only proves the
script thinks well of itself. Keep the metric as a bonus, don't build the alerting on it.

**To close:** find out what node-exporter is here ([07 Stage B.1b](07-phase-0-1-execution.md)), then
wire the S3 object-age alert either way.

---

## 7. Nobody owns rotating the S3 credentials

Long-lived write credentials to a bucket that holds the cluster CA and every Secret in readable form
are an ongoing risk.

**To close:** one named person, one schedule (suggest 90 days), written down here.

---

## 8. One region, one bucket

Reasonable given a single server with no failover — the server is a far bigger single point of
failure than a whole AWS region. But it should be **a decision on the record**, not a default
nobody examined. Versioning plus locked-down delete permissions is the meaningful protection here,
not a second region.

---

## Closed by the simplified design

These were real gaps against the previous plan. The current design resolves them — kept here so the
reasoning isn't lost.

| Was | Now |
|-----|-----|
| **Host OS settings weren't backed up** (network, firewall, SSH, packages) — restore step 2 was reconstruction from memory | Captured by Job 1 as `node-config.tar.gz`, in the same folder as everything else. Closes old gaps 3 and 4 ([#5](../../../issues/5), [#6](../../../issues/6)) |
| **Backups didn't record which K3s version made them** | `MANIFEST.json` in every run folder ([#17](../../../issues/17)) |
| **Nothing said which files belonged to the same backup run** — 4 datastore runs a day across 7 prefixes | One run a day, one folder, one complete set. The problem is gone rather than solved ([#23](../../../issues/23)) |
| **The runbook told you to use tools that didn't exist** | Both flows now name exactly what must be installed first, and Phase 2 is the blocker ([#18](../../../issues/18)) |
| **Nobody had written down how K3s certificates expire** | The "normal kind vs. real problem" table in [restore step 6](03-restore-runbook.md#step-6--start-k3s-and-verify-the-control-plane) ([#19](../../../issues/19)) |
| **The backup login couldn't upload a 64 MB file** — no `kms:Decrypt`, and the test used a 50-byte file that passed | `kms:Decrypt` scoped to our one key, and the preflight uploads 64 MB ([#21](../../../issues/21)) |
| **A bare KMS key id would deny every upload** | The script rejects anything that isn't a full ARN, with a readable message ([#24](../../../issues/24)) |
| **Do we need a daily ArgoCD export?** Two documents disagreed | **Decided: no.** Velero backs up the `argocd` namespace including Secrets, Applications and AppProjects; Git holds the app definitions. Verify once in Phase 2, then it's settled ([#20](../../../issues/20), [#1](../../../issues/1)) |
| **Who hosts this server** | Datalix, treated as on-premise. No hosting-level snapshot available ([#13](../../../issues/13)) |
| **This documentation could live only on the server** | This repo is the one true copy ([#7](../../../issues/7)) |

---

## Adding a new gap

1. Add a row to the table at the top
2. Add a section explaining **why it matters** and **how we plan to find out** — not just what's
   missing
3. Open a GitHub Issue and link it
