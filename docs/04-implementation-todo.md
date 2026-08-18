# 04 — Implementation TODO

Nothing below has been built yet. **This is the order we plan to build it in** — each phase
produces something the next phase needs.

Every phase has a matching GitHub Issue. When work is done: close the issue, and tick the box
here.

| Phase | What it's about | How urgent | Issue |
|-------|-------|----------|-------|
| 0 | Getting the basics ready | Do this first | [#9](../../issues/9) |
| 1 | Back up the server itself | Highest | [#10](../../issues/10) |
| 2 | Back up what's running inside Kubernetes | Highest | [#11](../../issues/11) |
| 3 | Make sure ArgoCD/Git are recoverable | Medium | [#1](../../issues/1) |
| 4 | Auto-cleanup + alerting | Medium | [#2](../../issues/2) |
| 5 | Actually test a restore | Medium | [#12](../../issues/12) |
| 6 | Close remaining unknowns | Low | [#3](../../issues/3) |

---

## Phase 0 — Getting the basics ready
**How urgent: Do this first. Every later phase depends on this being done.**

- [ ] Confirm who hosts this server, and whether they offer a snapshot feature we could use as
      an extra safety net
- [ ] Install the `sqlite3` command-line tool on `k3-master` (or confirm Python's built-in
      `sqlite3` module works instead — either gives us the safe backup feature we need)
- [ ] Create the S3 bucket `k3-master-dr` — with file-history (versioning) turned on, our own
      dedicated encryption key set as the default, and all public access blocked
- [ ] Create a dedicated login that can *only* touch this one bucket
      (and can only add/read/list files — nothing more)
- [ ] Create a **separate, read-only login** just for restores, and store it somewhere safe
      offline — not on `k3-master`
- [ ] Test that `k3-master` can actually reach S3 over the internet, using a throwaway test file

---

## Phase 1 — Back up the server itself
**How urgent: Highest**

Covers [items 1–4 and 8](02-backup-strategy.md#3-backup-components) from the backup strategy.

- [ ] Write a script that makes a **safe, consistent** backup of the SQLite database using its
      proper backup feature — never a plain file copy of a live database
- [ ] In the same script, also archive the `server/tls`, `server/cred`, `server/token`, and
      `server/manifests` folders, at the same time as the database backup
- [ ] Also archive `/etc/rancher/k3s` and `/etc/systemd/system/k3s.service`
- [ ] Save the server's OS-level settings into a `node-config/` backup: network settings,
      firewall rules, SSH keys and allowed logins, timezone/clock settings, and the list of
      installed system packages
- [ ] Generate a list of container images currently running, as part of the same backup run
- [ ] Calculate a fingerprint (SHA-256 checksum) for every file **before** uploading it, and save
      that fingerprint alongside the file
- [ ] Upload everything to the matching S3 folders
- [ ] Schedule this to run automatically using a **systemd timer** (matching how the server
      already schedules its one existing routine job) — not a cron job, since this server
      doesn't use cron today and we want to keep it that way
- [ ] Confirm one full run actually produces the files we expect, in every folder
- [ ] Save this script into `scripts/` in this repo

---

## Phase 2 — Back up what's running inside Kubernetes
**How urgent: Highest**

Covers [items 5, 6, and 7](02-backup-strategy.md#3-backup-components) from the backup strategy.
This is the piece that makes it possible to move to a new server or a new K3s version at all.

- [ ] Install Velero plus its AWS S3 plugin, pointed at the same bucket, saving under the
      `velero/` folder
- [ ] Turn on the **node-agent** feature (needed because our storage type doesn't support
      snapshot-based backups)
- [ ] Set up a daily schedule that covers **every** namespace, not just the ones with our apps
- [ ] Double-check that our six monitoring data volumes are actually included in the backup
- [ ] After a backup completes, actually check what's inside it — **don't just trust a green
      checkmark**
- [ ] Do one small test restore of something unimportant, just to prove the whole process works

---

## Phase 3 — Make sure ArgoCD/Git are recoverable
**How urgent: Medium**

Covers [item 9](02-backup-strategy.md#component-9--git--argocd-recoverability) from the backup
strategy.

- [ ] Go through every ArgoCD App and confirm each one is properly defined in our Git setup, not
      created by hand outside of it. Anything created by hand can't be recovered from Git alone.
- [ ] Schedule a daily `argocd admin export`, saved to the `argocd-export/` folder
- [ ] Write down exactly which Git repos and login credentials ArgoCD depends on
- [ ] Confirm whether our monitoring setup (Prometheus/Loki/Grafana) is defined as code in Git.
      If it is, its *configuration* is already covered by this phase, and only its *historical
      data* still needs Phase 2's backup.

---

## Phase 4 — Auto-cleanup and alerting
**How urgent: Medium**

- [ ] Set up S3's automatic cleanup rules, following the
      [table in the backup strategy](02-backup-strategy.md#retention-matrix)
- [ ] Have each backup job report a "last successful run" timestamp
- [ ] Set up an alert using our **existing** monitoring/alerting tool — if any backup's timestamp
      gets older than 1.5× how often it's supposed to run. No new alerting tool needed.
- [ ] Actually test that the alert fires, by deliberately making one backup job fail on purpose
- [ ] Let all three backup tracks run on their own, untouched, for **one full week** before we
      start relying on them

---

## Phase 5 — Actually test a restore
**How urgent: Medium — this is the phase that turns "we hope this works" into "we know this
works."**

- [ ] Get a throwaway test server matching `k3-master`'s specs
- [ ] Go through the entire [restore runbook](03-restore-runbook.md) on it, start to finish
- [ ] Write down exactly how long it took
- [ ] Fix whatever broke along the way, and update the runbook to reflect what actually happened
- [ ] Confirm the restored Prometheus actually has **old, historical** data in it — proof that
      the app-data restore really worked, not just that the pods started up
- [ ] Schedule this test to repeat **every 3 months**

---

## Phase 6 — Close remaining unknowns
**How urgent: Low — doesn't block phases 0–5, but does need to happen before we can call this
truly "done."**

- [ ] Work through the [list of open questions](05-gaps-and-open-questions.md), one at a time
- [ ] Figure out where our HTTPS certificates actually come from (we didn't find any
      certificate-management tool during discovery) and how to back that up
- [ ] Make a clear decision: is it OK that all our backups sit in one AWS region, or do we need
      backups copied to a second region too?
- [ ] Assign one specific person to be responsible for rotating the backup login
      credentials on a regular schedule
- [ ] Keep this repo as the one true copy of all this documentation — never let it live only on
      `k3-master`

---

## When is this whole project actually "done"?

We can call the backup project complete when **all** of these are true:

1. All three backup tracks run automatically, on their own, on schedule
2. If a backup ever fails, someone gets alerted within one cycle
3. We've successfully run through the entire restore process at least once, start to finish
4. We know exactly how long a full restore takes, and the business has agreed that's acceptable
5. This documentation lives in Git — not only on the server it's describing how to recover
