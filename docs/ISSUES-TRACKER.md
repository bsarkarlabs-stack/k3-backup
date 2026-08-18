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
- Script that safely backs up the K3s database (already written: `scripts/k3s-track-a-backup.sh`)
- Archive certs, config, node settings
- Upload to S3 with checksums
- Schedule via systemd timer
- Deploy the script onto `k3-master` and confirm a real run works

**Answer / Output:**
```
(paste here)
```

---

### 3. [#11](../../issues/11) — Phase 2: Install Velero
**Priority: Highest — currently not done at all**

What needs to happen:
- Install Velero + S3 plugin, pointed at the same bucket
- Turn on node-agent (needed for our storage type)
- Daily schedule covering every namespace
- Confirm the 6 monitoring data volumes are included
- Do one test restore

**Answer / Output:**
```
(paste here)
```

---

### 4. [#1](../../issues/1) — Phase 3: ArgoCD / Git recoverability
**Priority: Medium**

What needs to happen:
- Confirm every ArgoCD App is defined in Git, not created by hand
- Schedule daily `argocd admin export` to S3
- Write down which Git repos/logins ArgoCD depends on

**Answer / Output:**
```
(paste here)
```

---

### 5. [#2](../../issues/2) — Phase 4: Auto-cleanup + alerting
**Priority: Medium**

What needs to happen:
- S3 lifecycle rules so old backups auto-delete
- Each backup job reports a "last success" timestamp
- Alert via existing Alertmanager if a backup goes stale
- Actually test the alert by breaking a backup on purpose
- Let everything run untouched for one week

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

### 10. [#5](../../issues/5) — Server OS-level settings not backed up
**Priority: Medium / High**

Network settings, firewall rules, SSH keys, timezone — not yet captured automatically.

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

Fixed by adding a `run-manifests/manifest-<timestamp>.json` file to every backup run, recording
the K3s version and every file's checksum. Still needs to actually be deployed to `k3-master`
and confirmed working.

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
**Priority: Medium — open decision, not yet answered**

Two docs disagree: one says a daily `argocd admin export` is required, another argues Velero
already covers it. Needs to be decided after Issue #11 (Velero) actually exists, so we can test
what Velero really captures.

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

1. [#9](../../issues/9) — S3 + logins ready
2. [#14](../../issues/14) — encryption on the bucket (do this at the same time as #9, not after)
3. [#21](../../issues/21) — make sure the login can actually decrypt (fixes the multi-part upload bug)
4. [#10](../../issues/10) — deploy the backup script
5. [#17](../../issues/17) — deploy the version-manifest fix (already written, part of the same script)
6. [#22](../../issues/22) — run the two read-only checks (node-exporter present? K3s Secret encryption on?)
7. [#11](../../issues/11) — install Velero
8. [#20](../../issues/20) — decide on ArgoCD export once Velero is in place
9. [#1](../../issues/1) — ArgoCD/Git recoverability
10. [#2](../../issues/2) — auto-cleanup + alerting
11. [#12](../../issues/12) — test a real restore
12. Everything else in [#3](../../issues/3) — the smaller gaps (#4, #5, #6, #8, #13, #15, #16, #19)
