# 07 — Setup, stage by stage

This file is the **executable source of truth**. Run it top to bottom. Other docs
([01](01-discovery-baseline.md)–[06](06-developer-access.md), [ISSUES-TRACKER](ISSUES-TRACKER.md))
are **further reading**, not prerequisites.

**Target server:** `k3-master` (`45.90.98.51`) — live production, **zero tolerance for downtime**.

**This deployment — copy these values. Do not substitute examples from older drafts.**

| | |
|---|---|
| Bucket | `k3-master-dr-sep-07` |
| Region | `us-east-1` |
| Kubernetes node | `ip-172-31-28-133` (`Ready`, `control-plane`) |
| Clone on the node | `~/poc-k3-backup` |
| Velero credentials (temporary on node) | `~/poc-k3-backup/scripts/velero-credentials` → Kubernetes Secret → shred. Never a laptop file. |
| Installer on this node | `~/poc-k3-backup/scripts/install-velero.sh` |
| Installer in this GitHub repo | `scripts/velero/install-velero.sh` |

### Five golden rules

1. **`[local]` vs `[node]`.** Laptop snippets stay on the laptop. Node snippets stay on SSH.
2. **Never `sudo -E`.** This node's sudo rejects it. Pass vars with `sudo env KEY=value …` or run
   Velero as `sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero …`.
3. **Job 1 key ≠ Velero key.** `backup.env` is Job 1 only. Velero uses a node temp file, then a
   Secret, then that file is shredded.
4. **Stay in `~/poc-k3-backup`.** Do not `cd scripts/`.
5. **New shell:** `export` dies. Re-copy the command from the step — install commands embed the
   four values, so you do not need a mega “4.2.0” block.
6. **No angle-bracket names.** Backup names are printed first (`echo "VERIFY_BACKUP=$VERIFY_BACKUP"`).
   Later commands use `"$VERIFY_BACKUP"`. If the shell died, copy the NAME column from
   `velero backup get`. Heartbeat URLs come from 5.1, not from Velero.

