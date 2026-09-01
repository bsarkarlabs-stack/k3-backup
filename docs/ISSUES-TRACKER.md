# Issues Tracker — Answer & Fix One by One

> **Note:** This file was created on user request, to list every open issue in one place so
> answers and outputs can be filled in one by one. **Do not delete this file.**

How to use this file: go top to bottom, in order. For each issue, fill in the **Answer /
Output** box with whatever you find (command output, a decision, a "yes it's done" — whatever
applies). Once an issue is answered, we mark it done and move to the next one.

---

## Build Phases — the main work, do these in order

### 1. [#9](../../issues/9) — Phase 0: Get the basics ready
**Priority: Do this first — everything else depends on it**

What needs to happen:
- Confirm who hosts the server (already known: Datalix, on-premise, no snapshot feature)
- Install `sqlite3` or confirm Python's `sqlite3` module works
- Create the S3 bucket `k3-master-dr` — versioning ON, own encryption key, public access blocked
- Create a write-only login for the server to use
- Create a separate read-only login for restores, store it offline
- Test that the server can actually reach S3

**Answer / Output:**
```
(paste here)
```

---

### 2. [#10](../../issues/10) — Phase 1: Back up the server itself
**Priority: Highest**

What needs to happen:
- Deploy `scripts/k3s-server-backup.sh` + `scripts/systemd/k3s-backup.{service,timer}` (both
  already written) onto `k3-master`
- Confirm a dry run produces `state.db`, `k3s-identity.tar.gz`, `node-config.tar.gz`,
  `MANIFEST.json` and their `.sha256` files
- Confirm one real run lands in `s3://k3-master-dr/k3s/daily/YYYY-MM-DD/`
- `systemctl enable --now k3s-backup.timer`

**Answer / Output:**
```
(paste here)
```

---

### 3. [#11](../../issues/11) — Phase 2: Install Velero
**Priority: Highest — currently not done at all. This is half the design.**

What needs to happen:
- Run `scripts/velero/install-velero.sh` — Velero + AWS plugin, node-agent on, `prefix=velero`
- Apply `schedule-daily.yaml` and `schedule-weekly.yaml`
- **Verify the node-agent really reads the volumes:** `velero backup describe <name> --details`
  must list all six monitoring PVCs under *Pod Volume Backups*. An empty list is a silent
  total failure that still reports success
