# 04 — Implementation TODO

Nothing below is built yet. **This is the order to build it in** — each phase produces something
the next phase depends on.

Every phase has a corresponding GitHub Issue. Close the issue, tick the box here.

| Phase | Focus | Priority | Issue |
|-------|-------|----------|-------|
| 0 | Foundations | P0 — do first | [#9](../../issues/9) |
| 1 | Node & cluster-state backup (Track A) | P0 | [#10](../../issues/10) |
| 2 | Kubernetes-level backup (Track B) | P0 | [#11](../../issues/11) |
| 3 | GitOps recoverability (Track C) | P1 | [#1](../../issues/1) |
| 4 | Automation & retention | P1 | [#2](../../issues/2) |
| 5 | Restore validation | P1 | [#12](../../issues/12) |
| 6 | Close known gaps | P2 | [#3](../../issues/3) |

---

## Phase 0 — Foundations
**Priority: P0 — do first. Every later phase depends on this.**

- [ ] Confirm hosting provider, and whether a hypervisor-level VM snapshot is available as a
      belt-and-suspenders option
- [ ] Install `sqlite3` CLI on `k3-master` (or confirm `python3` with the `sqlite3` module is
      available for the `.backup` API)
- [ ] Create the S3 bucket `k3-master-dr` — versioning enabled, SSE-KMS default encryption with a
      customer-managed key, all public access blocked
- [ ] Create a least-privilege IAM user or role scoped to that bucket only
      (`PutObject` / `GetObject` / `ListBucket` on `arn:aws:s3:::k3-master-dr/*`)
- [ ] Create a **separate read-only credential** for restores and store it offline — not on
      `k3-master`
- [ ] Verify S3 connectivity and egress from `k3-master` with a throwaway object

---

## Phase 1 — Node & cluster-state backup (Track A)
**Priority: P0**

Covers [components 1–4 and 8](02-backup-strategy.md#3-backup-components).

- [ ] Script a **consistent** SQLite backup using the `.backup` API — never a raw `cp` of a live
      WAL database
- [ ] Add `tar` of `server/{tls,cred,token,manifests}` to the same script, taken alongside the DB
      snapshot
- [ ] Add `tar` of `/etc/rancher/k3s` and `/etc/systemd/system/k3s.service`
- [ ] Capture node OS configuration into `node-config/`: netplan, UFW rules, SSH host keys and
      `authorized_keys`, timezone/NTP, `dpkg --get-selections`
- [ ] Generate the container image manifest from live pods in the same run
- [ ] SHA-256 checksum every archive **before** upload; store the checksum alongside it
- [ ] Upload to the matching S3 prefixes
- [ ] Schedule via a **systemd timer** — match the existing `dpkg-db-backup.timer` convention
      rather than reintroducing cron (the server has no root crontab today; keep it that way)
- [ ] Verify a full cycle produces the expected objects in every prefix
- [ ] Commit the script to `scripts/` in this repository

---

## Phase 2 — Kubernetes-level backup (Track B)
**Priority: P0**

Covers [components 5, 6 and 7](02-backup-strategy.md#3-backup-components). This is what makes
migration and DR-to-a-new-VM possible at all.

- [ ] Install Velero + the AWS S3 plugin, pointed at the same bucket under the `velero/` prefix
- [ ] Enable the **node-agent** (restic / kopia) — required for `local-path` filesystem backup,
      which has no CSI snapshot capability
- [ ] Create a daily schedule covering **every** namespace, not just application namespaces
- [ ] Confirm the six monitoring PVCs are actually included in the backup
- [ ] Verify a completed backup lists restorable items — **do not trust a green exit code alone**
- [ ] Perform one scoped test restore of a single non-critical resource to prove the path works

---

## Phase 3 — GitOps recoverability (Track C)
**Priority: P1**

Covers [component 9](02-backup-strategy.md#component-9--git--argocd-recoverability).

- [ ] Audit every ArgoCD Application: confirm each is defined via app-of-apps in Git, not created
      ad hoc. Anything created ad hoc is unrecoverable from Git alone.
- [ ] Schedule daily `argocd admin export` to the `argocd-export/` prefix
- [ ] Document exactly which Git remotes and credentials the ArgoCD repo-server depends on
- [ ] Confirm whether the monitoring stack (Prometheus/Loki/Grafana) is deployed as
      config-as-code. If it is, monitoring *configuration* recovery collapses into this track and
      only *historical data* needs Phase 2.

---

## Phase 4 — Automation & retention
**Priority: P1**

- [ ] Apply the S3 lifecycle rules from the
      [retention matrix](02-backup-strategy.md#retention-matrix)
- [ ] Push a `backup_last_success_timestamp` metric from each job
- [ ] Wire alerts into the **existing** Alertmanager — alert if any track's timestamp is stale by
      more than 1.5× its own frequency. No new alerting tool.
- [ ] Confirm the alert actually fires by deliberately failing one job
- [ ] Let all three tracks run unattended for **one full week** before relying on them

---

## Phase 5 — Restore validation
**Priority: P1 — the phase that converts hope into evidence.**

- [ ] Provision a throwaway VM matching `k3-master`'s specification
- [ ] Execute the full [restore runbook](03-restore-runbook.md) end-to-end against it
- [ ] Record the actual RTO
- [ ] Fix whatever breaks, and update the runbook with what was actually required
- [ ] Confirm restored Prometheus contains **historical** data — proof that PVC restore worked,
      not just that pods started
- [ ] Schedule the drill to repeat **quarterly**

---

## Phase 6 — Close known gaps
**Priority: P2 — does not block Phases 0–5, but does block a clean restore.**

- [ ] Work through the [gap list](05-gaps-and-open-questions.md) — one issue per gap
- [ ] Determine the ingress TLS certificate source (no cert-manager was observed) and how to back
      it up
- [ ] Decide explicitly whether single-region S3 is acceptable, or whether cross-region
      replication is warranted
- [ ] Assign a named owner and rotation cadence for the backup IAM credentials
- [ ] Keep this repository as the canonical copy of all DR documentation — it must never live only
      on `k3-master`

---

## Definition of done

The backup programme is complete when **all** of the following are true:

1. All three tracks run automatically, unattended, on schedule
2. A failed backup pages someone within one cycle
3. The restore runbook has been executed successfully at least once, end to end
4. The measured RTO is known and accepted by the business
5. This documentation lives in Git, not on the server it describes recovering
