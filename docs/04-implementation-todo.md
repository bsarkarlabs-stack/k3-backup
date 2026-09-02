# 04 — Implementation TODO

Five phases. Each produces something the next one needs. Step-by-step commands are in
[07 — Setup](07-setup.md).

| Phase | What it is | Urgency | Issue |
|-------|------------|---------|-------|
| 1 | **Validate** — the server, and the assumptions the design rests on | Do this first | [#9](../../../issues/9) |
| 2 | **Job 1** — the K3s backup script + systemd timer | Highest | [#10](../../../issues/10) |
| 3 | **Job 2** — Velero for objects and PVC data | Highest | [#11](../../../issues/11) |
| 4 | **Monitor** — alert when a backup doesn't arrive | Medium | [#2](../../../issues/2) |
| 5 | **Restore-test** — prove all of the above actually works | Medium | [#12](../../../issues/12) |

Phases 2 and 3 are both "highest" on purpose: Job 1 rebuilds the server, Job 2 is the only thing
that can bring a PVC or a single deleted object back. Neither one alone is a backup solution.

---

## Phase 1 — Validate

- [ ] Run `k3s-backup-preflight.sh --no-aws` and get a READY result
- [ ] Confirm the baseline still holds: hostname, K3s version, service enabled, ≥5 GB free,
      `etcd-snapshot ls` still reports the datastore disabled
- [ ] List `server/tls/` and `server/cred/` file-by-file (names and permissions only) and confirm
      nothing identity-related sits loose under `server/` ([#8](../../../issues/8))
- [ ] Record the certificate expiry dates — CA ≈10 years, leaf ≈1 year ([#19](../../../issues/19))
- [ ] `k3s secrets-encrypt status` — if enabled, `cred/encryption-config.json` becomes a hard
      restore precondition ([#22](../../../issues/22))
- [ ] **Find out where Traefik's HTTPS certificates come from.** If ACME + `emptyDir`, nothing backs
      them up and every restore returns broken HTTPS ([#4](../../../issues/4))
- [ ] Confirm Python's `sqlite3` module works (nothing needs installing if it does)
- [ ] **Agree an RPO and an RTO**, or record explicitly that the design runs on the assumed 24 h /
      2–4 h ([02 §1](02-backup-strategy.md#1-two-numbers-to-agree-on-first--still-open))

---

## Phase 2 — Job 1: the K3s server backup

Script: [`scripts/k3s-server-backup.sh`](../scripts/k3s-server-backup.sh).

- [ ] Create the bucket: public access blocked, versioning on, **default SSE-S3 encryption**, one
      HTTPS-only bucket policy
- [ ] Six lifecycle rules — current expiry for Job 1 and preflight, noncurrent-only expiry for
      `velero/` and `k3s-release/`, plus abort stuck multipart uploads
- [ ] Create separate Job 1 and Velero IAM users. Job 1 has write-only access to its prefixes;
      Velero has read/write/delete access only to `velero/*`
- [ ] Write `/etc/k3s-backup/backup.env` (0600 root:root) with bucket, region, keys and
      `HEARTBEAT_URL`
- [ ] Install the script and both units; re-run the preflight with AWS enabled and confirm the
      read-back and delete guardrails are **refused**
- [ ] `DRY_RUN=1` run — one `.tar.gz`, one `.sha256`, one `MANIFEST.json`, and K3s untouched
      (`NRestarts` unchanged)
- [ ] Confirm `MANIFEST.json` records a real `k3s_version` and the real `k3s_start_command`
      ([#17](../../../issues/17))
- [ ] One real run — four objects including last-written `COMPLETE.json` land under a unique
      `k3s/daily/<run-id>/`; the K3s binary and checksum land under `k3s-release/<version>/`
- [ ] Download it from your laptop, verify the `COMPLETE.json` → `MANIFEST.json` → archive chain,
      extract, and confirm `state.db` passes `PRAGMA integrity_check` with a non-zero `kine` row count
- [ ] `systemctl enable --now k3s-backup.timer`, confirm with `systemctl list-timers`
- [ ] Confirm a Sunday run also writes `k3s/weekly/`

---

## Phase 3 — Job 2: Velero

This is the piece that makes PVC data and single-object restores possible at all. Nothing else in
this plan covers either.

- [ ] Find K3s's kubelet root **before** trusting anything
- [ ] Install pinned Velero CLI `v1.18.0`; run
      [`scripts/velero/install-velero.sh`](../scripts/velero/install-velero.sh) with AWS plugin
      `v1.14.1` and the verified `KUBELET_ROOT_DIR` — Velero +
      plugin, node-agent on, `prefix=velero`, `--use-volume-snapshots=false`,
      `--default-volumes-to-fs-backup`
- [ ] Apply [`schedule-daily.yaml`](../scripts/velero/schedule-daily.yaml) and
      [`schedule-weekly.yaml`](../scripts/velero/schedule-weekly.yaml)
- [ ] **Verify the node-agent actually reads the volumes.** `velero backup describe <name> --details`
      must list all six monitoring PVCs under *Pod Volume Backups*. An empty list means the hostPath
      doesn't match the kubelet root — it fails silently and looks like success
- [ ] Confirm cluster-scoped resources are in the backup (CRDs, ClusterRoles, StorageClass)
- [ ] Confirm the `argocd` namespace backup contains its Secrets and Applications — this is what
      retires the separate ArgoCD export ([#20](../../../issues/20), [#1](../../../issues/1))
- [ ] One object restore plus one controller-aware PVC restore. Suspend ArgoCD and delete the
      volume-owning controller as well as the claim; scaling it to zero is not sufficient
- [ ] After a week, confirm old backups actually expire — proves the `velero/` delete permission is
      right
- [ ] Pin the Velero CLI version to match `install-velero.sh` and record both it and the plugin
      version — `velero install` deploys `velero/velero:<CLI version>`, so an unpinned CLI silently
      decides the server version

---

## Phase 4 — Monitor

Four alerts, and only four ([02 §7](02-backup-strategy.md#7-knowing-it-works)).

- [ ] **Decide where the heartbeat reports to** — hosted dead-man's switch, AWS EventBridge +
      CloudWatch, or an off-cluster Alertmanager. Create separate checks for Job 1 and Velero;
      both detect server loss because both pings stop ([#2](../../../issues/2))
- [ ] Set `HEARTBEAT_URL` in `backup.env`, run the job by hand, confirm `heartbeat sent` in the log
- [ ] Install the supplied Velero verifier and second external heartbeat. It must validate the
      newest scheduled Backup, age, every PVB phase, `MIN_EXPECTED_PVBS`, and that the backup was
      not already reported (a skipped schedule must stop the heartbeat)
- [ ] Alert on root disk free space under 10%
- [ ] **Test all four by deliberately breaking them.** An untested alert is a decoration. For the
      volume-count one, scale a workload to zero and confirm the next backup trips it. For the
      missed-run one, run the verifier twice without a new backup in between and confirm the second
      run refuses to ping
- [ ] Watch the first two or three runs by hand, then stop watching — the alerts are the plan

---

## Phase 5 — Restore-test

**This is the phase that turns "we think this works" into "we know."** Full procedure:
[03 §C](03-restore-runbook.md#c--the-restore-test).

- [ ] Throwaway Ubuntu VM matching `k3-master`, on a different address
- [ ] Install K3s from `k3s-release/` in the bucket rather than `get.k3s.io`, so the fallback is
      proven while there's time to fix it
- [ ] Run §A steps 1–11 end to end
- [ ] Confirm restored **Prometheus answers a query over pre-incident data** — proof the volume
      restore worked, not just that the pod started
- [ ] Confirm HTTPS comes back valid
- [ ] Run §B's one-object path; §A already exercises the destructive PVC path
- [ ] Record the real timings, fix the runbook to match what happened, and set the actual RTO
- [ ] Diary the repeat for **3–6 months out**, and after any K3s upgrade

---

## When is this done?

1. Both jobs run on schedule, untouched, for a week
2. A missing or failed backup pages someone within one cycle — **including when the server is dead**
3. Same-cluster recovery and clean-cluster fallback have both been run, and the runbook matches
4. We know the real RTO and the business has agreed it's acceptable
5. This documentation lives in Git, not only on the server it describes how to recover