- Confirm the `argocd` namespace backup contains its Secrets and Applications — this is what
  retires the separate ArgoCD export (#20, #1)
- Do one test restore into a scratch namespace
- Confirm old backups actually expire after their TTL (proves `s3:DeleteObject` is granted)

**Answer / Output:**
```
(paste here)
```

---

### 4. [#1](../../issues/1) / [#20](../../issues/20) — ArgoCD recoverability
**Priority: Medium — decision made, one thing left to verify**

**Decided: no separate daily `argocd admin export`.** Velero backs up the whole `argocd` namespace
including its Secrets, Applications and AppProjects, and Git holds the app definitions. The export
would be duplicate coverage.

What's left:
- Confirm every ArgoCD App is defined in Git, not created by hand (anything hand-made can't come
  back from Git alone — it comes back from Velero)
- Verify the Velero backup really contains ArgoCD's Secrets and Applications, as part of #11
- Write down which Git repos/logins ArgoCD depends on

**Answer / Output:**
```
(paste here)
```

---

### 5. [#2](../../issues/2) — Phase 3: Retention + alerting
**Priority: Medium**

What needs to happen:
- Exactly two S3 lifecycle rules: `k3s/daily/` expire 8 days, `k3s/weekly/` expire 31 days
- **Confirm there is no lifecycle rule on `velero/`** — one would silently corrupt Velero's Kopia
  repository, and you'd only find out during a restore
- Alert on the **age of the newest object** under `k3s/daily/` (~36 h threshold) — this proves the
  backup arrived, unlike the script's own success metric
- Alert on `velero_backup_last_successful_timestamp`
- Actually test both alerts by breaking a run on purpose
- Let both jobs run untouched for one week

**Answer / Output:**
```
(paste here)
```

---

### 6. [#12](../../issues/12) — Phase 5: Actually test a restore
**Priority: Medium — turns "hope" into "proof"**

What needs to happen:
- Spin up a throwaway test server matching `k3-master`'s specs
- Run the full restore runbook end to end
- Record how long it actually took
- Fix whatever broke, update the runbook

**Answer / Output:**
```
(paste here)
```

---

### 7. [#3](../../issues/3) — Phase 6: Close remaining unknowns
**Priority: Low — doesn't block earlier phases**

What needs to happen:
- Work through every gap listed below, one at a time

**Answer / Output:**
```
(paste here)
```

---

## Known Gaps — smaller unknowns

### 8. [#14](../../issues/14) — Bucket must be encrypted
**Priority: Highest / Critical**

Secrets reach S3 in plain text unless SSE-KMS encryption is turned on **from the bucket's
creation**, not added later.

**Answer / Output:**
```
(paste here)
```

---

### 9. [#4](../../issues/4) — Where do HTTPS certificates actually come from?
**Priority: Medium / High**

Need to check if Traefik's certificates are Kubernetes Secrets, or issued automatically via
`acme.json` (and if so, whether that file lives on disk or in temporary storage).

**Answer / Output:**
```
(paste here)
```

---

### 10. [#5](../../issues/5) / [#6](../../issues/6) — Server OS-level settings not backed up
**Priority: Medium — resolved in the design, needs one confirming run**

Network settings, firewall rules, SSH keys, timezone and the installed-package list are now
captured by job 1 as `node-config.tar.gz`, in the same folder as everything else — no separate job,
no separate prefix. Confirm the file appears in the first real backup and contains what you expect.

**Answer / Output:**
```
(paste here)
```

---

### 11. [#8](../../issues/8) — `tls/` and `cred/` folders never checked file-by-file
**Priority: Medium / High**

Need to list (names + permissions only, never contents) what's actually inside these two
folders, and confirm the backup script covers everything.

**Answer / Output:**
```
(paste here)
```

---

### 12. [#13](../../issues/13) — Who hosts this server?
**Priority: Low — mostly resolved**

Already answered: Datalix, treated as on-premise, no snapshot fallback available.

**Answer / Output:**
```
(paste here)
```

---

### 13. [#6](../../issues/6) — Installed system software list not saved
**Priority: Low**

Add `dpkg --get-selections` output to the node-config backup.

**Answer / Output:**
```
(paste here)
```

---

### 14. [#15](../../issues/15) — Single AWS region, no backup-of-the-backup
**Priority: Low**

Decide explicitly: is one region acceptable, or do we need cross-region copies too?

**Answer / Output:**
```
(paste here)
```

---

### 15. [#7](../../issues/7) — Documentation must not live only on the server
**Priority: Low — already resolved**

Already fixed: this GitHub repo is the one true copy.

**Answer / Output:**
```
(paste here)
```

---

### 16. [#16](../../issues/16) — No owner for credential rotation
**Priority: Low**

Assign one specific person + a schedule (suggested: every 90 days) to rotate the backup
login credentials.

**Answer / Output:**
```
(paste here)
```

---

## Found during a K3s review — newer issues

### 17. [#17](../../issues/17) — Backups never recorded which K3s version made them
**Priority: Highest — fixed in code, not yet deployed**

Fixed by writing a `MANIFEST.json` into every backup run's folder, recording the K3s version, the
OS release and every file's checksum. It now lives beside the files it describes rather than in its
own prefix, so it can't expire before them. Still needs to be deployed to `k3-master` and confirmed
working.

**Answer / Output:**
```
(paste here)
```

---

### 18. [#18](../../issues/18) — Restore runbook assumed tools that don't exist yet
**Priority: Medium — fixed**

Fixed by adding a "what this runbook can actually do today" table and marking restore steps 8
and 9 (Velero restore, ArgoCD import) as blocked until Issue #11 is done.

**Answer / Output:**
```
(paste here)
```

---

### 19. [#19](../../issues/19) — Nobody wrote down how K3s certificates expire
**Priority: Medium — fixed**

Fixed by adding a "normal vs. real problem" table for certificate errors during restore, and a
warning never to regenerate the master certificate. Still need to actually capture the real
expiry dates from `k3-master` (Stage B.1 in doc 07) — nobody has run that check yet.

**Answer / Output:**
```
(paste here)
```

---

### 20. [#20](../../issues/20) — Do we actually need the ArgoCD settings export?
**Priority: Medium — DECIDED: no**

Velero backs up the whole `argocd` namespace including Secrets, Applications and AppProjects, and
Git holds the app definitions. A separate daily export is duplicate coverage for one more scheduled
job. Removed from the design.

The one thing to verify, during #11: that the Velero backup really does contain ArgoCD's Secrets
and Applications. If it somehow doesn't, reopen this.

**Answer / Output:**
```
(paste here)
```

---

### 21. [#21](../../issues/21) — Backup login couldn't actually upload our database file
**Priority: Critical — fixed**

The server's backup login was given no `kms:Decrypt` permission (reasoning: it only ever writes,
never reads). But any file over 8 MB uploads as a **multi-part** upload, and multi-part uploads
to an encrypted bucket need `kms:Decrypt` too. Our database backup is ~64 MB — so **every real
backup would have failed** with `AccessDenied`, while the small test file in Stage D would have
passed and hidden the problem until the first real backup.

