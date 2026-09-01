# 04 — Implementation TODO

Four phases. Each one produces something the next needs. Every phase has a GitHub Issue — when the
work is done, close the issue and tick the box here.

| Phase | What it is | Urgency | Issue |
|-------|------------|---------|-------|
| 0 | The bucket, the keys, the logins | Do this first | [#9](../../../issues/9), [#14](../../../issues/14) |
| 1 | Job 1 — K3s server backup | Highest | [#10](../../../issues/10) |
| 2 | Job 2 — Velero | Highest | [#11](../../../issues/11) |
| 3 | Retention + alerting | Medium | [#2](../../../issues/2) |
| 4 | Prove a restore works | Medium | [#12](../../../issues/12) |
| 5 | Close the remaining unknowns | Low | [#3](../../../issues/3) |

Step-by-step commands for phases 0–1 are in
[07 — Phase 0 & 1 Execution](07-phase-0-1-execution.md).

---

## Phase 0 — The bucket, the keys, the logins
**Everything else depends on this.**

- [ ] Confirm Python's built-in `sqlite3` module works on `k3-master` (the `sqlite3` CLI is not
      installed and does not need to be)
- [ ] Create a dedicated KMS key
- [ ] Create the bucket `k3-master-dr` — **with default encryption on from creation**, versioning
      on, all public access blocked. Encryption is not retroactive ([#14](../../../issues/14))
- [ ] Create the **backup writer** login: `Put`/`Get`/`AbortMultipartUpload` across the bucket
      (job 1's 64 MB upload to `k3s/` is multipart, so Abort cannot be scoped to `velero/`),
      `ListBucket` on the bucket, **`DeleteObject` on `velero/*` only**, plus
      `kms:GenerateDataKey` + **`kms:Decrypt`** on the one key
- [ ] Create the **restore reader** login (`Get`/`List`/`kms:Decrypt`) and store it offline —
      never on `k3-master`
- [ ] Test the writer with a **64 MB** file, not a small one — that is what exercises the
      multipart path where the missing `kms:Decrypt` shows up ([#21](../../../issues/21))

---

## Phase 1 — Job 1: K3s server backup
**Highest.** Script: [`scripts/k3s-server-backup.sh`](../scripts/k3s-server-backup.sh) — already
written, not yet deployed.

- [ ] Copy the script to `/usr/local/sbin/` and the two units to `/etc/systemd/system/`
- [ ] Run the preflight (`k3s-backup-preflight.sh`) and get a READY result
- [ ] `DRY_RUN=1` run — confirm it produces `state.db`, `k3s-identity.tar.gz`,
      `node-config.tar.gz`, `MANIFEST.json` and four `.sha256` files
- [ ] Confirm `MANIFEST.json` records the correct `k3s_version` ([#17](../../../issues/17))
- [ ] One real run — confirm the folder arrives at `s3://k3-master-dr/k3s/daily/YYYY-MM-DD/`
- [ ] Extract the identity archive somewhere scratch and confirm `tls/`, `cred/`, `token`,
      `manifests/`, `/etc/rancher/k3s` and the systemd unit are all in it ([#8](../../../issues/8))
- [ ] `systemctl enable --now k3s-backup.timer`, then confirm with `systemctl list-timers`
- [ ] Confirm a Sunday run also writes `k3s/weekly/`

---

## Phase 2 — Job 2: Velero
**Highest.** This is the piece that makes PVC data and single-object restores possible at all.
Nothing else in this plan covers either.

- [ ] Write the backup-writer credentials into a `velero-credentials` file in AWS's own format
      (`[default]` / `aws_access_key_id` / `aws_secret_access_key`), then shred it once Velero has
      turned it into a Secret
- [ ] Run [`scripts/velero/install-velero.sh`](../scripts/velero/install-velero.sh) — Velero + AWS
      plugin, node-agent on, `prefix=velero`, SSE-KMS with our key
- [ ] Apply [`schedule-daily.yaml`](../scripts/velero/schedule-daily.yaml) and
      [`schedule-weekly.yaml`](../scripts/velero/schedule-weekly.yaml)
- [ ] **Verify the node-agent actually reads the volumes.** `velero backup describe <name>
      --details` must list all six monitoring PVCs under *Pod Volume Backups*. An empty list means
      the hostPath doesn't match K3s's kubelet root — it fails silently and looks like success
      ([02 §9 gap 2](02-backup-strategy.md#9-gaps-that-still-need-validating))
- [ ] Confirm cluster-scoped resources are in the backup (CRDs, ClusterRoles, StorageClass)
- [ ] Confirm the `argocd` namespace backup contains its Secrets and Applications — this is what
      retires the separate ArgoCD export ([#20](../../../issues/20), [#1](../../../issues/1))
- [ ] Do one small restore into a scratch namespace. **Don't just trust a green checkmark.**
- [ ] Confirm old backups actually expire after their TTL — proves the `DeleteObject` permission
      is right

---

## Phase 3 — Retention and alerting

- [ ] Two S3 lifecycle rules, and only two: `k3s/daily/` expire 8 days, `k3s/weekly/` expire
      31 days
- [ ] **Confirm there is no lifecycle rule on `velero/`** — one would delete Kopia chunks that
      valid backups depend on, and the damage only shows up at restore time
- [ ] Alert on the **age of the newest object** under `k3s/daily/` (threshold ~36 h)
- [ ] Alert on `velero_backup_last_successful_timestamp`
- [ ] Test both alerts by deliberately breaking a run
- [ ] Let both jobs run untouched for **one full week** before relying on them

---

## Phase 4 — Prove a restore works
**This is the phase that turns "we think this works" into "we know".**

- [ ] Throwaway server matching `k3-master`
- [ ] Run [§A of the restore runbook](03-restore-runbook.md#a--full-server-rebuild) start to finish
- [ ] Confirm restored Prometheus answers a query over **pre-incident** data — proof the volume
      restore worked, not just that the pod started
- [ ] Confirm HTTPS comes back valid (this is where the Traefik certificate gap bites, if it bites)
- [ ] Run [§B](03-restore-runbook.md#b--restoring-one-pvc-or-one-object) once in production against
      a scratch namespace
- [ ] Record how long each took; fix whatever broke; update the runbook to match reality
- [ ] Schedule the test to repeat **every 3 months**

---

## Phase 5 — Close the remaining unknowns

- [ ] **Where Traefik's TLS certificates come from** ([#4](../../../issues/4)) — the one gap that can
      silently produce a broken restore
- [ ] `k3s secrets-encrypt status` — if on, note in the runbook that `cred/encryption-config.json`
      is mandatory ([#22](../../../issues/22))
- [ ] Decide explicitly whether one region is acceptable ([#15](../../../issues/15))
- [ ] Assign one person and a schedule (suggest 90 days) for rotating the S3 credentials
      ([#16](../../../issues/16))
- [ ] Keep this repo as the one true copy of the documentation ([#7](../../../issues/7))

---

## When is this done?

1. Both jobs run on schedule, untouched, for a week
2. A failed or missing backup pages someone within one cycle
3. Both restore flows have actually been run, and the runbook matches what really happened
4. We know the real RTO and the business has agreed it's acceptable
5. This documentation lives in Git, not only on the server it describes how to recover
