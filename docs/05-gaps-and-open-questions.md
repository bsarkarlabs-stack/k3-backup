# 05 — Gaps & Open Questions

These are things we **don't actually know for sure yet** — they weren't confirmed in
[01 — Discovery Baseline](01-discovery-baseline.md). **Don't assume an answer** — each one has
its own GitHub Issue to track it.

| # | What we don't know | How serious | What it blocks | Issue |
|---|-----|----------|--------|-------|
| 1 | Who exactly hosts this server | Medium | Planning a hosting-level snapshot as a backup | [#13](../../issues/13) |
| 2 | Where our HTTPS certificates actually come from | **High** | A clean, reliable restore | [#4](../../issues/4) |
| 3 | The server's OS-level settings aren't backed up | **High** | Step 2 of the restore runbook | [#5](../../issues/5) |
| 4 | List of installed system software isn't saved | Low | Getting a fresh server caught up quickly | [#6](../../issues/6) |
| 5 | Secrets would reach S3 unencrypted unless we turn on encryption | **Critical** | Phase 2 | [#14](../../issues/14) |
| 6 | All backups sit in one AWS region, no backup-of-the-backup | Medium | Recovering from a whole-region outage | [#15](../../issues/15) |
| 7 | This documentation could be a single point of failure | Medium | — *(fixed by this repo existing)* | [#7](../../issues/7) |
| 8 | Nobody's assigned to rotate backup passwords/keys | Medium | Keeping our security posture solid over time | [#16](../../issues/16) |
| 9 | Two certificate folders were never checked file-by-file | **High** | Feeling confident our restore will actually work | [#8](../../issues/8) |

---

## 1. Who exactly hosts this server

When we tried checking for AWS-specific server info, we got:
`AWS EC2 metadata not available`. Just because the `aws` command-line tool happens to be
installed doesn't mean AWS actually hosts this server.

*(Update: this has since been resolved — the actual host is **Datalix**, and we're treating this
server as an on-premise-style machine with **no** automatic hosting-level snapshot feature
available. See [07](07-phase-0-1-execution.md) for how this was confirmed.)*

**Why it matters:** we can't plan any hosting-level snapshot as an extra safety net until we know
who's actually hosting us. A hosting snapshot wouldn't replace our own backup plan, but it would
be a nice free extra layer of protection, if it's available.

**How to close this out:** check billing records, the hosting control panel, or low-level system
info to confirm the actual provider. *(Already done — see the update above.)*

---

## 2. Where our HTTPS certificates actually come from

**How serious: High.**

We didn't find any certificate-management tool (like cert-manager) running during discovery. So
we genuinely don't know if Traefik's HTTPS certificates are:

- Manually saved as Kubernetes Secrets (→ already covered by Velero, item 7 in the backup
  strategy), or
- Automatically issued by Traefik's own built-in certificate system, and stored in a file called
  `acme.json` that might live on a disk volume, or might just be sitting in temporary,
  disappears-on-restart storage, or
- Handled by something else entirely, upstream of our server

**Why it matters:** each of these three possibilities needs a completely different backup
approach. If the certificate is sitting in temporary storage, **it's currently not backed up by
anything in our plan at all** — and after a restore, we'd silently end up with a broken HTTPS
certificate, with no warning beforehand.

**How to close this out:** look at how Traefik is set up and find out exactly where (if anywhere)
`acme.json` is being saved.

---

## 3. The server's OS-level settings aren't backed up yet

**How serious: High.** This is exactly what
[restore runbook step 2](03-restore-runbook.md#step-2--restore-node-level-os-configuration)
needs, and right now there's nothing behind it.

Things we haven't written down or backed up:

- Network settings for our static IP addresses (`45.90.98.51`, `10.10.10.103`)
- Firewall rules
- SSH login keys and who's allowed to log in
- Timezone and clock-sync settings
- Any other system-level customizations beyond the K3s setup itself

**Why it matters:** without this, restore step 2 means trying to remember and rebuild all of this
from memory during an actual outage — exactly the moment when relying on memory is least
reliable.

**How to close this out:** this is covered by
[Phase 1](04-implementation-todo.md#phase-1--node--cluster-state-backup-track-a) — we'll capture
it into a `node-config/` backup folder.

---

## 4. List of installed system software isn't saved

Running `dpkg --get-selections` would let us quickly get a fresh server caught up to match the
old one, beyond just knowing the four tools we already confirmed are installed (`rsync`, `aws`,
`tar`, `gzip`).

**Why it matters:** minor — but it saves time during an outage, for basically zero extra storage
cost.

**How to close this out:** add it to the same `node-config/` backup from Phase 1.

---

## 5. Secrets would reach S3 unencrypted unless we turn on encryption

**How serious: Critical.**

A Velero backup contains, among other things, **real, readable Kubernetes Secrets** —
image-pull credentials, HTTPS certificate keys, ArgoCD's Git login details, and app secrets. The
`server-identity/` folder likewise contains the cluster's master certificate and its secret
access token.

**Why it matters:** without encryption and tight access controls, our backup bucket would
actually be a *more valuable target* for an attacker than the server it's protecting. This is a
must-have, not a nice-to-have.

**How to close this out:** [Phase 0](04-implementation-todo.md#phase-0--foundations) — the bucket
must be created with encryption turned on **from the very start**. We can't create it first and
encrypt it later — default encryption doesn't apply retroactively to files already uploaded
before it was turned on.

---

## 6. All backups sit in one AWS region, no backup-of-the-backup

This is a reasonable choice given we only have one server with no built-in failover — the server
itself is a bigger single point of failure than losing an entire AWS region would be.

**Why it matters:** it should be a **decision we actually made on purpose**, not just a default
nobody thought about.

**How to close this out:** decide this explicitly during
[Phase 6](04-implementation-todo.md#phase-6--close-known-gaps) and write down our reasoning here.

---

## 7. This documentation could be a single point of failure

If this documentation only lived on `k3-master` itself, it would disappear in exactly the
scenario it's meant to help us survive.

**Status: already fixed** — this GitHub repo is now the one true copy. The only remaining
discipline needed is to actually keep updating it here, instead of editing some separate copy
directly on the server.

---

## 8. Nobody's assigned to rotate backup passwords/keys

The login credentials our backup scripts use need a regular rotation schedule and one specific
person responsible for making sure it happens.

**Why it matters:** long-lived, never-rotated credentials with write access to our backup bucket
are an ongoing risk — especially since that bucket also holds our cluster's master certificate.

**How to close this out:** assign one person and a schedule (we suggest every 90 days) during
Phase 6.

---

## 9. Two certificate folders were never checked file-by-file

**How serious: High.**

Our [backup strategy](02-backup-strategy.md#2-the-correction-that-changes-the-whole-plan) already
flagged these two folders as top-priority — but we've never actually listed what files are inside
them on this specific server.

**Why it matters:** our backup plan is correct in theory, but hasn't actually been checked
against what's really on this server. There could be extra files, or a slightly different layout,
that our backup script would accidentally miss.

**How to close this out:** list what's inside both folders — **just the file names and
permissions, never open or read the actual file contents** — and confirm our Phase 1 backup
script would actually catch everything that's there.

---

## Adding a new gap

Whenever we find something new we don't know:

1. Add a row to the table at the top of this document
2. Add a section below explaining **why it matters** and **how we plan to find out** — not just
   what's missing
3. Open a GitHub Issue for it and link that issue in the table