Fixed by adding `kms:Decrypt` (scoped to just our one key) and changing the Stage D test to
upload a 64 MB file instead of a tiny one.

**Answer / Output:**
```
(paste here)
```

---

### 22. [#22](../../issues/22) — Two things that can only be checked on the server
**Priority: High / Medium — read-only checks, waiting on someone running them**

Two separate questions bundled under one issue:

- **Does our "backup succeeded" signal go anywhere?** The script writes a success metric to
  `/var/lib/node_exporter/textfile_collector` — but we never confirmed node-exporter is even
  installed, or that this folder is reachable. If not, the signal goes nowhere and Phase 4
  alerting would be built on a hook that does nothing.
- **Is K3s encrypting Secrets inside its own database?** If yes, there's a key file
  (`cred/encryption-config.json`) that's required to read any Secret after a restore. We already
  back up all of `cred/` either way — this is about knowing, not about coverage.

Both have read-only checks waiting in [07 Stage B.1a/B.1b](07-phase-0-1-execution.md) — nobody's
run them on `k3-master` yet.

**Answer / Output:**
```
(paste here)
```

---

## Suggested order to work through this

1. [#4](../../issues/4) — **check the Traefik certificates first.** It's read-only, takes two
   minutes, and it's the one answer that could change the design. If `acme.json` sits in an
   `emptyDir`, nothing here backs it up and every restore comes back with broken HTTPS
2. [#9](../../issues/9) + [#14](../../issues/14) — bucket, encryption key and both logins.
   Encryption must be on **at creation**, not added afterwards
3. [#21](../../issues/21) — prove the writer login can do a 64 MB multipart upload
4. [#10](../../issues/10) + [#17](../../issues/17) — deploy job 1 and confirm `MANIFEST.json`
   records a real K3s version
5. [#11](../../issues/11) — **install Velero.** Until this exists, a deleted PVC is permanent
6. [#22](../../issues/22) — the two read-only checks (node-exporter present? K3s secret encryption
   on?)
7. [#1](../../issues/1) — confirm every ArgoCD App is defined in Git ([#20](../../issues/20) is
   already decided)
8. [#2](../../issues/2) — retention rules + backup-arrived alerting
9. [#12](../../issues/12) — **test both restore flows.** Nothing before this counts as proven
10. Everything else in [#3](../../issues/3) — the smaller gaps (#8, #13, #15, #16, #19)