Standard step format below: **Goal → Run → Expected → If fail.** Optional *Why* is after the
command, or in [Design notes](#design-notes-and-troubleshooting) at the bottom.

Five stages, in order:

| Stage | What it does | Steps | Where | Downtime risk |
|-------|--------------|-------|-------|---------------|
| [1](#stage-1--validate-the-server) | Validate the server | 1.1–1.7 | `[node]` | **None** — read-only |
| [2](#stage-2--create-the-bucket-and-two-scoped-workload-credentials) | Bucket + two IAM keys | 2.1–2.7 | `[local]` | **None** |
| [3](#stage-3--deploy-job-1) | Job 1: K3s backup + timer | 3.1–3.8 | `[node]` | **Very low** |
| [4](#stage-4--deploy-job-2-velero) | Job 2: Velero + prove volumes | 4.1–4.5 **now**; 4.6 deferred | `[node]` | Low |
| [5](#stage-5--monitoring-and-the-restore-test) | Alerts, then restore test | 5.1–5.7 **starts right after 4.5** | both | **None** |

**Required now vs deferred**

| When | Steps |
|------|--------|
| **Required now** | 1.1 → 4.5, then Stage 5 |
| **Deferred verification** | [4.6](#46--post-deployment-check--do-after-8-days) — calendar reminder 8 days out. Do **not** wait here before Stage 5. |

**Every step is tagged with where you run it.**

- **`[local]`** — your laptop, AWS admin login. Windows: Git Bash or WSL.
- **`[node]`** — SSH on `k3-master` (`ssh <user>@45.90.98.51`), user can `sudo`.
- **`[decision]`** — write something down; no command.

If a snippet is tagged `[local]` do **not** paste it into the server session, and vice versa.

### Every step

| Step | What you do | When | Where |
|------|-------------|------|-------|
| [1.1](#11--run-the-preflight-checker-node) | Preflight `--no-aws` | now | `[node]` |
| [1.2](#12--confirm-the-baseline-still-holds-node) | Hostname, **capture live K3s version**, disk, datastore | now | `[node]` |
| [1.3](#13--look-inside-tls-and-cred-node) | List `tls/` `cred/`; record cert expiry | now | `[node]` |
| [1.4](#14--is-secrets-encryption-on-node) | `k3s secrets-encrypt status` | now | `[node]` |
| [1.5](#15--where-do-the-https-certificates-come-from-node) | Where Traefik HTTPS certs live | now | `[node]` |
| [1.6](#16--confirm-a-safe-sqlite-backup-is-possible-node) | Python `sqlite3` module | now | `[node]` |
| [1.7](#17--agree-an-rpo-and-an-rto-decision) | Agree RPO/RTO or record the assumption | now | decision |
| [2.1](#21--region-is-us-east-1) | Confirm region `us-east-1` | now | `[local]` |
| [2.2](#22--create-the-bucket) | Create the bucket | now | `[local]` |
| [2.3](#23--lock-it-down-before-anything-is-uploaded) | Block public access, versioning, SSE-S3, HTTPS-only | now | `[local]` |
| [2.4](#24--retention-rules) | Six lifecycle rules | now | `[local]` |
| [2.5](#25--create-separate-job-1-and-velero-credentials) | Job 1 + Velero IAM keys | now | `[local]` |
| [2.6](#26--check-all-of-stage-2-at-once) | Verify bucket and IAM | now | `[local]` |
| [2.7](#27--write-down-who-can-restore-local) | Two people who can restore | now | writing |
| [3.1](#31--write-the-config-node) | `/etc/k3s-backup/backup.env` | now | `[node]` |
| [3.2](#32--install-the-script-and-units-node) | Script + units | now | `[node]` |
| [3.3](#33--re-run-the-preflight-this-time-with-aws-node) | Preflight with AWS | now | `[node]` |
| [3.4](#34--write-down-the-current-state-so-you-can-prove-nothing-changed-node) | Record `NRestarts` | now | `[node]` |
| [3.5](#35--dry-run-build-the-archive-upload-nothing-node) | `DRY_RUN=1` | now | `[node]` |
| [3.6](#36--first-real-run-node) | First real upload | now | `[node]` |
| [3.7](#37--verify-the-archive-off-the-server-local) | Download + checksum | now | `[local]` |
| [3.8](#38--turn-the-schedule-on-node) | Enable timer | now | `[node]` |
| [4.1](#41--find-the-kubelet-root) | Confirm `/var/lib/kubelet` | now | `[node]` |
| [4.2](#42--install-velero) | Four values → CLI → creds → installer → verify | now | `[node]` |
| [4.3](#43--prove-the-node-agent-actually-reads-the-volumes) | Record **actual** PodVolumeBackup count | now | `[node]` |
| [4.4](#44--confirm-object-coverage-including-argocd) | Cluster objects + `argocd` | now | `[node]` |
| [4.5](#45--test-kubernetes-object-restore-only--pvc-restore-not-tested-yet) | ConfigMap restore only | now | `[node]` |
| [4.6](#46--post-deployment-check--do-after-8-days) | Confirm Velero TTL expiry | **deferred 8 days** | `[node]` |
| [5.1](#51--choose-the-two-dead-man-checks-local) | Two dead-man checks | now (after 4.5) | `[local]` |
| [5.2](#52--wire-job-1s-heartbeat-node) | Job 1 heartbeat | now | `[node]` |
| [5.3](#53--install-the-velero-verifier-and-its-heartbeat-node) | Verifier + `MIN_EXPECTED_PVBS` from 4.3 | now | `[node]` |
| [5.4](#54--alert-on-root-disk-space-node) | Disk alert | now | `[node]` |
| [5.5](#55--break-every-alert-on-purpose) | Break alerts on purpose | now | both |
| [5.6](#56--watch-the-first-few-runs-node) | Watch a few runs | now | `[node]` |
| [5.7](#57--prove-a-restore-works) | Restore test (includes PVC) | now | `[local]` |

**Ground rules.** Stages 1–3 do not restart K3s. If you are about to type `systemctl restart k3s`,
stop. Keep a second SSH session open.

**Record the session:**

```bash
# [node] — first thing after SSH, before 1.1
script -q ~/k3s-setup-$(date +%F-%H%M).log
# ...run every step...
exit
```

Do the same on `[local]` for the AWS stage if you want those captured too. Read a transcript back
with `cat ~/k3s-setup-*.log`, and send that file if you want someone to review what happened. The
per-command `tee` in step 1.1 is still fine on its own — with `script` running, it simply means the
preflight also gets its own separate log.

The safety claim that matters, stated plainly so you can verify it yourself: **the datastore
backup uses SQLite's built-in online backup API through a read-only connection, and because SQLite
is in WAL mode this never blocks anything else writing to the database.** A plain file copy would
have been the dangerous option — that's exactly why the script doesn't do one.

These shell variables are used throughout the `[local]` steps. Set them **on your laptop**, in the
terminal you'll run the AWS commands from. They are just shell variables — no file is created, and
they vanish when you close the terminal, so re-export them if you open a new one.

First, confirm the AWS CLI is installed and logged in `[local]`:

```bash
aws --version                    # v2.x
aws sts get-caller-identity      # shows your account — if this errors, log in first
```

If you juggle several AWS accounts, create and select a dedicated profile so you don't act on the
wrong one:

```bash
aws configure --profile k3-backup-admin     # one-time, enter the admin key/secret/region
export AWS_PROFILE=k3-backup-admin
```

Then set the variables every later `[local]` step relies on:

```bash
export AWS_PROFILE=k3-backup-admin        # the profile you just selected
export REGION=us-east-1                    # this deployment (N. Virginia). See stage 2.1
export BUCKET=k3-master-dr-sep-07          # live bucket; k3-master-dr was taken
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "$REGION / $BUCKET / $ACCOUNT_ID"
```

For the full picture of which credential and file belongs on which machine, read
[Where each credential and config lives](#where-each-credential-and-config-lives) before Stage 2.

---

## Stage 1 — Validate the server

### 1.1 — Run the preflight checker `[node]`

**Do this before anything else.** Changes nothing, answers "is everything actually in place?" in
about 30 seconds.

**First, get the script onto the server.** Pick whichever matches how you have the repo:

```bash
# If you cloned this repo onto k3-master already, it's the file in the clone:
#   ~/poc-k3-backup/k3s-backup-preflight.sh   (adjust to your clone path)

# If the repo is only on your laptop, copy it over from [local]:
scp scripts/k3s-backup-preflight.sh <user>@45.90.98.51:/tmp/
```

**Then install it** to `/usr/local/sbin/` as root. Use the path where the file actually is — the
repo clone, or `/tmp` if you scp'd it. Spelling out the full destination filename avoids any doubt
about where it lands:

```bash
sudo install -m 0750 -o root -g root \
  ~/poc-k3-backup/k3s-backup-preflight.sh \
  /usr/local/sbin/k3s-backup-preflight.sh
```

**Then run it.** Use `--no-aws` this first time — the bucket doesn't exist yet, and this tells you
what's missing locally so you aren't creating AWS resources only to find the server can't use them.
This one command both shows the output on screen **and** saves a log you can re-read or hand over.
`set -o pipefail` makes the checker's real exit code survive the pipe instead of being replaced by
`tee`'s:

```bash
set -o pipefail
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws 2>&1 \
  | tee ~/k3s-preflight-$(date +%F-%H%M).log
echo "Exit code: ${PIPESTATUS[0]}"
```

`2>&1` folds warnings and errors into the same log so nothing is lost, and the `Exit code:` line is
the number the table below reads — not `tee`'s. Read the saved log back with `cat
~/k3s-preflight-*.log`, and send that file if you want someone else to check it. (If you just want a
quick look with no log, `sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws` on its own works
too.)

| Exit | Meaning |
|------|---------|
| `0` — READY | Everything checks out |
| `2` — READY, with warnings | Safe to proceed, but read them — some mean a future failure would go unnoticed |
| `1` — NOT READY | Blocking problems. Every failure prints the exact command to fix it |

### 1.2 — Confirm the baseline still holds `[node]`

**Goal:** host is healthy; capture the **live** K3s version (do not expect a historical string).

**Run:**

```bash
hostnamectl | head -3
CURRENT_K3S_VERSION=$(k3s --version | awk '{print $3; exit}')
echo "CURRENT_K3S_VERSION=$CURRENT_K3S_VERSION"
systemctl is-active k3s && systemctl is-enabled k3s
df -h / && df -i /
sudo ls -la /var/lib/rancher/k3s/server/db/
sudo k3s etcd-snapshot ls 2>&1 | head -2
```

**Expected:** hostname prints; `CURRENT_K3S_VERSION` is non-empty (example at discovery was
`v1.34.5+k3s1` — **newer is fine**); k3s `active` and `enabled`; ≥5 GB free on `/`; `db/` has
`state.db`, `state.db-wal`, `state.db-shm`; `etcd-snapshot ls` still says datastore disabled.

**If fail:** STOP. Write `CURRENT_K3S_VERSION` down — 3.5/3.6 must match it in `MANIFEST.json`.

### 1.3 — Look inside `tls/` and `cred/` `[node]`

> 🔒 **List names and permissions only. Never open or read these files** — their contents are the
> cluster's private keys.

```bash
sudo find /var/lib/rancher/k3s/server/tls  -printf '%M %u:%g %10s %p\n' | sort -k4
sudo find /var/lib/rancher/k3s/server/cred -printf '%M %u:%g %10s %p\n' | sort -k4
sudo find /var/lib/rancher/k3s/server -maxdepth 1 -type f -printf '%M %10s %p\n'
```

**Check:** everything identity-related should be inside `tls/` or `cred/`. The backup takes both
folders whole, so if you spot a stray `.key`, `.crt` or `-ca.` file sitting *directly* under
`server/`, record it in [05](05-gaps-and-open-questions.md) and add it to the script's path list.

While you're here, write down **when the certificates expire**. This reads expiry dates only, and
recurses so certificates in subdirectories (for example `tls/etcd/`) aren't missed:

```bash
sudo find /var/lib/rancher/k3s/server/tls -type f -name "*.crt" -print0 |
while IFS= read -r -d "" c; do
  printf "%-80s " "${c#/var/lib/rancher/k3s/server/tls/}"
  sudo openssl x509 -enddate -noout -in "$c" 2>/dev/null || echo "could not read"
done
```

**Check:** two clear groups, and the gap between them is the point.

| Certificate | Should expire |
|-------------|---------------|
| Anything ending `-ca.crt` (the master certificates) | roughly **10 years** out |
| Everything else | roughly **1 year** out |

Write both into [01](01-discovery-baseline.md). They matter during a restore: restoring a backup
older than the *everyday* certificate expiry makes K3s throw certificate errors on startup and then
**fix them itself** from the still-valid CA. Knowing the real dates is what lets someone tell that
apart from a genuinely broken identity — see
[03 step 6](03-restore-runbook.md#step-6--start-k3s-and-verify-the-control-plane).

> If any **master** certificate is within a year of expiring, stop and raise it. That's a problem
> with the live cluster, not with backups, and it will not fix itself.

### 1.4 — Is secrets-encryption on? `[node]`

If it is, `cred/encryption-config.json` becomes the file without which **every Secret in a restored
database is unreadable**.

```bash
sudo ls -la /var/lib/rancher/k3s/server/cred/
sudo k3s secrets-encrypt status 2>&1 | head -5
```

**Check:** either answer is fine — `cred/` is backed up whole regardless. If it's **Enabled**, note
it in [01](01-discovery-baseline.md) and make sure
[restore step 4](03-restore-runbook.md#step-4--restore-the-identity-and-the-datastore) is followed
to the letter.

### 1.5 — Where do the HTTPS certificates come from? `[node]`

This is the gap most likely to produce a restore that looks successful and isn't
([gap 4](05-gaps-and-open-questions.md#4-where-traefiks-https-certificates-come-from)).

```bash
sudo k3s kubectl get ingress,ingressroute -A
sudo k3s kubectl get secrets -A --field-selector type=kubernetes.io/tls
sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -i -B2 -A4 'acme\|certresolver\|entryPoint'
sudo k3s kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik \
  -o jsonpath='{.items[*].spec.volumes[*].name}{"\n"}'
```

**Check** — you're answering one question: *if there's an `acme.json`, where does it live?*

| What you see | What it means |
|--------------|---------------|
| TLS Secrets exist, no ACME config | ✅ Covered by Velero. Close the gap |
| ACME configured, storage is `emptyDir` | 🚨 **Backed up by nothing.** A restore returns a site with no valid certificate. Fix this before stage 4 — move it to a PVC, or document re-issuance as a restore step |
| ACME configured, storage is a PVC | ✅ Covered by Velero — confirm that volume is in the backup in stage 4 |
| No TLS setup here at all | Terminated upstream. Write down where |

### 1.6 — Confirm a safe SQLite backup is possible `[node]`

```bash
python3 -c "import sqlite3; print('ok, sqlite', sqlite3.sqlite_version)"
```

**Check:** a version number means **nothing needs installing**. Python's built-in `sqlite3` module
has the same online backup API as the CLI tool, which keeps this whole setup free of new software
on a production server.

### 1.7 — Agree an RPO and an RTO `[decision]`

The only step in this document with no command, and the one everything else is measured against.
Daily backups are the right answer *if* losing up to a day of cluster state is acceptable; without
the two numbers, "daily" is a default nobody examined
([gap 1](05-gaps-and-open-questions.md#1-rpo-and-rto-are-not-signed-off)).

Take the working assumptions to whoever owns the service and come back with either a signature or
different numbers:

| | Meaning | Working assumption |
|---|---|---|
| **RPO** | How much recent change we accept losing | 24 hours |
| **RTO** | How long a rebuild may take before it's a business problem | 2–4 hours |

[02 §1](02-backup-strategy.md#1-two-numbers-to-agree-on-first--still-open) lists exactly what
changes for each possible answer — an RPO under 6 h adds a third prefix and a second Velero
Schedule, an RTO under 1 h means a warm standby rather than backups. Cheap to revisit, expensive to
assume.

**Check:** write the agreed numbers and who signed them into
[02 §1](02-backup-strategy.md#1-two-numbers-to-agree-on-first--still-open) and
the *Agree an RPO and an RTO* entry in [ISSUES-TRACKER](ISSUES-TRACKER.md). "We accept the
assumption as written, <name>, <date>" is a
perfectly good answer — an unexamined default is not.

---

## Where each credential and config lives

Before creating anything in AWS, hold this map in your head. The single most common beginner mistake
here is putting a credential in the wrong place — the Velero key in `backup.env`, or a real key in
Git. There are **four** places things live, and each one holds different things.

```text
                         AWS ACCOUNT
                              |
              +---------------+----------------+
              |                                |
          S3 bucket                          IAM
     k3-master-dr-sep-07         +------------+------------+
                                 |                         |
                       k3-master-backup-writer     k3-master-velero
                          (Job 1 key)                 (Velero key)
                                 |                         |
                                 v                         v
                        /etc/k3s-backup/backup.env   Kubernetes Secret
                        on k3-master                 in the velero namespace
```

| Where | What lives there | Permanent? |
|-------|------------------|------------|
| **Laptop `[local]`** | AWS admin profile; temporary `/tmp/k3-dr-*.json` policy files only | **No** — delete `/tmp` JSON after Stage 2 |
| **AWS** | Bucket; IAM users `k3-master-backup-writer` and `k3-master-velero`; keys | Yes |
| **`k3-master` `[node]`** | `/etc/k3s-backup/backup.env` — **Job 1 key only**. Velero key is a **temporary** file at `~/poc-k3-backup/scripts/velero-credentials` during 4.2, then shredded | backup.env yes; velero-credentials **no** |
| **Kubernetes** | Velero AWS key as a Secret in `velero` (installer creates it) | Yes |
| **This Git repo** | Scripts, docs, units, YAML — **never a real key** | Yes |

Two rules:

- **The Velero key never goes in `backup.env`.** On the node: temp file → installer → Kubernetes
  Secret → `shred`. No laptop copy.
- **No real key ever gets committed.** `.gitignore` already blocks `backup.env`, `velero-credentials`,
  `*.key`. Save access-key secrets in a password manager.

Temporary files (deleted after use):

```text
/tmp/k3-dr-bucket-policy.json     bucket HTTPS-only policy   (step 2.3)  [local]
/tmp/k3-dr-lifecycle.json         retention rules            (step 2.4)  [local]
/tmp/k3-dr-writer-policy.json     Job 1 IAM policy           (step 2.5)  [local]
/tmp/k3-dr-velero-policy.json     Velero IAM policy          (step 2.5)  [local]
~/poc-k3-backup/scripts/velero-credentials   Velero key      (step 4.2)  [node] then shred
```

---

## Stage 2 — Create the bucket and two scoped workload credentials

All `[local]`, with your admin login. **Nothing here touches `k3-master`.** If you have more than
one AWS account configured, confirm you are pointed at the right one before creating anything:

```bash
aws sts get-caller-identity      # is this the account that should own the DR bucket?
```

If it isn't, set `AWS_PROFILE` (see the variable block above) until this shows the correct account.

### 2.1 — Region is `us-east-1`

**Goal:** use the region this bucket already lives in. It cannot be changed later.

**Run:** none — already chosen.

**Expected:** `REGION=us-east-1` in the laptop exports above.

Region-selection theory (Mumbai / Frankfurt / cost) lives in
[02](02-backup-strategy.md). Do not re-pick here.

### 2.2 — Create the bucket

```bash
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi
```

> Written as an `if` on purpose: `us-east-1` is the one region that **rejects**
> `--create-bucket-configuration`, while every other region **requires** it.

> Bucket names are globally unique. `k3-master-dr` was taken, so this deployment uses
> `k3-master-dr-sep-07`. If you ever create another bucket, add a suffix and update `$BUCKET` —
> every later command reads that variable.

### 2.3 — Lock it down, before anything is uploaded

```bash
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":false}]}'
```

That's the encryption story in full: **SSE-S3**, on by default, nothing to rotate, nothing to lose,
no key whose deletion would make every backup unreadable. See
[02 §3](02-backup-strategy.md#3-where-it-all-goes) for why this replaced a customer-managed KMS key.

One bucket policy, and it only does one thing — refuse plain HTTP:

```bash
cat > /tmp/k3-dr-bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "DenyInsecureTransport",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "s3:*",
    "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
    "Condition": { "Bool": { "aws:SecureTransport": "false" } }
  }]
}
EOF

aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/k3-dr-bucket-policy.json
```

### 2.4 — Retention rules

Set these up **now**. Without them nothing is ever deleted, and versioning means overwrites pile up
too.

A lifecycle rule can only say *"delete N days after upload"*. That single limitation is the whole
reason Job 1 writes into two folders: `k3s/daily/` every day, and `k3s/weekly/` on Sundays as well.

```bash
cat > /tmp/k3-dr-lifecycle.json <<'EOF'
{
  "Rules": [
    { "ID": "k3s-daily-8d",  "Status": "Enabled",
      "Filter": { "Prefix": "k3s/daily/" },
      "Expiration": { "Days": 8 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 31 } },

    { "ID": "k3s-weekly-31d", "Status": "Enabled",
      "Filter": { "Prefix": "k3s/weekly/" },
      "Expiration": { "Days": 31 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 31 } },

    { "ID": "preflight-tests-2d", "Status": "Enabled",
      "Filter": { "Prefix": "_preflight/" },
      "Expiration": { "Days": 2 } },

    { "ID": "velero-noncurrent-35d", "Status": "Enabled",
      "Filter": { "Prefix": "velero/" },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 35 } },

    { "ID": "k3s-release-noncurrent-365d", "Status": "Enabled",
      "Filter": { "Prefix": "k3s-release/" },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 365 } },

    { "ID": "abort-stuck-uploads", "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 3 } }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" --lifecycle-configuration file:///tmp/k3-dr-lifecycle.json
rm -f /tmp/k3-dr-lifecycle.json
```

> ### 🚨 There is no **current-version expiry** for `velero/` or `k3s-release/`
>
> Velero's file-system backups live in a Kopia repository whose objects reference each other, and
> Velero expires them itself using each Schedule's `ttl`. An S3 expiry rule would delete chunks a
> still-valid backup depends on, and the corruption only shows up when you try to restore. If you
> want a safety net on that prefix, it must be a *noncurrent version* rule and never a
> current-version one. The rules above expire only noncurrent S3 versions; they never remove a
> current Kopia object.
>
> `k3s-release/` holds the K3s binaries a future restore needs. It must never expire.

### 2.5 — Create separate Job 1 and Velero credentials

```bash
aws iam create-user --user-name k3-master-backup-writer

cat > /tmp/k3-dr-writer-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ResolveBucketRegion",
      "Effect": "Allow",
      "Action": "s3:GetBucketLocation",
      "Resource": "arn:aws:s3:::$BUCKET"
    },
    {
      "Sid": "ListOnlyItsOwnPrefixes",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::$BUCKET",
      "Condition": {
        "StringLike": {
          "s3:prefix": ["k3s/*", "k3s-release/*", "_preflight/*"]
        }
      }
    },
    {
      "Sid": "WriteOnlyForK3sBackups",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": [
        "arn:aws:s3:::$BUCKET/k3s/*",
        "arn:aws:s3:::$BUCKET/k3s-release/*",
        "arn:aws:s3:::$BUCKET/_preflight/*"
      ]
    }
  ]
}
EOF

aws iam put-user-policy --user-name k3-master-backup-writer \
  --policy-name k3-master-dr-write --policy-document file:///tmp/k3-dr-writer-policy.json

aws iam create-access-key --user-name k3-master-backup-writer \
  --query 'AccessKey.{Id:AccessKeyId,Secret:SecretAccessKey}' --output table

aws iam create-user --user-name k3-master-velero

cat > /tmp/k3-dr-velero-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucketForVelero",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::$BUCKET"
    },
    {
      "Sid": "VeleroOwnsOnlyItsPrefix",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::$BUCKET/velero/*"
    }
  ]
}
EOF

aws iam put-user-policy --user-name k3-master-velero \
  --policy-name k3-master-dr-velero --policy-document file:///tmp/k3-dr-velero-policy.json

aws iam create-access-key --user-name k3-master-velero \
  --query 'AccessKey.{Id:AccessKeyId,Secret:SecretAccessKey}' --output table

rm -f /tmp/k3-dr-*.json
```

Read the *gaps* in that policy, because they're the design:

- **No `GetObject` on `k3s/*`.** The server writes backups and can never read one back. A
  compromised `k3-master` cannot download the cluster CA out of S3. The script confirms its own
  uploads by *listing* them and comparing sizes.
- **No `DeleteObject` on `k3s/*`.** Old backups expire via the lifecycle rules in 2.4, never via
  anything on the server.
- **The Job 1 key cannot access `velero/*`.** Compromising `backup.env` does not expose the readable
  Kopia repository.
- **Only the Velero key gets full control of `velero/*`.** Velero expires backups using `ttl` — TTL
  expiry *is* Velero issuing deletes. Remove it and nothing under `velero/` ever expires, TTL-based
  retention becomes fiction, and failed backups leave partial data behind.
  **Do not "harden" this away.**
- **Listing is scoped for Job 1 and bucket-wide for Velero.** Job 1 always lists a known prefix, so
  its `s3:ListBucket` carries an `s3:prefix` condition. Velero and Kopia list keys under their own
  prefix using patterns that are not a documented contract, so the same condition there risks
  breaking backup or expiry after a Velero upgrade — for a credential that can already read every
  byte under `velero/`. What the Velero key therefore *can* do is enumerate key names elsewhere in
  the bucket. It still cannot read, write or delete a single object outside `velero/`. If key-name
  enumeration matters to you, put Velero's data in its own bucket rather than adding an untested
  prefix condition.

Save both access-key pairs now — each secret is shown once. The Job 1 pair goes into
`/etc/k3s-backup/backup.env`; the Velero pair is used only to create the Kubernetes Secret in stage
4. **Never commit either pair to this repo.**

> **There is deliberately no second, restore-only credential.** Restores use your normal AWS admin
> or SSO login. The previous design kept a permanent reader key in a vault on a 90-day rotation,
> which was an ongoing chore protecting against nothing this one doesn't.
>
> What that *does* require: **at least two named people with AWS access**, and the bucket name and
> region written down somewhere outside AWS. Do that now, not later —
> [gap 5](05-gaps-and-open-questions.md#5-who-can-actually-perform-a-restore).

### 2.6 — Check all of stage 2 at once

```bash
aws s3api get-public-access-block --bucket "$BUCKET"
aws s3api get-bucket-versioning  --bucket "$BUCKET"
aws s3api get-bucket-encryption  --bucket "$BUCKET"
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[].{ID:ID,Prefix:Filter.Prefix,Days:Expiration.Days}' --output table
aws iam list-user-policies --user-name k3-master-backup-writer
aws iam list-user-policies --user-name k3-master-velero
```

Expect: four `true`s, versioning `Enabled`, encryption `AES256`, six lifecycle rules, no
current-version expiry on `velero/` or `k3s-release/`, and one inline policy on each user.

**This is the only place bucket settings get verified.** The on-node preflight deliberately doesn't
check them — that credential can't read bucket configuration, and it shouldn't be able to.

Once the checks above pass, delete the leftover policy helper files — they've done their job and hold
nothing you need again (the real policies now live in AWS):

```bash
rm -f /tmp/k3-dr-bucket-policy.json /tmp/k3-dr-writer-policy.json /tmp/k3-dr-velero-policy.json
```

### 2.7 — Write down who can restore `[local]`

Five minutes of writing, and it's what makes the "no stored restore key" decision safe rather than
fragile ([gap 5](05-gaps-and-open-questions.md#5-who-can-actually-perform-a-restore)). A restore
uses a human AWS login, so the restore path fails if that login is one person on holiday.

```bash
# who can actually reach the bucket today
aws iam list-users --query 'Users[].UserName' --output table
aws sts get-caller-identity
```

Record all four of these under *Who can actually perform a restore* in
[ISSUES-TRACKER](ISSUES-TRACKER.md) — the answers, not just the question:

1. **At least two named people** who can log into AWS and read `s3://k3-master-dr-sep-07`. One is not a
   plan; it's a single point of failure with a name.
2. **The bucket name and region, somewhere that survives losing access to this AWS account.** This
   repo counts and already states both — confirm that's still true rather than assuming it.
3. **Who owns and rotates the two workload keys** (Job 1 and Velero), and how often. These are
   long-lived keys by deliberate choice; an unowned long-lived key is the part that ages badly.
4. **Where the recovery kit lives** — this repo, cloned somewhere that is not `k3-master`. The
   restore runbook needs `scripts/velero/` before the cluster it describes exists again.

**Check:** someone other than you can answer "how would you start a restore tomorrow?" by reading
what you just wrote, without asking you anything.

---

## Stage 3 — Deploy Job 1

From here on you are on the server. `ssh <user>@45.90.98.51` and stay there through the end of
Stage 3.

### 3.1 — Write the config `[node]`

This is the one place the **Job 1** access key from 2.5 gets stored. Use the
`k3-master-backup-writer` pair — **not** the Velero pair, which never touches this file (it goes
into the cluster in 4.2).

```bash
sudo install -d -m 0700 -o root -g root /etc/k3s-backup
sudo install -m 0600 -o root -g root /dev/null /etc/k3s-backup/backup.env
sudo nano /etc/k3s-backup/backup.env
```

```ini
S3_BUCKET=k3-master-dr-sep-07
AWS_REGION=us-east-1
AWS_ACCESS_KEY_ID=<k3-master-backup-writer key from 2.5>
AWS_SECRET_ACCESS_KEY=<k3-master-backup-writer secret from 2.5>
# Job 1's external dead-man signal. Velero uses a separate URL. See 02 §7.
HEARTBEAT_URL=
```

**Check:**

```bash
sudo stat -c '%a %U:%G %n' /etc/k3s-backup /etc/k3s-backup/backup.env
```

`700 root:root` and `600 root:root`. Anything readable by other users here is a problem to fix
immediately — this file holds write access to the bucket containing the cluster CA.

> `HEARTBEAT_URL` can stay empty for now; the script warns on every run until it's set. Filling it
> in is [gap 2](05-gaps-and-open-questions.md#2-the-external-heartbeats-have-nowhere-to-report-yet) and
> takes about five minutes once the channel is decided.

### 3.2 — Install the script and units `[node]`

From `[local]`, inside your clone of this repo:

```bash
scp scripts/k3s-server-backup.sh <user>@45.90.98.51:/tmp/
scp scripts/systemd/k3s-backup.service scripts/systemd/k3s-backup.timer <user>@45.90.98.51:/tmp/
```

Then on `[node]`:

```bash
sudo install -m 0750 -o root -g root /tmp/k3s-server-backup.sh /usr/local/sbin/k3s-server-backup.sh
sudo install -m 0644 -o root -g root /tmp/k3s-backup.service /tmp/k3s-backup.timer /etc/systemd/system/
sudo install -d -m 0700 -o root -g root /var/backups/k3s
sudo systemctl daemon-reload
sudo bash -n /usr/local/sbin/k3s-server-backup.sh && echo "syntax OK"
```

> `sudo` is required for the syntax check: the script is installed `0750 root:root`, so a normal user
> can't read it. The same applies to inspecting `/var/backups/k3s` later — it's `0700 root:root`, so
> every `ls`/`tar`/`cat` under it needs `sudo` too.

> Copy it **from the repo**, don't paste it into an editor on the server. The repo is the one true
> copy.

### 3.3 — Re-run the preflight, this time with AWS `[node]`

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh
```

**Check:** exit `0` or `2`. Section C should now show uploads working, listing working, and — this
is the part worth reading — **reading back and deleting correctly refused**. If either of those
guardrails reports the credential *can* read or delete, go back to 2.5.

### 3.4 — Write down the current state, so you can prove nothing changed `[node]`

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
```

Save that output. Steps 3.5 and 3.6 compare against it.

### 3.5 — Dry run: build the archive, upload nothing `[node]`

```bash
sudo DRY_RUN=1 /usr/local/sbin/k3s-server-backup.sh
sudo ls -lah /var/backups/k3s/                    # the dated run directory the script just created
sudo sh -c 'ls -lah /var/backups/k3s/*/'          # the files inside it
```

> **Why `sudo sh -c '...'` for the wildcard.** `/var/backups/k3s` is `0700 root:root`. In
> `sudo ls /var/backups/k3s/*/` your **own** shell expands `*` *before* `sudo` runs, and since your
> user can't read the directory the glob matches nothing and the command fails. Wrapping it in
> `sudo sh -c '...'` makes **root's** shell do the expansion. The plain `sudo ls -lah
> /var/backups/k3s/` works without the wrapper because it has no wildcard.

**Expected:** `snapshot ok (read-only), integrity_check=ok`, then `manifest: k3s=<CURRENT_K3S_VERSION from 1.2>`.
Archive ~20 MB. Staging folder has `.tar.gz`, `.sha256`, `MANIFEST.json`, `COMPLETE.json`.

Look inside without extracting anything:

```bash
sudo sh -c 'tar -tzf /var/backups/k3s/*/k3s-*.tar.gz' | head -30
sudo sh -c 'python3 -m json.tool /var/backups/k3s/*/MANIFEST.json'
```

> Same wildcard rule as above — the `/var/backups/k3s/*/` path is expanded by root inside
> `sudo sh -c '...'`. `head` stays outside the quotes; it needs no privilege.

**Validate the archive actually contains a complete restore set.** The listing above is truncated to
30 lines, so eyeballing it can miss a gap. This confirms every part a restore depends on is really
inside the archive — the datastore, all four halves of the cluster identity, the config and the
systemd unit — and prints `MISSING` for anything absent:

```bash
sudo sh -c '
  A=$(ls /var/backups/k3s/*/k3s-*.tar.gz)
  L=$(tar -tzf "$A")
  for p in \
    MANIFEST.json \
    state.db \
    fs-root/var/lib/rancher/k3s/server/token \
    fs-root/var/lib/rancher/k3s/server/tls/ \
    fs-root/var/lib/rancher/k3s/server/cred/ \
    fs-root/var/lib/rancher/k3s/server/manifests/ \
    fs-root/etc/rancher/k3s/ \
    fs-root/etc/systemd/system/k3s.service \
    host-facts/README.txt ; do
    printf "%s\n" "$L" | grep -q "^\./$p" && echo "present : $p" || echo "MISSING : $p"
  done
'
```

**Check:** every line reads `present`. A single `MISSING` — especially `state.db`, `token`, `tls/`
or `cred/` — means the archive can't rebuild the cluster on its own; stop and fix the script before
trusting the backup. (`token`, `tls/`, `cred/` and `state.db` are four halves of the same identity;
restoring only some of them produces a cluster that won't trust its own data.)

**Check the manifest**, because it's the file a restore reads first:

- `k3s_version` **equals** `CURRENT_K3S_VERSION` from 1.2 (whatever is installed now). If it says
  `unknown`, STOP — the script could not read `/usr/local/bin/k3s`.
- `k3s_start_command` contains the real start flags, including any `--tls-san`.
- `archive.sha256` and `archive.bytes` are filled in.

Now confirm K3s is exactly where you left it:

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
```

`ActiveEnterTimestamp` and `NRestarts` **must match 3.4 exactly.** That's the proof this caused
zero downtime.

```bash
sudo sh -c 'rm -rf /var/backups/k3s/*/'   # wildcard, so run it inside sudo sh -c (see 3.5)
```

### 3.6 — First real run `[node]`

```bash
sudo /usr/local/sbin/k3s-server-backup.sh
```

The script verifies its own uploads and will fail loudly if an object didn't land at the right
size, so a clean exit is already meaningful. Confirm independently anyway:

```bash
# backup.env is 0600 root:root, so both source it AND run aws inside one root shell.
# Prefix-scoped: the Job 1 key cannot list the bucket root.
sudo bash -c '
  set -a; . /etc/k3s-backup/backup.env; set +a
  AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s/"         --recursive --human-readable
  AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s-release/" --recursive --human-readable
'
```

> **Load the env inside the root shell, not before `sudo`.** `/etc/k3s-backup/backup.env` is
> `0600 root:root`, so `. /etc/k3s-backup/backup.env` as your normal user gives `Permission denied`
> and leaves `$AWS_REGION`/`$S3_BUCKET` empty — the AWS CLI then builds a malformed
> `https://s3..amazonaws.com` endpoint. Sourcing it inside `sudo bash -c '...'` reads the file as
> root, so no `sudo -E` is needed.

```text
k3s/daily/<run-id>/COMPLETE.json
k3s/daily/<run-id>/MANIFEST.json
k3s/daily/<run-id>/k3s-<run-id>.tar.gz
k3s/daily/<run-id>/k3s-<run-id>.tar.gz.sha256
k3s-release/<CURRENT_K3S_VERSION>/RESTORE.txt
k3s-release/<CURRENT_K3S_VERSION>/k3s
k3s-release/<CURRENT_K3S_VERSION>/k3s.sha256
```

**That folder is one complete restore set.** The `k3s-release/` upload happens once per version —
tomorrow's run won't repeat it.

If today is Sunday you'll also see the same four objects under `k3s/weekly/`. That's the retention
design, not a bug: two prefixes so two lifecycle rules can express 7 daily + 4 weekly.

You *won't* see `velero/` yet — that's stage 4, and until it exists no PVC data and no single
deleted object can be restored.

And once again, the thing that matters most:

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A | grep -v Running | head
```

Restart count unchanged, node still `Ready`, and only the four already-broken demo apps from
[01 §13](01-discovery-baseline.md#13-argocd-deploys-our-apps-automatically-from-git) — `demo-app`,
`nginx-app`, `nginx-app-dev`, `nginx-app11`. **Those were broken before you started. Ignore them.**

### 3.7 — Verify the archive off the server `[local]`

Downloading it proves the restore path works *and* that a normal admin login can reach it — which
is exactly what a real restore will use.

```bash
mkdir -p ~/k3-restore-check && cd ~/k3-restore-check
RUN_ID=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix k3s/daily/ \
  --query "Contents[?ends_with(Key, 'COMPLETE.json')].Key" --output text |
  tr '\t' '\n' | awk -F/ '{print $3}' | sort | tail -1)
[ -n "$RUN_ID" ] || { echo "no complete restore set found" >&2; exit 1; }
aws s3 cp "s3://$BUCKET/k3s/daily/$RUN_ID/" . --recursive
python3 - <<'PY'
import hashlib, json

def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

# COMPLETE.json (written last) vouches for MANIFEST.json, which vouches for the
# archive. Verifying that chain is the point; the sidecar .sha256 is a copy
# nothing else attests to.
marker = json.load(open("COMPLETE.json"))
actual = hashlib.sha256(open("MANIFEST.json", "rb").read()).hexdigest()
assert actual == marker["manifest_sha256"], f"manifest mismatch: {actual}"

archive = json.load(open("MANIFEST.json"))["archive"]
actual = digest(archive["filename"])
assert actual == archive["sha256"], f"archive mismatch: {actual}"
print(f"chain verified: COMPLETE.json -> MANIFEST.json -> {archive['filename']}")
print("k3s_version:", json.load(open("MANIFEST.json"))["k3s_version"])
PY
```

That `k3s_version` must equal `CURRENT_K3S_VERSION` from 1.2. This is the same chain
[restore step 1](03-restore-runbook.md#step-1--pick-a-backup-and-read-its-manifest) uses in an
outage.

```bash
tar -xzf k3s-*.tar.gz
ls -la fs-root/var/lib/rancher/k3s/server/ fs-root/etc/rancher/k3s/
cat host-facts/README.txt

# the datastore must be a valid, complete SQLite database
python3 - state.db <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
print("integrity_check:", db.execute("PRAGMA integrity_check").fetchone()[0])
print("kine rows:", db.execute("SELECT count(*) FROM kine").fetchone()[0])
PY
```

**Check:** `integrity_check: ok` and a real, non-zero row count — that count is the proof this is a
snapshot of the live cluster and not an empty shell. Under `fs-root/` you should find `tls/`, `cred/`,
`token`, `manifests/`, `/etc/rancher/k3s` and `k3s.service`; compare the `tls/` and `cred/` listings
against what you found in 1.3.

```bash
cd ~ && rm -rf ~/k3-restore-check
```

> **A restore-time gotcha, worth learning now:** `state.db` is one single complete file. It goes to
> `/var/lib/rancher/k3s/server/db/state.db` with **no `-wal` and no `-shm` beside it**, while K3s is
> stopped. Leaving a stale `-wal` from a fresh install next to a restored snapshot is how you
> silently load the wrong data.

### 3.8 — Turn the schedule on `[node]`

We use a systemd timer, matching how the server already schedules its one existing routine job.
**No cron** — this server has no scheduled root cron jobs and we're keeping it that way.

```bash
sudo systemd-analyze verify /etc/systemd/system/k3s-backup.service
sudo systemctl start k3s-backup.service        # same path the timer will take
sudo systemctl status k3s-backup.service --no-pager
sudo journalctl -u k3s-backup.service -n 40 --no-pager
```

**Expected:** `status=0/SUCCESS`, log ends `completed successfully`.

**If fail:** exact error `tar: … Cannot stat: Function not implemented` → [T3](#t3--systemd-tar-statx). Other errors: STOP and read the journal.

Only now:

```bash
sudo systemctl enable --now k3s-backup.timer
systemctl list-timers 'k3s-backup*' --all --no-pager
```

**Check:** next run at 02:15 UTC. Its 30-minute systemd timeout plus 10-minute random delay ends
before the 03:30 UTC Velero window. The script also takes a lock, so two Job 1 runs cannot overlap.

---

## Stage 4 — Deploy Job 2 (Velero)

Job 1 cannot restore a deleted PVC or Secret. Do **all of Stage 4 on the node**. After **4.5**, go
straight to Stage 5. **4.6 waits 8 days** — set a reminder; do not block.

### Velero for someone new to it

Velero is a program **inside the cluster** that snapshots Kubernetes objects and (with the
node-agent) PVC files. The `velero` command on the node is only a **client**. It must talk to the
K3s API the same way `kubectl` does.

**What `/etc/rancher/k3s/k3s.yaml` is.** It is the cluster admin kubeconfig. Do **not** `cat` it
into chat. It holds:

```text
/etc/rancher/k3s/k3s.yaml
       |
       +--> K3s API address
       +--> cluster CA certificate
       +--> client certificate
       +--> client private key
       +--> context / user
```

The line that matters for this node:

```text
server: https://127.0.0.1:6443
```

That means: this file points at the API **on this same machine**, port 6443.

```text
velero / kubectl
       |
       | HTTPS :6443  + certs from k3s.yaml
       v
K3s API server
```

`sudo k3s kubectl` already knows that path. Standalone tools (`velero`, `helm`, plain `kubectl`)
do **not**. So every Velero command in this stage passes it explicitly:

```text
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero …
```

`export KUBECONFIG=…` would do the same for **this shell only** — it dies when you disconnect. That
is why the commands below embed `KUBECONFIG=` instead of asking you to remember an export. Never
`sudo -E` (golden rule 2).

**What `velero backup get` means.** “List every Velero backup this cluster knows about, and its
status.” It is a directory, not a restore. One row = one backup. Example:

```text
NAME                   STATUS      ERRORS  WARNINGS  CREATED                         EXPIRES  STORAGE LOCATION
daily-20260916095129   Completed   0       24        2026-09-16 09:51:30 +0000 UTC   6d       default
probe-1789552392       Completed   0       0         2026-09-16 09:54:38 +0000 UTC   29d      default
verify-1789486389      Completed   0       9         2026-09-15 15:33:09 +0000 UTC   29d      default
```

| Column | Meaning |
|--------|---------|
| **NAME** | Backup id. You chose `verify-…` / `probe-…` in 4.3/4.5. `daily-…` comes from the schedule. |
| **STATUS** | `Completed` / `Failed` / `InProgress`. `Completed` is **not** proof volumes were copied — 4.3 checks that. |
| **ERRORS** | Hard failures. Non-zero → read `velero backup describe NAME --details`. |
| **WARNINGS** | Soft issues. Backup can still be `Completed` (your `daily-` row has 24). |
| **CREATED** | When Velero created it (UTC). |
| **EXPIRES** | TTL left. Daily ~7d; a one-off verify/probe ~29d. After this Velero deletes it. |
| **STORAGE LOCATION** | S3 target name. Ours is `default` → bucket `k3-master-dr-sep-07` prefix `velero/`. |
| **QUEUE POSITION** | Empty unless a backup is waiting in a queue. |
| **SELECTOR** | Label filter, if any. `<none>` = whole selected scope. |

To inspect **one** row (replace the name with a NAME from `get` — or `"$VERIFY_BACKUP"` if you set it):

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  velero backup describe "$VERIFY_BACKUP" --details
```

**What `velero backup-location get` means.** “Where do backups go in S3, and can Velero still write
there?” This is the **Backup Storage Location** (BSL). `velero backup get`’s STORAGE LOCATION
column (`default`) is this object’s NAME.

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup-location get
```

**Expected on this node (this is a pass):**

```text
NAME      PROVIDER   BUCKET/PREFIX                PHASE       LAST VALIDATED                  ACCESS MODE   DEFAULT
default   aws        k3-master-dr-sep-07/velero   Available   2026-09-16 11:17:20 +0000 UTC   ReadWrite     true
```

| Column | Meaning |
|--------|---------|
| **NAME** | Location id. Ours is `default`. |
| **PROVIDER** | `aws` — S3-compatible plugin. |
| **BUCKET/PREFIX** | `k3-master-dr-sep-07/velero` — Job 2 prefix only. Job 1 uses `k3s/` in the same bucket. |
| **PHASE** | Must be **`Available`**. Anything else → STOP (wrong bucket, region, or Velero key). |
| **LAST VALIDATED** | Last time Velero successfully talked to S3. |
| **ACCESS MODE** | `ReadWrite` = can create backups. Restore-time we may set `ReadOnly` so a half-restored cluster cannot overwrite S3. |
| **DEFAULT** | `true` = backups without a location go here. |

Same object via kubectl: `sudo k3s kubectl -n velero get backupstoragelocation`.

Conventions (golden rule 2):

```text
Velero:     sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero …
Kubernetes: sudo k3s kubectl …
Never:      sudo -E …
```

### 4.1 — Find the kubelet root

**Goal:** Velero must read `/var/lib/kubelet/pods`. Wrong path → empty backup that still says
`Completed`.

**Run:**

```bash
sudo test -r /etc/rancher/k3s/k3s.yaml && echo "OK: kubeconfig exists"
sudo grep -E '^\s+server:' /etc/rancher/k3s/k3s.yaml
sudo test -d /var/lib/kubelet/pods && echo "OK: /var/lib/kubelet/pods exists" || echo "NOT FOUND"
sudo ls -la /var/lib/kubelet/pods | head -3
```

**Expected:** `OK` lines, `server: https://127.0.0.1:6443`, `pods` lists directories.

**If fail:** STOP. Do not `cat` `k3s.yaml` into chat. If `NOT FOUND`:

```bash
sudo k3s kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/configz" | tr ',' '\n' | grep -i rootdir
```

Use that path in 4.2.4 instead of `/var/lib/kubelet`.

### 4.2 — Install Velero

**Goal:** CLI → creds file on the node → installer → schedules → shred creds → verify.

Stay in `~/poc-k3-backup`. Do not `cd scripts/`.

**4.2.1 — Confirm installer path**

**Run:**

```bash
cd ~/poc-k3-backup
ls -l /home/ubuntu/poc-k3-backup/scripts/install-velero.sh
```

**Expected:** installer listed (`-rwx…`).

**If fail:** this GitHub tree keeps the installer at `scripts/velero/install-velero.sh` — use that
path in 4.2.4 instead. STOP if neither file exists.

**4.2.2 — Install the Velero CLI v1.18.0** (once per node)

**Run:**

```bash
VELERO_VERSION=v1.18.0
curl -fsSL -o /tmp/velero.tgz \
  "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz"
tar -xzf /tmp/velero.tgz -C /tmp
sudo install -m 0755 "/tmp/velero-${VELERO_VERSION}-linux-amd64/velero" /usr/local/bin/velero
```

**Expected:** CLI on disk. Client check is in 4.2.4 (same kubeconfig the installer uses).

**4.2.3 — Create the Velero credentials file on the node** (once)

Use the **`k3-master-velero`** key from 2.5 — not Job 1. Skip `cat` if the file already exists
`-rw-------`.

**Run:**

```bash
cat > /home/ubuntu/poc-k3-backup/scripts/velero-credentials <<'EOF'
[default]
aws_access_key_id=PUT_K3-MASTER-VELERO_ACCESS_KEY_HERE
aws_secret_access_key=PUT_K3-MASTER-VELERO_SECRET_KEY_HERE
EOF
chmod 600 /home/ubuntu/poc-k3-backup/scripts/velero-credentials
ls -l /home/ubuntu/poc-k3-backup/scripts/velero-credentials
```

**Expected:** `-rw-------` `/home/ubuntu/poc-k3-backup/scripts/velero-credentials`. Do not `git add`.

**4.2.4 — Gate, then run the installer**

This does **not** restart K3s. It creates the `velero` namespace and resources, the AWS plugin, and
the node-agent. PVC data on `local-path` is backed up by that node-agent only.

**Run first (required):**

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  k3s kubectl get nodes
```

**Expected:**

```text
NAME                  STATUS   ROLES           AGE   VERSION
ip-172-31-28-133...   Ready    control-plane   ...   ...
```

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  velero version --client-only
```

**Expected:** `Version: v1.18.0`.

**If fail:** STOP. Do not run the installer.

**Then:**

```bash
sudo env \
  KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  S3_BUCKET=k3-master-dr-sep-07 \
  AWS_REGION=us-east-1 \
  CREDS_FILE=/home/ubuntu/poc-k3-backup/scripts/velero-credentials \
  KUBELET_ROOT_DIR=/var/lib/kubelet \
  /home/ubuntu/poc-k3-backup/scripts/install-velero.sh
```

If this GitHub clone has `scripts/velero/install-velero.sh` instead, use that path as the last
argument.

**Expected:** finishes without error. K3s is still running; no restart.

**If fail:** last error line. Wrong bucket/region/key is the usual cause.

**4.2.5 — Apply schedules, then shred the node credentials file**

**Run:**

```bash
ls -l /home/ubuntu/poc-k3-backup/scripts/schedule-daily.yaml \
      /home/ubuntu/poc-k3-backup/scripts/schedule-weekly.yaml
sudo k3s kubectl apply -f /home/ubuntu/poc-k3-backup/scripts/schedule-daily.yaml
sudo k3s kubectl apply -f /home/ubuntu/poc-k3-backup/scripts/schedule-weekly.yaml
shred -u /home/ubuntu/poc-k3-backup/scripts/velero-credentials
```

If `ls` fails, copy `scripts/velero/schedule-daily.yaml` and `schedule-weekly.yaml` from this GitHub
repo into `~/poc-k3-backup/scripts/` on the node, then re-apply. Or apply from
`~/poc-k3-backup/scripts/velero/` if that directory exists.

**Expected:** both schedules `created`; credentials file gone. Key now exists only as a Kubernetes
Secret.

**4.2.6 — Verify the install**

**Run:**

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero version
```

```bash
sudo k3s kubectl -n velero get pods -o wide
```

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup-location get
```

```bash
sudo k3s kubectl -n velero get schedules
```

**Expected:** server `v1.18.0`; pods `Running`; backup-location `default` / `k3-master-dr-sep-07/velero` / **PHASE `Available`** / `ReadWrite`; schedules `Enabled`. Column meanings:
[backup-location get](#velero-for-someone-new-to-it). Then 4.3.

**If fail:** PHASE not `Available` → bucket/region/key in 4.2.4.

### 4.3 — Prove the node-agent actually reads the volumes

**Goal:** a `Completed` backup with **copied volumes**. Record the **actual** PodVolumeBackup count
(do not assume 6).

**How the name works:** you **choose** it first. `date +%s` prints seconds (example
`verify-1789486389`). That printed string **is** the backup name. There is no `<name>` to type.
If this is a new shell, set `VERIFY_BACKUP=` to the NAME column from `velero backup get`.

**Run 1 — pick the name and print it:**

```bash
VERIFY_BACKUP=verify-$(date +%s)
echo "VERIFY_BACKUP=$VERIFY_BACKUP"
```

**Expected:** one line like `VERIFY_BACKUP=verify-1789486389`. Copy that value if the shell dies.

**Run 2 — create that backup:**

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  velero backup create "$VERIFY_BACKUP" --wait
```

**Expected:** phase `Completed`.

**Run 3 — list backups (confirm the NAME column matches `$VERIFY_BACKUP`):**

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
```

**Expected:** a table. Your `$VERIFY_BACKUP` row is `Completed`. Column meanings are in
[Velero for someone new to it](#velero-for-someone-new-to-it) above. `WARNINGS` can be non-zero
while `STATUS` is still `Completed`.

**Run 4 — describe that same name:**

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  velero backup describe "$VERIFY_BACKUP" --details \
  | sed -n '/Pod Volume Backups/,/^$/p'
```

**Run 5 — count volumes for that same name:**

```bash
sudo k3s kubectl -n velero get podvolumebackups \
  -l velero.io/backup-name="$VERIFY_BACKUP" --no-headers | wc -l
```

**Expected:** count ≥ 1. Write that integer down as `MIN_EXPECTED_PVBS` for 5.3.

**If fail:** count `0` → STOP. Node-agent hostPath ≠ kubelet root. Fix `KUBELET_ROOT_DIR` in 4.2.4
and re-install.

Unmounted PVCs produce no pod volume; a volume on two pods produces two. Use what the node-agent
copied, not the PVC list.

### 4.4 — Confirm object coverage, including ArgoCD

Uses the **same** `$VERIFY_BACKUP` from 4.3. If this is a new shell:

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
VERIFY_BACKUP=verify-PASTE-THE-NAME-COLUMN-HERE
echo "VERIFY_BACKUP=$VERIFY_BACKUP"
```

**Run:**

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  velero backup describe "$VERIFY_BACKUP" --details \
  | grep -E 'customresourcedefinitions|clusterroles|storageclasses'
```

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  velero backup describe "$VERIFY_BACKUP" --details \
  | grep -E 'argocd/'
```

**Expected:** CRDs, ClusterRoles, StorageClass, and `argocd/` objects. Then 4.5.

**If fail:** STOP; backup is not cluster-wide.

### 4.5 — Test Kubernetes object restore only — PVC restore not tested yet

**Goal:** prove Velero can restore a **ConfigMap**. This does **not** prove PVC/volume data. PVC
restore is Stage **5.7**. Do not delete a production PVC here.

Same name rule: pick `PROBE_BACKUP` first, print it, then reuse `"$PROBE_BACKUP"`. Never type
`<probe-backup>`.

**Run 1 — scratch namespace + ConfigMap:**

```bash
sudo k3s kubectl create namespace restore-probe
sudo k3s kubectl -n restore-probe create configmap probe --from-literal=k=v
```

**Run 2 — pick the probe backup name:**

```bash
PROBE_BACKUP=probe-$(date +%s)
echo "PROBE_BACKUP=$PROBE_BACKUP"
```

**Run 3 — back it up:**

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  velero backup create "$PROBE_BACKUP" --include-namespaces restore-probe --wait
```

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
```

**Run 4 — delete the namespace, then restore from that same name:**

```bash
sudo k3s kubectl delete namespace restore-probe
```

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  velero restore create --from-backup "$PROBE_BACKUP" \
  --include-namespaces restore-probe --wait
```

```bash
sudo k3s kubectl -n restore-probe get configmap probe -o jsonpath='{.data.k}{"\n"}'
```

```bash
sudo k3s kubectl delete namespace restore-probe
```

**Expected:** ConfigMap value `v`. **Pass → Stage 5 now.** Set a calendar reminder for 4.6 in 8 days.

**If fail:** STOP.

**If fail:** STOP.

### 4.6 — Post-deployment check — do after 8 days

**Do not wait here.** Stage 5 starts immediately after 4.5.

**Goal (day 8+):** Velero TTL actually deletes old backups.

**Run:**

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get -l velero.io/schedule-name=weekly
```

**Expected:** daily backups older than 168 h gone; Sunday ones remain to 720 h; list is not growing
forever.

**If fail:** re-read the Velero IAM policy in 2.5.

---

## Stage 5 — Monitoring and the restore test

Starts **immediately after 4.5**. Do not wait for 4.6.

| # | Alert | Threshold | Set up in |
|---|-------|-----------|-----------|
| 1 | No Job 1 backup arrived | 26 h | 5.1 + 5.2 |
| 2 | No verified Velero backup arrived | 30 h | 5.1 + 5.3 |
| 3 | A scheduled Backup or any of its PodVolumeBackups is bad | any failure, or fewer volumes than expected | 5.3 (suppresses alert 2's ping) |
| 4 | Root disk free space low | under 10% | 5.4 |

### 5.1 — Choose the two dead-man checks `[local]`

Alerts 1 and 2 must terminate **outside** this cluster. Prometheus and Alertmanager run inside the
cluster we're protecting, so they die with the thing they'd be reporting on
([gap 2](05-gaps-and-open-questions.md#2-the-external-heartbeats-have-nowhere-to-report-yet)).

Pick one channel and create **two separate checks** in it:

| Option | Effort | Notes |
|--------|--------|-------|
| Hosted dead-man's switch (healthchecks.io, Cronitor) | ~5 min | Free tier is enough. Two URLs, no infrastructure. **The default recommendation** |
| AWS-native: EventBridge on S3 `ObjectCreated` under `k3s/daily/` → CloudWatch alarm treating missing data as breaching | ~1 hour | No third party, more moving parts, and it watches the bucket rather than the job |
| An Alertmanager or push gateway hosted outside this cluster | varies | Only worth it if one already exists |

Configure the two checks as:

| Check | Period | Grace | Who pings it |
|-------|--------|-------|--------------|
| `k3-master job 1` | 24 h | 2 h → alerts at 26 h | `k3s-server-backup.sh`, after `COMPLETE.json` is verified in S3 |
| `k3-master velero` | 24 h | 6 h → alerts at 30 h | `check-last-backup.sh`, after a *new* backup passes every check |

**Two checks, not one.** A shared URL lets either job keep the light green while the other is
dead — which is the exact failure the alert exists to catch. Route both to somewhere a human
actually reads, and record which channel and who receives it under *Alerting, and where the
heartbeat reports to* in [ISSUES-TRACKER](ISSUES-TRACKER.md).

After you create the two checks, **write the two ping URLs down**. They are used in 5.2 and 5.3.
They are not backup names.

### 5.2 — Wire Job 1's heartbeat `[node]`

Paste the Job 1 ping URL from 5.1 — do not leave the angle brackets.

```bash
JOB1_HEARTBEAT_URL='https://paste-the-job-1-ping-url-from-5.1'
echo "JOB1_HEARTBEAT_URL=$JOB1_HEARTBEAT_URL"
sudo sed -i "s|^HEARTBEAT_URL=.*|HEARTBEAT_URL=${JOB1_HEARTBEAT_URL}|" /etc/k3s-backup/backup.env
```

```bash
sudo systemctl start k3s-backup.service
sudo journalctl -u k3s-backup.service -n 20 --no-pager | grep -i heartbeat
```

**Check:** the log says `heartbeat sent`, and the external check flips to "up" within a minute. The
ping happens *after* the objects are verified in S3, so a green check means the backup arrived —
not that the script is pleased with itself.

### 5.3 — Install the Velero verifier and its heartbeat `[node]`

This is alerts 2 and 3 in one script. It selects the newest `daily` or `weekly` scheduled backup,
requires it to be fresh, `Completed`, backed by enough completed `PodVolumeBackups`, and **not a
backup it has already reported** — then pings the second dead-man URL.

`MIN_EXPECTED_PVBS` is the integer from 4.3 Run 5 (`wc -l`). `VELERO_HEARTBEAT_URL` is the second
ping URL from 5.1. Replace both before `tee`.

```bash
# [local]
scp scripts/velero/check-last-backup.sh \
  scripts/systemd/velero-backup-check.service \
  scripts/systemd/velero-backup-check.timer <user>@45.90.98.51:/tmp/
```

```bash
# [node]
sudo install -m 0750 /tmp/check-last-backup.sh /usr/local/sbin/check-last-velero-backup.sh
sudo install -m 0644 /tmp/velero-backup-check.service \
  /tmp/velero-backup-check.timer /etc/systemd/system/
sudo install -m 0600 /dev/null /etc/k3s-backup/velero-monitor.env
```

```bash
VELERO_HEARTBEAT_URL='https://paste-the-velero-ping-url-from-5.1'
MIN_EXPECTED_PVBS=PASTE_THE_INTEGER_FROM_4.3
echo "VELERO_HEARTBEAT_URL=$VELERO_HEARTBEAT_URL"
echo "MIN_EXPECTED_PVBS=$MIN_EXPECTED_PVBS"
sudo tee /etc/k3s-backup/velero-monitor.env >/dev/null <<EOF
VELERO_HEARTBEAT_URL=${VELERO_HEARTBEAT_URL}
MIN_EXPECTED_PVBS=${MIN_EXPECTED_PVBS}
MAX_AGE_HOURS=30
EOF
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now velero-backup-check.timer
sudo systemctl start velero-backup-check.service
sudo journalctl -u velero-backup-check.service -n 20 --no-pager
```

**Expected:** log ends with `verified and reported` plus the backup NAME column (same style as 4.3).
External check goes green. `systemctl list-timers 'velero-backup-check*'` shows next run ~06:30 UTC.

The verifier records the UID of the backup it last reported in
`/var/lib/k3s-backup/velero-last-reported` and refuses to ping twice for the same one, so a skipped
schedule stops the heartbeat even while yesterday's backup is still inside `MAX_AGE_HOURS`. Two
consequences to know before you go live: the first run after install pings immediately, and
deleting that state file causes one extra ping for a backup already reported. **Never "fix" a firing
alert by deleting it.**

### 5.4 — Alert on root disk space `[node]`

**Goal:** fire when `/` has under 10% free. Run on the **node** (no laptop kubeconfig).

**Run:**

```bash
sudo k3s kubectl get prometheusrule -A | head
```

If that returns rules, add one beside them:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: k3s-backup-host
  namespace: monitoring        # match the namespace your other rules use
spec:
  groups:
    - name: k3s-backup-host
      rules:
        - alert: RootDiskAlmostFull
          # 10% of / left. The datastore, every local-path volume and the
          # backup staging area all live here.
          expr: |
            node_filesystem_avail_bytes{mountpoint="/",fstype!~"tmpfs|overlay"}
              / node_filesystem_size_bytes{mountpoint="/",fstype!~"tmpfs|overlay"} < 0.10
          for: 15m
          labels:
            severity: warning
          annotations:
            summary: "k3-master root filesystem below 10% free"
            runbook: "docs/07-setup.md#54--alert-on-root-disk-space-node"
```

```bash
sudo k3s kubectl apply -f k3s-backup-host-rule.yaml
sudo k3s kubectl -n monitoring get prometheusrule k3s-backup-host
```

**Check:** the rule appears in Prometheus's *Rules* page and is not in `err` state. If this cluster
has no rule-based Prometheus, the fallback is a `df` check inside the Velero verifier's environment
— but write down which one you chose, because "we thought the other one covered it" is how disk
alerts go missing.

### 5.5 — Break every alert on purpose

**An untested alert is a decoration.** Do these one at a time and confirm exactly one alert fires
each time. Budget an hour; this is the step that finds the typo in the URL.

| Alert | How to break it | Expect |
|-------|-----------------|--------|
| 1 | `sudo systemctl stop k3s-backup.timer` and leave it stopped past the grace window | The Job 1 dead-man check alerts at 26 h |
| 2 | `sudo systemctl stop velero-backup-check.timer` for one cycle | The Velero check alerts at 30 h |
| 2 (missed run) | After 5.3 has already reported a backup, run `sudo systemctl start velero-backup-check.service` again with **no** new Velero backup in between | Exits non-zero, logs "a scheduled run was missed", and **does not** ping. (5.3 already consumed the first ping; a second run is the test.) |
| 3 (volume count) | Set `MIN_EXPECTED_PVBS` to `99` in `/etc/k3s-backup/velero-monitor.env`, then run the service | Exits non-zero with captured count vs 99, no ping. **Put the 4.3 value back** |
| 4 | Temporarily lower the rule's threshold above current usage, or fill a scratch file | The disk alert fires, then remove the file and restore the threshold |

Re-enable everything afterwards and confirm all four checks are green again:

```bash
sudo systemctl enable --now k3s-backup.timer velero-backup-check.timer
systemctl list-timers 'k3s-backup*' 'velero-backup-check*' --no-pager
```

Record which alerts you tested, and on what date, in the same
[ISSUES-TRACKER](ISSUES-TRACKER.md) entry. Both
backup-success alerts terminate off-server, so losing the whole host shows up as a missed heartbeat
rather than as silence.

### 5.6 — Watch the first few runs `[node]`

Takes about 30 seconds a day, for two or three days — not a week, because the alerts are the
monitoring plan, not you.

```bash
systemctl list-timers 'k3s-backup*' 'velero-backup-check*' --no-pager
journalctl -u k3s-backup.service --since '24 hours ago' --no-pager | tail -30
df -h /

# backup.env is 0600 root:root — source it and run aws in the same root shell.
sudo bash -c '
  set -a; . /etc/k3s-backup/backup.env; set +a
  AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s/daily/" | tail -8
'
```

Expect one new dated folder per day, one more under `k3s/weekly/` after the first Sunday, and S3
usage flat at roughly 200 MB once the lifecycle rules start expiring things.

> **Why `sudo bash -c '...'` and not `set -a; . backup.env` first.** `/etc/k3s-backup/backup.env` is
> `0600 root:root`. Sourcing it as your normal user gives `Permission denied` and leaves
> `$AWS_REGION`/`$S3_BUCKET` empty, so the CLI either builds a broken `https://s3..amazonaws.com`
> endpoint or reports `Unable to locate credentials`. Reading the file *inside* the root shell fixes
> both, and needs no `sudo -E`.

**One check that can only happen on a Sunday:** after the first weekend, confirm Job 1 wrote the
same committed set under `k3s/weekly/` and that Velero ran the weekly Schedule rather than the daily
one.

```bash
sudo bash -c '
  set -a; . /etc/k3s-backup/backup.env; set +a
  AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s/weekly/"
'
velero backup get -l velero.io/schedule-name=weekly
```

### 5.7 — Prove a restore works

**Nothing before this counts as proven.** Everything up to here demonstrates that backups are
*produced*; this is the only step that demonstrates they can be *used*.

Before you start, confirm the recovery kit from 2.7 is real: this repo cloned somewhere that isn't
`k3-master`, plus AWS CLI v2, `python3`, `tar`, `sha256sum`, `kubectl`, Velero CLI `v1.18.0` and
ArgoCD access. The full prerequisite list is
[03 — Before you start](03-restore-runbook.md#before-you-start).

Then run [§C of the restore runbook](03-restore-runbook.md#c--the-restore-test) on a throwaway VM.
It ends with four things written down, and the writing-down is the deliverable:

1. **The real timings per phase.** Total wall-clock time *is* the RTO — replace the estimate in
   [03](03-restore-runbook.md) and settle 1.7's assumption with a measured number.
2. **Everything that didn't match the runbook**, fixed in the runbook rather than remembered.
3. **Whether the monitoring volumes came back usable**, and therefore whether Prometheus/Loki/MinIO
   history is accepted as best-effort or needs an application-native export
   ([gap 7](05-gaps-and-open-questions.md#7-application-consistency-of-the-monitoring-volumes)).
4. **The date, and the next due date** — every 3–6 months, and after any K3s or Velero upgrade.

Paste the results under *Prove a restore works* in [ISSUES-TRACKER](ISSUES-TRACKER.md) and set the
reminder before you tear
the VM down. A restore test nobody scheduled a repeat for decays into a one-off anecdote.

---

## Undoing any of this

Nothing in stages 1–3 modifies K3s, so undoing means "remove what we added."

| Stage | How to undo |
|-------|-------------|
| 5.4 | `sudo k3s kubectl -n monitoring delete prometheusrule k3s-backup-host` |
| 5.3 | Disable `velero-backup-check.timer`, remove its service/timer/script, `velero-monitor.env` and `/var/lib/k3s-backup/`, then `daemon-reload` |
| 5.2 | Blank `HEARTBEAT_URL` in `backup.env`, and pause or delete the external checks |
| 4 | `velero uninstall` (leaves the bucket data untouched), then `kubectl delete schedule daily weekly` first if you want them gone from the cluster's history |
| 3.8 | `sudo systemctl disable --now k3s-backup.timer`, `sudo rm /etc/systemd/system/k3s-backup.*`, `daemon-reload` |
| 3.2–3.6 | `sudo rm -f /usr/local/sbin/k3s-server-backup.sh; sudo rm -rf /var/backups/k3s` |
| 3.1 | `sudo rm -rf /etc/k3s-backup`, then delete the Job 1 access key |
| 2 | Empty all object versions/delete markers, delete the bucket, then delete both inline policies, access keys and IAM users (`k3-master-backup-writer`, `k3-master-velero`) |
| 1 | Nothing — read-only throughout |

**If a backup run ever seems to be affecting the server** (unlikely — it runs at low I/O priority
and only ever reads K3s's data):

```bash
sudo systemctl stop k3s-backup.service
sudo systemctl disable --now k3s-backup.timer
```

That stops the backup completely and doesn't touch K3s. There's nothing to undo on the K3s side,
because the script never writes to it.

---

## Design notes and troubleshooting

Further reading (not required to execute this file): [01](01-discovery-baseline.md),
[02](02-backup-strategy.md), [03](03-restore-runbook.md), [04](04-implementation-todo.md),
[05](05-gaps-and-open-questions.md).

**T3 — systemd tar statx.** If Job 1 fails under systemd with `tar: … Cannot stat: Function not
implemented` but works by hand: systemd seccomp + old `libseccomp` vs `statx()`. Reinstall the unit
from this repo (`sudo install -m 0644 -o root -g root /tmp/k3s-backup.service /etc/systemd/system/`
then `daemon-reload`). Alternative: `sudo apt-get install --only-upgrade libseccomp2`. Then
`sudo sh -c 'rm -rf /var/backups/k3s/*/'`.

**Certificate self-renew.** Restoring a backup older than leaf-cert expiry can make K3s complain
then re-issue from the CA. Master (`-ca.crt`) expiry within a year is a live-cluster problem, not a
backup bug. Detail: 1.3 commands and [03 step 6](03-restore-runbook.md#step-6--start-k3s-and-verify-the-control-plane).

**Region theory.** This deployment is `us-east-1`. Why off-site / other regions: [02](02-backup-strategy.md).

**`sudo env` vs `sudo -E`.** This node rejects `sudo -E`. `sudo env KEY=value command` injects only
the named vars. Root `install-velero.sh` reads `/etc/rancher/k3s/k3s.yaml` itself if `KUBECONFIG` is
unset.

---

## What's still not covered when stages 1–4 are done

| Not covered | Until |
|-------------|-------|
| A missed backup being noticed | Both dead-man checks exist and are wired (5.1–5.3) |
| Knowing the alerts work at all | Each one has been broken on purpose (5.5) |
| A full root filesystem being noticed | The disk rule is applied (5.4) |
| Any proof a restore works | The restore test is run (5.7) |
| RPO/RTO being agreed rather than assumed | Someone signs off 1.7 / [02 §1](02-backup-strategy.md#1-two-numbers-to-agree-on-first--still-open) |
| A restore being possible without one specific person | 2.7 is filled in with two names |
| A fallback if a restore itself goes wrong | Nothing. On-premise, no hosting-provider snapshot, nothing behind the S3 bucket |
