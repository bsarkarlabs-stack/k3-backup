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
| 10 | Backups didn't record which K3s version made them | **Critical** | Every single restore | [#17](../../issues/17) |
| 11 | Restore runbook assumed tools we haven't built yet | **High** | Being able to follow the runbook at all | [#18](../../issues/18) |
| 12 | Nobody wrote down how K3s certificates expire | **High** | Not panicking during a restore | [#19](../../issues/19) |
| 13 | Do we actually need the ArgoCD settings export? | Decision | How much Phase 3 involves | [#20](../../issues/20) |
| 14 | Backup login couldn't upload our 64 MB database file | **Critical** | The very first real backup | [#21](../../issues/21) |
| 15 | Our "backup succeeded" signal may go nowhere | **High** | Phase 4 alerting working at all | [#22](../../issues/22) |
| 16 | Is K3s encrypting Secrets inside its own database? | Medium | How critical `cred/` is | [#22](../../issues/22) |

> Items 10–12 and 14 came out of K3s reviews of the backup script and docs. They're already fixed
> in this repo; they stay listed here so the reasoning isn't lost. Items 15 and 16 need a fact
> that can only be checked on the server — both have read-only checks waiting in
> [07 Stage B](07-phase-0-1-execution.md).

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

## 10. Backups didn't record which K3s version made them — **fixed, waiting on deployment**

**How serious: Critical.**

A restore needs the *exact matching* K3s version. But nothing in our backup recorded which version
produced it. We checked every file the script saves:

| File we already save | Does it say the K3s version? |
|----------------------|------------------------------|
| `node-config/uname.txt` | No — that's the Linux kernel version, not K3s |
| `node-config/dpkg-selections.txt` | No — K3s isn't installed as a system package, it's a plain program file |
| `image-manifest/` | No — those are our app images, not K3s itself |
| The database snapshot | No |

So the version only existed as **text written in a document**, kept accurate by someone
remembering to edit it. The moment we upgrade K3s, every older backup becomes a guess.

There was a second half to this too: the database is backed up 4× a day while everything else is
backed up once a day, across seven different folders with their own timestamps — and nothing said
which files actually belonged together as one restorable set.

**Fixed by** a new `run-manifests/manifest-<timestamp>.json` written on every run, recording the
K3s version, the OS version, and the fingerprint of every file in that run.
[Restore step 0](03-restore-runbook.md#step-0--open-the-run-manifest-first) now starts by reading it.

**Not fully closed until** the updated script is actually deployed to `k3-master` and we've
confirmed a manifest showing up in S3 — see [#17](../../issues/17).

---

## 11. The restore runbook assumed tools we haven't built yet

**How serious: High.**

Steps 8 and 9 of the [restore runbook](03-restore-runbook.md) told you to restore app data with
Velero and import ArgoCD's settings — **neither of which exists yet**. Step 11 then asked you to
confirm Prometheus history was present, when nothing backs that history up in the first place.

**Why it mattered:** someone following the runbook during a genuine outage would get to step 8,
find nothing to restore from, and be stuck with a half-rebuilt server and no stated way forward.

**Fixed by** adding a plain "what this runbook can actually do today" table at the top, marking
steps 8 and 9 as blocked, and adding a "can this pass today?" column to the checking tables. This
didn't change *what we're building* — it stopped the document quietly implying we'd already built
it.

**Delete those warnings when** [#11](../../issues/11) is done. Tracked as [#18](../../issues/18).

---

## 12. Nobody wrote down how K3s certificates expire

**How serious: High.**

K3s's everyday certificates last about **a year**; the master certificate that issues them lasts
about **ten years**. When K3s starts up and finds the short-lived ones expired, it quietly reissues
them from the master certificate. So restoring a backup that's roughly a year old throws alarming
certificate errors that **fix themselves**.

**Why it mattered:** [step 6](03-restore-runbook.md#step-6--start-k3s-and-check-that-the-server-itself-is-healthy)
said "if you see certificate errors, stop here." That's right for a genuine identity problem — but
it would also halt a restore that was about to recover on its own, and tempt someone into
regenerating certificates, which **throws away the cluster identity they just restored**.

**Fixed by** a "normal kind vs. real problem" table in step 6, plus a hard warning never to
regenerate the master certificate.

**Still to check:** the actual expiry dates on `k3-master`. Stage B.1 of
[07](07-phase-0-1-execution.md) now captures them, but nobody has run it yet. Tracked as
[#19](../../issues/19), connected to [#8](../../issues/8).

---

## 13. Do we actually need the ArgoCD settings export?

**This is an open decision, not a hole in our coverage.**

Two of our own documents currently disagree. [#1](../../issues/1) and
[02](02-backup-strategy.md) say a daily ArgoCD export is required, because Git doesn't hold
ArgoCD's own settings. A later proposal argued it's unnecessary work, because Velero already backs
up the whole ArgoCD section of the cluster.

Both arguments are reasonable. They can't both be right about what we build.

**Deliberately left undecided.** It should be settled *after* [#11](../../issues/11) exists (so we
can actually test whether Velero really captures everything, rather than assuming) and after the
Phase 3 audit tells us whether anyone created ArgoCD apps by hand instead of through Git. Tracked
as [#20](../../issues/20).

---

## 14. The backup login couldn't upload our database file — **fixed**

**How serious: Critical.** It would have failed the very first real backup.

The login we create for the server was deliberately given no `kms:Decrypt` permission, on the
reasoning that a backup only ever *writes*, so it should never be able to decrypt anything.

That reasoning is appealing and wrong. Any file over 8 MB gets uploaded by `aws s3 cp` as a
**multi-part** upload, and multi-part uploads to an encrypted bucket need `kms:Decrypt` too. Our
database backup is about 64 MB — so **every single database upload would have failed** with
`AccessDenied`.

**What made it worse:** the connection test in Stage D uploaded a 50-byte text file. That's a
single-part upload, so it would have **passed** — handing over a green light, with the real
failure appearing later during the first genuine backup, disguised as an S3 permissions problem.

**Fixed by** adding `kms:Decrypt` (scoped to just our one encryption key), and changing the Stage D
test to upload a 64 MB file so it exercises the same path the real backup uses. The protections
that actually matter — no delete permission, one key only, versioning on — are untouched. Tracked
as [#21](../../issues/21).

---

## 15. Our "backup succeeded" signal may go nowhere

**How serious: High.**

The backup script reports success by writing a metric file into
`/var/lib/node_exporter/textfile_collector` on the server. If that folder doesn't exist, the script
quietly skips it and carries on.

**Why it matters:** discovery never confirmed node-exporter is installed at all — it isn't in the
monitoring list in [01](01-discovery-baseline.md). If it runs inside the cluster without that
server folder mounted, the metric is written nowhere and read by nobody, and the alerting we're
planning in [#2](../../issues/2) would be built on a hook that does nothing. **A backup that
silently stopped running would stay silent** — exactly what the alerting exists to prevent.

**How to close this out:** [07 Stage B.1b](07-phase-0-1-execution.md) now has a read-only check to
find out what node-exporter actually is here. Worth considering either way: alerting on **how old
the newest file in S3 is** would prove the backup actually *arrived*, rather than trusting the
script's own opinion of itself. Tracked as [#22](../../issues/22).

---

## 16. Is K3s encrypting Secrets inside its own database?

**How serious: Medium — this is about knowing, not about coverage.**

K3s can optionally encrypt Kubernetes Secrets inside its own database. If that's switched on,
there's a key file (`cred/encryption-config.json`) without which **every Secret in a restored
database is unreadable**.

**Either answer is fine.** We back up the whole `cred/` folder regardless, so the file is already
covered. What changes is how loudly we flag it, and whether a restore needs to explicitly confirm
that file landed before starting K3s.

**How to close this out:** [07 Stage B.1a](07-phase-0-1-execution.md) now checks this, read-only,
and the answer gets recorded in [01](01-discovery-baseline.md).

---

## Adding a new gap

Whenever we find something new we don't know:

1. Add a row to the table at the top of this document
2. Add a section below explaining **why it matters** and **how we plan to find out** — not just
   what's missing
3. Open a GitHub Issue for it and link that issue in the table
