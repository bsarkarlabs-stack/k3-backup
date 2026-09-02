# Issues Tracker — Answer & Fix One by One

> **Note:** This file was created on user request, to list every open issue in one place so answers
> and outputs can be filled in one by one. **Do not delete this file.**

How to use this file: go top to bottom, in order. For each issue, fill in the **Answer / Output**
box with whatever you find (command output, a decision, a "yes it's done" — whatever applies). Once
an issue is answered, we mark it done and move to the next one.

---

## Build phases — the main work, in order

### 1. [#9](../../../issues/9) — Phase 1: Validate
**Priority: Do this first — everything else depends on it**

Commands: [07 steps 1.1–1.6](07-setup.md#stage-1--validate-the-server).

- Run `k3s-backup-preflight.sh --no-aws` and get a READY result
- Confirm hostname, K3s version, service enabled, ≥5 GB free, `etcd-snapshot ls` still disabled
- Confirm Python's `sqlite3` module works (nothing to install if it does)
- List `server/tls/` and `server/cred/` file-by-file — names and permissions only, never contents
- Record the certificate expiry dates (CA ≈10 years, leaf ≈1 year)
- `k3s secrets-encrypt status`
- **Where do Traefik's HTTPS certificates come from?** (see #4 below — do this one first)

**Answer / Output:**
```
(paste here)
```

---

### 2. [#3](../../../issues/3) — Agree an RPO and an RTO
**Priority: Highest — it's a decision, not a command, and everything else assumes an answer**

The design assumes we can lose up to **24 hours** of cluster state (RPO) and that a rebuild may take
**2–4 hours** (RTO). Daily backups are correct *if those are right*.

[02 §1](02-backup-strategy.md#1-two-numbers-to-agree-on-first--still-open) lists exactly what
changes for each possible answer, so this is cheap to revisit — but it should be signed off rather
than assumed. The step: [07 step 1.7](07-setup.md#17--agree-an-rpo-and-an-rto-decision).

**Answer / Output:**
```
RPO agreed:
RTO agreed:
Signed off by / date:
```

---

### 3. [#10](../../../issues/10) — Phase 2: Job 1, the K3s server backup
**Priority: Highest**

Commands: [07 steps 2.1–3.8](07-setup.md#stage-2--create-the-bucket-and-two-scoped-workload-credentials).

- Bucket: public access blocked, versioning on, **default SSE-S3**, HTTPS-only bucket policy
- Six lifecycle rules: Job 1 current expiry, noncurrent-only expiry for `velero/` and releases,
  preflight expiry, and abort stuck multipart uploads
- Separate Job 1 and Velero users. Job 1 is write-only on its prefixes; Velero has full control
  only on `velero/*`
- Deploy `scripts/k3s-server-backup.sh` + the two systemd units
- Preflight with AWS: confirm read-back and delete are **refused**
- `DRY_RUN=1` → archive, checksum, manifest, completion marker, and `NRestarts` unchanged
- One real run → committed unique prefix and binary plus checksum in `k3s-release/`
- `systemctl enable --now k3s-backup.timer`

**Answer / Output:**
```
(paste here)
```

---

### 4. [#11](../../../issues/11) — Phase 3: Job 2, Velero
**Priority: Highest — this is half the design and currently doesn't exist at all**

Commands: [07 steps 4.1–4.6](07-setup.md#stage-4--deploy-job-2-velero).

- Find K3s's kubelet root **before** trusting anything
- Install Velero CLI `v1.18.0`; run the installer with AWS plugin `v1.14.1`, verified
  `KUBELET_ROOT_DIR`, node-agent on, `prefix=velero`, no volume snapshots,
  `--default-volumes-to-fs-backup`
- Apply `schedule-daily.yaml` and `schedule-weekly.yaml`
- **Verify the node-agent really reads the volumes:** `velero backup describe <name> --details` must
  list all six monitoring PVCs under *Pod Volume Backups*. An empty list is a silent total failure
  that still reports success
- Confirm the `argocd` namespace backup contains its Secrets and Applications (retires #20/#1)
- One object restore into a scratch namespace ([07 step 4.5](07-setup.md#45--prove-one-narrow-restore-local)).
  Do **not** delete a production PVC during setup — that proof belongs in the restore test
- After a week, confirm old backups actually expire (proves the `velero/` delete permission)

**Answer / Output:**
```
(paste here)
```

---

### 5. [#2](../../../issues/2) — Phase 4: Alerting, and where the heartbeat reports to
**Priority: Highest of the "medium" items — until this exists, a stopped backup is silent**

Four alerts ([02 §7](02-backup-strategy.md#7-knowing-it-works)):

1. **No Job 1 backup in 26 h** — external heartbeat after a committed S3 set
2. **No verified Velero backup in 30 h** — separate external heartbeat
3. Latest scheduled Backup/PVB set failed, stale, already reported, or below `MIN_EXPECTED_PVBS` — suppresses #2 ping
4. Root disk free under 10% — in-cluster

Options for #1/#2: a hosted dead-man's switch (healthchecks.io / Cronitor); AWS EventBridge
on S3 `ObjectCreated` + a CloudWatch alarm treating missing data as breaching; or an Alertmanager
hosted outside this cluster.

Commands: [07 steps 5.1–5.4](07-setup.md#51--choose-the-two-dead-man-checks-local). Then **test all
four by deliberately breaking them** —
[07 step 5.5](07-setup.md#55--break-every-alert-on-purpose).

**Answer / Output:**
```
Two heartbeat checks chosen:
HEARTBEAT_URL set on the node:      yes / no
VELERO_HEARTBEAT_URL set:           yes / no
Alert 1 tested by breaking it:      yes / no
Alert 2 tested:                     yes / no
Alert 3 tested:                     yes / no
Alert 4 (disk) tested:              yes / no
```

---

### 6. [#12](../../../issues/12) — Phase 5: Prove a restore works
**Priority: Medium — turns "hope" into "proof". Nothing before this counts as proven**

Procedure: [03 §C](03-restore-runbook.md#c--the-restore-test), driven from
[07 step 5.7](07-setup.md#57--prove-a-restore-works).

- Throwaway Ubuntu VM matching `k3-master`, on a different address
- Install K3s from `k3s-release/` in the bucket rather than `get.k3s.io` — proves the fallback
- Run §A steps 1–11 end to end
- Confirm restored **Prometheus answers a query over pre-incident data** — proof the volume restore
  worked, not just that the pod started
- Confirm HTTPS comes back valid
- Run §B's one-object path; §A already exercises PVC recovery
- Record whether live monitoring files are accepted as best-effort or need application-native backup
- Record real timings, fix the runbook to match reality, set the actual RTO
- Diary the repeat for 3–6 months out

**Answer / Output:**
```
Date run:
Total time (= the real RTO):
What didn't match the runbook:
Next due:
```

---

## Known gaps — the smaller unknowns

### 7. [#4](../../../issues/4) — Where do HTTPS certificates actually come from?
**Priority: High — read-only, two minutes, and it's the one answer that could change the design**

If Traefik issues its own certificates via ACME and keeps `acme.json` in an `emptyDir`, **nothing
backs it up** and every restore returns a site with no valid certificate. Commands in
[07 stage 1.5](07-setup.md#15--where-do-the-https-certificates-come-from-node).

**Answer / Output:**
```
(paste here)
```

---

### 8. [#16](../../../issues/16) — Who can actually perform a restore
**Priority: High — five minutes of writing things down**

There is deliberately no stored restore credential; restores use a normal AWS admin/SSO login. That
only works if the access isn't a single point of failure.
Commands: [07 step 2.7](07-setup.md#27--write-down-who-can-restore-local).

**Answer / Output:**
```
People who can read s3://k3-master-dr:
Bucket name + region recorded outside AWS:   yes / no
Recovery kit (this repo) cloned off k3-master: yes / no
Who rotates the Job 1 and Velero keys, and how often:
```

---

### 9. [#8](../../../issues/8) — `tls/` and `cred/` never checked file-by-file
**Priority: Medium**

List (names + permissions only, never contents) what's actually inside these two folders, and
confirm the backup covers everything — including anything sitting loose directly under `server/`.

**Answer / Output:**
```
(paste here)
```

---

### 10. [#22](../../../issues/22) — Is K3s encrypting Secrets in its own database?
**Priority: Medium — read-only check**

Either answer is fine; `cred/` is backed up regardless. But if it's **on**, restoring
`cred/encryption-config.json` becomes a hard precondition before starting K3s.

```bash
sudo k3s secrets-encrypt status
```

> The other half of this issue — the node-exporter textfile metric — is **closed by removal.** The
> metric proved the script's own opinion of itself and nothing was confirmed to read it. The
> heartbeat in #2 replaces it.

**Answer / Output:**
```
(paste here)
```

---

### 11. [#19](../../../issues/19) — Certificate expiry dates never captured
**Priority: Medium — the "what to do about it" part is written, the numbers aren't**

The restore runbook explains which certificate errors fix themselves and which don't. What's missing
is the actual expiry dates from `k3-master` — [07 stage 1.3](07-setup.md#13--look-inside-tls-and-cred-node).

**Answer / Output:**
```
CA certificates expire:
Leaf certificates expire:
```

---

### 12. [#1](../../../issues/1) / [#20](../../../issues/20) — ArgoCD recoverability
**Priority: Medium — decided, one thing left to verify**

**Decided: no separate daily `argocd admin export`.** Velero backs up the whole `argocd` namespace
including its Secrets, Applications and AppProjects, and Git holds the app definitions.

What's left: confirm every ArgoCD App is defined in Git (anything hand-made comes back from Velero,
not Git), verify the Velero backup really contains ArgoCD's Secrets and Applications as part of #11,
and write down which Git repos/logins ArgoCD depends on. All three happen in
[07 step 4.4](07-setup.md#44--confirm-object-coverage-including-argocd-local).

**Answer / Output:**
```
(paste here)
```

---

### 13. [#15](../../../issues/15) — Single AWS region, no backup-of-the-backup
**Priority: Low — decide explicitly rather than by default**

Reasonable for one server with no failover. Related decision already on the record: we protect
against host loss and a compromised `k3-master`, **not** a compromised AWS account
([02 §9](02-backup-strategy.md#9-the-immutability-decision--made-and-on-the-record)).

**Answer / Output:**
```
(paste here)
```

---

### 14. [#13](../../../issues/13) — Who hosts this server?
**Priority: Low — resolved**

Datalix, treated as on-premise, no snapshot fallback available.

**Answer / Output:**
```
(paste here)
```

---

### 15. [#7](../../../issues/7) — Documentation must not live only on the server
**Priority: Low — resolved.** This GitHub repo is the one true copy.

**Answer / Output:**
```
(paste here)
```

---

## Closed by the simplified design — no action needed

These no longer need answering, because the thing they were about is gone. Kept so nobody reopens
them.

| Issue | Why it's closed |
|-------|-----------------|
| [#14](../../../issues/14) — bucket must be encrypted | Default **SSE-S3** from creation. No key to create, rotate, or lose |
| [#21](../../../issues/21) — the 64 MB multipart upload failed | It failed for want of `kms:Decrypt`. There is no KMS any more, so neither the failure nor its test exists |
| [#24](../../../issues/24) — a bare KMS key id denied every upload | Same: no `KMS_KEY_ID` in the config at all |
| [#5](../../../issues/5) / [#6](../../../issues/6) — host OS settings not backed up | Captured as a plain-text fact sheet in the archive. `/etc/ssh` and `authorized_keys` are deliberately **not** captured |
| [#17](../../../issues/17) — backups didn't record their K3s version | `MANIFEST.json`, beside the archive and inside it, with the version and the real start command. Verify once in #3 |
| [#23](../../../issues/23) — which files belong to the same run | One archive per run. The question no longer arises |
| [#18](../../../issues/18) — the runbook assumed tools that didn't exist | Every flow names what must be installed first |

---

## Suggested order

1. [#4](../../../issues/4) — **check the Traefik certificates first.** Read-only, two minutes, and
   the one answer that could change the design
2. [#3](../../../issues/3) — agree the RPO and RTO while you're still deciding things
3. [#9](../../../issues/9) — the rest of the validation
4. [#10](../../../issues/10) — bucket, credential, Job 1
5. [#11](../../../issues/11) — **install Velero.** Until this exists, a deleted PVC is permanent
6. [#2](../../../issues/2) — pick the heartbeat channel and wire all four alerts
7. [#12](../../../issues/12) — **test a restore.** Nothing before this counts as proven
8. [#16](../../../issues/16), [#8](../../../issues/8), [#22](../../../issues/22),
   [#19](../../../issues/19), [#1](../../../issues/1), [#15](../../../issues/15) — the rest
