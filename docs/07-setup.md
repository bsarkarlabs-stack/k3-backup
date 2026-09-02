# 07 — Setup, stage by stage

The hands-on companion to [04 — Implementation TODO](04-implementation-todo.md). Every command is
meant to be run **one at a time**, checking the "check" that follows before moving on.

**Target server:** `k3-master` (`45.90.98.51`) — live production, **zero tolerance for downtime**.

Five stages, in order:

| Stage | What it does | Steps | Where | Downtime risk |
|-------|--------------|-------|-------|---------------|
| [1](#stage-1--validate-the-server) | Validate — is everything we assumed still true? | 1.1–1.7 | `[node]` | **None** — read-only |
| [2](#stage-2--create-the-bucket-and-two-scoped-workload-credentials) | Create the bucket and two scoped AWS credentials | 2.1–2.7 | `[local]` | **None** — doesn't touch the server |
| [3](#stage-3--deploy-job-1) | Deploy Job 1: the K3s backup + timer | 3.1–3.8 | `[node]` | **Very low** — only reads K3s's data |
| [4](#stage-4--deploy-job-2-velero) | Deploy Job 2: Velero, and prove it reads the volumes | 4.1–4.6 | `[local]` | Low — installs into the cluster |
| [5](#stage-5--monitoring-and-the-restore-test) | Wire and test the four alerts, then prove a restore works | 5.1–5.7 | both | **None** |

**Every step is tagged with where you run it.** Get this wrong and commands fail in confusing ways,
or a credential lands on the wrong machine.

- **`[local]`** — your own laptop, in a terminal with your AWS admin login. On Windows use Git Bash
  or WSL so the `bash` snippets work. Nothing here is typed on the server.
- **`[node]`** — an SSH session on `k3-master` (`ssh <user>@45.90.98.51`), as a user who can `sudo`.
- **`[decision]`** — no command; a thing to agree and write down.

If a snippet is tagged `[local]` do **not** paste it into the server session, and vice versa.

### Every step, in order

This is the full list. [04 — Implementation TODO](04-implementation-todo.md) is the same work as
checkboxes and [ISSUES-TRACKER](ISSUES-TRACKER.md) is where the answers get pasted; nothing is
required of you that isn't a step below.

| Step | What you do | Where | Why it's on the list |
|------|-------------|-------|----------------------|
| [1.1](#11--run-the-preflight-checker-node) | Run the preflight with `--no-aws` | `[node]` | Finds local blockers before any AWS resource exists |
| [1.2](#12--confirm-the-baseline-still-holds-node) | Re-confirm hostname, version, service, disk, datastore | `[node]` | [01](01-discovery-baseline.md) is only useful if it's still true |
| [1.3](#13--look-inside-tls-and-cred-node) | List `tls/` and `cred/`; record certificate expiry | `[node]` | Nothing identity-related may sit outside the backup's paths |
| [1.4](#14--is-secrets-encryption-on-node) | `k3s secrets-encrypt status` | `[node]` | Decides how hard a precondition `cred/` is at restore |
| [1.5](#15--where-do-the-https-certificates-come-from-node) | Find where Traefik's HTTPS certificates live | `[node]` | The one answer that can change the design |
| [1.6](#16--confirm-a-safe-sqlite-backup-is-possible-node) | Confirm Python's `sqlite3` module works | `[node]` | Keeps this design free of new software on production |
| [1.7](#17--agree-an-rpo-and-an-rto-decision) | **Agree an RPO and an RTO**, or record the assumption | decision | "Daily" is arbitrary until these two numbers exist |
| [2.1](#21--pick-a-region) | Pick a region | `[local]` | Can't be changed later |
| [2.2](#22--create-the-bucket) | Create the bucket | `[local]` | — |
| [2.3](#23--lock-it-down-before-anything-is-uploaded) | Block public access, versioning, SSE-S3, HTTPS-only policy | `[local]` | This bucket holds the cluster CA |
| [2.4](#24--retention-rules) | Six lifecycle rules | `[local]` | Without them nothing ever expires |
| [2.5](#25--create-separate-job-1-and-velero-credentials) | Create the Job 1 and Velero credentials | `[local]` | Two failure domains, two keys |
| [2.6](#26--check-all-of-stage-2-at-once) | Verify every bucket and IAM setting | `[local]` | The only place bucket config is checked |
| [2.7](#27--write-down-who-can-restore-local) | Name who can restore; record bucket, region, key owners | writing | No stored restore key means access must not be one person |
| [3.1](#31--write-the-config-node) | Write `/etc/k3s-backup/backup.env` | `[node]` | — |
| [3.2](#32--install-the-script-and-units-node) | Install the script and both units | `[node]` | — |
| [3.3](#33--re-run-the-preflight-this-time-with-aws-node) | Preflight with AWS; read-back and delete must be refused | `[node]` | Proves the write-only credential really is write-only |
| [3.4](#34--write-down-the-current-state-so-you-can-prove-nothing-changed-node) | Record `NRestarts` and node state | `[node]` | The baseline for the zero-downtime claim |
| [3.5](#35--dry-run-build-the-archive-upload-nothing-node) | `DRY_RUN=1` run; check the manifest | `[node]` | Builds everything, uploads nothing |
| [3.6](#36--first-real-run-node) | First real run; confirm the committed set in S3 | `[node]` | — |
| [3.7](#37--verify-the-archive-off-the-server-local) | Download it and verify the integrity chain | `[local]` | Practises the restore-time check while nothing is on fire |
| [3.8](#38--turn-the-schedule-on-node) | Enable the timer | `[node]` | — |
| [4.1](#41--find-the-kubelet-root-node) | Find K3s's kubelet root | `[node]` | A mismatch backs up **nothing** and still says `Completed` |
| [4.2](#42--install-velero-local) | Install Velero and apply both schedules; record the versions | `[local]` | — |
| [4.3](#43--prove-the-node-agent-actually-reads-the-volumes-local) | Prove all six PVCs appear as Pod Volume Backups | `[local]` | [gap 6](05-gaps-and-open-questions.md#6-whether-veleros-node-agent-can-actually-read-our-volumes) — the likeliest silent failure |
| [4.4](#44--confirm-object-coverage-including-argocd-local) | Confirm cluster-scoped objects and the `argocd` namespace | `[local]` | What retires a separate ArgoCD export |
| [4.5](#45--prove-one-narrow-restore-local) | Restore one object into a scratch namespace | `[local]` | The 10-minute flow you'll actually use most |
| [4.6](#46--a-week-later-confirm-backups-expire-local) | A week later: confirm old backups expire | `[local]` | Proves Velero's delete permission is right |
| [5.1](#51--choose-the-two-dead-man-checks-local) | Create two external dead-man checks | `[local]` | [gap 2](05-gaps-and-open-questions.md#2-the-external-heartbeats-have-nowhere-to-report-yet) — alerts 1 and 2 |
| [5.2](#52--wire-job-1s-heartbeat-node) | Set `HEARTBEAT_URL` and confirm the ping | `[node]` | Alert 1 |
| [5.3](#53--install-the-velero-verifier-and-its-heartbeat-node) | Install the verifier, its timer and `MIN_EXPECTED_PVBS` | `[node]` | Alerts 2 and 3 |
| [5.4](#54--alert-on-root-disk-space-local) | Alert on root disk under 10% | `[local]` | Alert 4 |
| [5.5](#55--break-every-alert-on-purpose) | Break all four alerts deliberately | both | An untested alert is a decoration |
| [5.6](#56--watch-the-first-few-runs-node) | Watch two or three runs, then stop | `[node]` | — |
| [5.7](#57--prove-a-restore-works) | Run the restore test on a throwaway VM | `[local]` | **Nothing before this counts as proven** |

**Ground rules.** Nothing in stages 1–3 restarts, reloads or reconfigures K3s. If you find yourself
about to type `systemctl restart k3s`, you've gone off-script — stop. Keep a second SSH session
open the whole time. Go top to bottom; later steps depend on earlier ones.

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
export REGION=ap-south-1                   # Mumbai. Any region works — see stage 2.1
export BUCKET=k3-master-dr                 # globally unique; add a suffix if taken
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "$REGION / $BUCKET / $ACCOUNT_ID"
```

For the full picture of which credential and file belongs on which machine, read
[Where each credential and config lives](#where-each-credential-and-config-lives) before Stage 2.

---

## Stage 1 — Validate the server

### 1.1 — Run the preflight checker `[node]`

**Do this before anything else.** One command, changes nothing, answers "is everything actually in
place?" in about 30 seconds.

```bash
scp scripts/k3s-backup-preflight.sh <user>@45.90.98.51:/tmp/     # from [local]
```

```bash
sudo install -m 0750 -o root -g root /tmp/k3s-backup-preflight.sh /usr/local/sbin/
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws
```

Use `--no-aws` this first time — the bucket doesn't exist yet. It'll tell you what's missing
locally so you aren't creating AWS resources only to find the server can't use them.

| Exit | Meaning |
|------|---------|
| `0` — READY | Everything checks out |
| `2` — READY, with warnings | Safe to proceed, but read them — some mean a future failure would go unnoticed |
| `1` — NOT READY | Blocking problems. Every failure prints the exact command to fix it |

### 1.2 — Confirm the baseline still holds `[node]`

```bash
hostnamectl | head -3
k3s --version
systemctl is-active k3s && systemctl is-enabled k3s
df -h / && df -i /
sudo ls -la /var/lib/rancher/k3s/server/db/
sudo k3s etcd-snapshot ls 2>&1 | head -2
```

**Check:**

- Hostname `k3-master`, K3s `v1.34.5+k3s1`, service both `active` and `enabled`.
- **At least 5 GB free** on `/`. We recorded 34 GB at discovery.
- `db/` contains `state.db`, `state.db-wal`, `state.db-shm`.
- `etcd-snapshot ls` still says `etcd datastore disabled` — confirming we really do need the SQLite
  approach, not a K3s built-in snapshot.

> If the K3s version has changed, update [01](01-discovery-baseline.md). A restore needs the
> matching version, and `MANIFEST.json` will record whatever is actually installed.

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

While you're here, write down **when the certificates expire**. This reads expiry dates only:

```bash
for c in /var/lib/rancher/k3s/server/tls/*.crt; do
  printf '%-58s ' "$(basename "$c")"
  sudo openssl x509 -enddate -noout -in "$c" 2>/dev/null || echo "couldn't read"
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
        k3-master-dr-xxxx        +------------+------------+
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
| **Laptop `[local]`** | Your AWS admin profile; temporary `/tmp/k3-dr-*.json` policy files; a temporary `./velero-credentials` file | **No** — the `/tmp` files and `velero-credentials` are deleted once used |
| **AWS** | The S3 bucket; IAM users `k3-master-backup-writer` and `k3-master-velero`; their inline policies and access keys | Yes |
| **`k3-master` `[node]`** | `/etc/k3s-backup/backup.env` — holds **only** the Job 1 key | Yes |
| **Kubernetes** | The Velero AWS key, stored as a Secret in the `velero` namespace (the installer creates it) | Yes |
| **This Git repo** | Scripts, docs, systemd units, Velero YAML — **never a real key** | Yes |

Two rules that fall out of the map:

- **The Velero key never goes in `backup.env`.** `backup.env` is Job 1 only. The Velero key reaches
  the cluster through the installer, as a Kubernetes Secret, and its laptop copy is shredded after.
- **No real key ever gets committed.** `.gitignore` already blocks `backup.env`, `*.credentials`,
  `velero-credentials`, `*.key` and `.env*`; the two access-key secrets are shown once by AWS, so
  save them in a password manager, not in a file in this repo.

The temporary laptop files you will create and then delete:

```text
/tmp/k3-dr-bucket-policy.json     bucket HTTPS-only policy   (step 2.3)
/tmp/k3-dr-lifecycle.json         retention rules            (step 2.4)
/tmp/k3-dr-writer-policy.json     Job 1 IAM policy           (step 2.5)
/tmp/k3-dr-velero-policy.json     Velero IAM policy          (step 2.5)
./velero-credentials              Velero key, for the installer only (step 4.2)
```

Each of these is only a *helper* that hands a document to AWS or the installer. The real
configuration ends up inside AWS, on the node, or in the cluster — never in these files, which is
why every one of them is deleted once it has done its job.

---

## Stage 2 — Create the bucket and two scoped workload credentials

All `[local]`, with your admin login. **Nothing here touches `k3-master`.** If you have more than
one AWS account configured, confirm you are pointed at the right one before creating anything:

```bash
aws sts get-caller-identity      # is this the account that should own the DR bucket?
```

If it isn't, set `AWS_PROFILE` (see the variable block above) until this shows the correct account.

### 2.1 — Pick a region

A region is just *which AWS data centre stores the files*. It **can't be changed later** — moving
means a new bucket and copying everything across. Our daily upload is ~20 MB, so speed is
irrelevant; pick on cost and on where the team and any compliance requirements are.

| Region | Code | Good when |
|--------|------|-----------|
| Mumbai | `ap-south-1` | Team is in India. **Our default** |
| N. Virginia | `us-east-1` | Cheapest. One quirk, noted in 2.2 |
| Frankfurt | `eu-central-1` | Closest to the Datalix server; keeps data in the EU |

> **Why off-site at all:** this server is on-premise-style with no hosting-provider snapshot. A
> backup that only lives on `k3-master` dies with `k3-master`. Any off-server destination would do
> — S3 is just the one we picked, and only the upload step in the script would change. What is
> **not** acceptable is a destination on the same disk, including the MinIO running inside our own
> cluster.

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

> Bucket names are globally unique. On `BucketAlreadyExists`, use `k3-master-dr-<yourorg>` and
> update `$BUCKET` — every later command reads that variable.

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

1. **At least two named people** who can log into AWS and read `s3://k3-master-dr`. One is not a
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
S3_BUCKET=k3-master-dr
AWS_REGION=<your-region>
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
bash -n /usr/local/sbin/k3s-server-backup.sh && echo "syntax OK"
```

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
sudo ls -lah /var/backups/k3s/*/
```

**Check:** the script should print `snapshot ok (read-only), integrity_check=ok`, then
`manifest: k3s=v1.34.5+k3s1 …`, then an archive size around 20 MB. In the staging folder you should
see four things — the `.tar.gz`, its `.sha256`, `MANIFEST.json`, and `COMPLETE.json`.

Look inside without extracting anything:

```bash
sudo tar -tzf /var/backups/k3s/*/k3s-*.tar.gz | head -30
sudo python3 -m json.tool /var/backups/k3s/*/MANIFEST.json
```

**Check the manifest**, because it's the file a restore reads first:

- `k3s_version` is a real version, **not** `unknown`. If it says `unknown` the script couldn't read
  `/usr/local/bin/k3s` — fix that before going further, a manifest without a version defeats the
  point of having one.
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
sudo rm -rf /var/backups/k3s/*/
```

### 3.6 — First real run `[node]`

```bash
sudo /usr/local/sbin/k3s-server-backup.sh
```

The script verifies its own uploads and will fail loudly if an object didn't land at the right
size, so a clean exit is already meaningful. Confirm independently anyway:

```bash
set -a; . /etc/k3s-backup/backup.env; set +a
# Prefix-scoped: the Job 1 key cannot list the bucket root.
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s/" --recursive --human-readable
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s-release/" --recursive --human-readable
```

```text
k3s/daily/2026-09-02T021500Z/COMPLETE.json
k3s/daily/2026-09-02T021500Z/MANIFEST.json
k3s/daily/2026-09-02T021500Z/k3s-2026-09-02T021500Z.tar.gz
k3s/daily/2026-09-02T021500Z/k3s-2026-09-02T021500Z.tar.gz.sha256
k3s-release/v1.34.5+k3s1/RESTORE.txt
k3s-release/v1.34.5+k3s1/k3s
k3s-release/v1.34.5+k3s1/k3s.sha256
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
PY
```

That chain check is exactly what
[restore step 1](03-restore-runbook.md#step-1--pick-a-backup-and-read-its-manifest) tells you to run
during an outage — practise it here, while nothing is on fire.

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

**Check:** `status=0/SUCCESS`, and the log ends with `completed successfully`.

Only now:

```bash
sudo systemctl enable --now k3s-backup.timer
systemctl list-timers 'k3s-backup*' --all --no-pager
```

**Check:** next run at 02:15 UTC. Its 30-minute systemd timeout plus 10-minute random delay ends
before the 03:30 UTC Velero window. The script also takes a lock, so two Job 1 runs cannot overlap.

---

## Stage 4 — Deploy Job 2 (Velero)

**This is half the design, not an optional extra.** Job 1 cannot restore a deleted PVC or a single
deleted Secret, and `local-path` destroys a volume's files the instant its PVC goes away.

### 4.1 — Find the kubelet root `[node]`

Velero's file-system backup reads pod volumes through a hostPath into the kubelet root. K3s does not
always use the stock `/var/lib/kubelet`, and **a mismatch starts cleanly and backs up nothing** —
it looks like an empty backup, not an error.

```bash
sudo ls -la /var/lib/kubelet/pods 2>/dev/null | head -3
sudo k3s kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/configz" 2>/dev/null | head -c 400; echo
```

Write down what you find. You'll compare the node-agent's hostPath against it in 4.3.

### 4.2 — Install Velero `[local]`

Install **Velero CLI v1.18.0** and verify that this machine reaches the production cluster first:

```bash
velero version --client-only       # v1.18.0
kubectl get nodes                  # k3-master Ready
```

The installer pins AWS plugin `v1.14.1`, the compatible plugin series for Velero `v1.18.x`.

Now the **Velero** access key from 2.5 comes into play — the `k3-master-velero` pair, which is
different from the Job 1 key in `backup.env`. It goes into a short-lived file on your laptop that
the installer turns into a Kubernetes Secret; you shred the file straight after. It is never written
to `backup.env` and never committed.

```bash
cat > ./velero-credentials <<'EOF'
[default]
aws_access_key_id=<k3-master-velero key from 2.5>
aws_secret_access_key=<k3-master-velero secret from 2.5>
EOF
chmod 600 ./velero-credentials

export S3_BUCKET="$BUCKET" AWS_REGION="$REGION" CREDS_FILE=./velero-credentials
export KUBELET_ROOT_DIR=/var/lib/kubelet   # replace with the verified 4.1 value
./scripts/velero/install-velero.sh

shred -u ./velero-credentials             # the key now lives only as a cluster Secret
kubectl apply -f scripts/velero/schedule-daily.yaml
kubectl apply -f scripts/velero/schedule-weekly.yaml
```

No encryption flags are passed — the bucket's default SSE-S3 encrypts every object on arrival. After
the install, the Velero key lives **only** as a Secret in the `velero` namespace; confirm it landed
and nothing kept a plaintext copy:

```bash
kubectl -n velero get secret cloud-credentials     # created by the installer
ls ./velero-credentials 2>/dev/null && echo "DELETE THIS" || echo "good — laptop copy is gone"
```

**Check, and write these three versions down** — a restore has to reproduce them, and `velero
install` deploys `velero/velero:<CLI version>`, so an unpinned CLI silently decides the server
version:

```bash
velero version                    # client and server should both read v1.18.0
kubectl -n velero get deploy velero \
  -o jsonpath='{.spec.template.spec.initContainers[*].image}{"\n"}'   # plugin v1.14.1
kubectl -n velero get schedules   # daily and weekly, both Enabled
```

Record the CLI, server and plugin versions in [01](01-discovery-baseline.md) alongside the K3s
version. Restoring into a cluster whose Velero predates the backup's format is a migration, not a
restore.

### 4.3 — Prove the node-agent actually reads the volumes `[local]`

A green checkmark is not evidence. This is
[gap 6](05-gaps-and-open-questions.md#6-whether-veleros-node-agent-can-actually-read-our-volumes)
and the most likely silent failure in the whole design.

```bash
kubectl -n velero get pods                       # node-agent must be Running
kubectl -n velero get backupstoragelocation      # must be Available
kubectl -n velero get ds node-agent -o jsonpath='{.spec.template.spec.volumes[*].hostPath.path}{"\n"}'

velero backup create verify-$(date +%s) --wait
velero backup describe <name> --details
```

**Check:** the node-agent's hostPath matches what you found in 4.1, and **all six monitoring PVCs
appear under "Pod Volume Backups"**. An empty section there is the failure — stop and fix it before
trusting anything.

Count the pod volumes in that backup and keep the number; it becomes `MIN_EXPECTED_PVBS` in 5.3:

```bash
kubectl -n velero get podvolumebackups \
  -l velero.io/backup-name=<name> --no-headers | wc -l      # expect 6
```

Use that count, **not** the raw PVC count: an unmounted claim produces no pod volume, and a volume
mounted by two pods produces two. The number that matters is what the node-agent actually did.

### 4.4 — Confirm object coverage, including ArgoCD `[local]`

The backup takes everything by default, so this is verifying there's no surprise rather than
building an include list. It's also what retires the separate daily `argocd admin export` for good
(the *ArgoCD recoverability* entry in [ISSUES-TRACKER](ISSUES-TRACKER.md)).

```bash
velero backup describe <name> --details | sed -n '/Resource List/,$p' | head -40

# cluster-scoped objects must be in there, not just namespaced ones
velero backup describe <name> --details | grep -E 'customresourcedefinitions|clusterroles|storageclasses'

# ArgoCD's own state: Applications, AppProjects and its Secrets
velero backup describe <name> --details | grep -E 'argocd/'
```

**Check:**

- CRDs, ClusterRoles, ClusterRoleBindings and the StorageClass all appear.
- The `argocd` namespace contributes Secrets, Applications and AppProjects. Anything hand-made in
  the UI comes back from Velero and *not* from Git, which is exactly why this has to be confirmed.
- While you're here, write down **which Git repositories and logins ArgoCD depends on**. Velero
  restores the Application objects; it cannot restore access to a repo whose deploy key nobody has.

### 4.5 — Prove one narrow restore `[local]`

The ~10-minute flow you will actually use most often, so prove it while nothing is wrong. Full
procedure: [03 §B](03-restore-runbook.md#b--restoring-one-pvc-or-one-object).

```bash
kubectl create namespace restore-probe
kubectl -n restore-probe create configmap probe --from-literal=k=v
velero backup create probe-$(date +%s) --include-namespaces restore-probe --wait

kubectl delete namespace restore-probe
velero restore create --from-backup <probe-backup> --include-namespaces restore-probe --wait
kubectl -n restore-probe get configmap probe -o jsonpath='{.data.k}{"\n"}'   # v

kubectl delete namespace restore-probe
```

**Check:** the ConfigMap comes back with its data. Then stop there — **do not** try to prove PVC
recovery with a scratch namespace. Volume data only returns when Velero creates the pod, so a
meaningful PVC test requires the controller-aware procedure in
[03 §B](03-restore-runbook.md#one-pvcs-data) (suspend ArgoCD, delete the owning workload *and* the
claim) and the real thing is exercised by the restore test in 5.7.

### 4.6 — A week later: confirm backups expire `[local]`

Put this in your calendar for eight days out. It is the only proof that Velero's delete permission
on `velero/*` works — and if it doesn't, retention is fiction and the bucket grows forever.

```bash
velero backup get                       # nothing older than 7 days in the daily tier
velero backup get -l velero.io/schedule-name=weekly
aws s3 ls "s3://$BUCKET/velero/backups/" | wc -l
```

**Check:** daily-tier backups older than 168 h are gone, Sunday ones survive to 720 h, and the
object count is flat rather than climbing. If nothing ever expires, re-read the Velero policy in
2.5 before "fixing" the schedules.

---

## Stage 5 — Monitoring and the restore test

Four alerts, and only four. Design and thresholds:
[02 §7](02-backup-strategy.md#7-knowing-it-works).

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

### 5.2 — Wire Job 1's heartbeat `[node]`

```bash
sudo sed -i 's|^HEARTBEAT_URL=.*|HEARTBEAT_URL=https://<job-1-check-url>|' /etc/k3s-backup/backup.env
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

```bash
# [local]
scp scripts/velero/check-last-backup.sh \
  scripts/systemd/velero-backup-check.service \
  scripts/systemd/velero-backup-check.timer <user>@45.90.98.51:/tmp/

# [node]
sudo install -m 0750 /tmp/check-last-backup.sh /usr/local/sbin/check-last-velero-backup.sh
sudo install -m 0644 /tmp/velero-backup-check.service \
  /tmp/velero-backup-check.timer /etc/systemd/system/
sudo install -m 0600 /dev/null /etc/k3s-backup/velero-monitor.env
sudo tee /etc/k3s-backup/velero-monitor.env >/dev/null <<'EOF'
VELERO_HEARTBEAT_URL=https://<velero-check-url>
MIN_EXPECTED_PVBS=6
MAX_AGE_HOURS=30
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now velero-backup-check.timer
sudo systemctl start velero-backup-check.service
sudo journalctl -u velero-backup-check.service -n 20 --no-pager
```

**Check:** the log ends with `verified and reported <backup-name>`, the external check goes green,
and `systemctl list-timers 'velero-backup-check*'` shows the next run at 06:30 UTC.

`MIN_EXPECTED_PVBS` comes from the volume count you took in 4.3 — **not** from the PVC count. Raise
or lower it whenever the mounted volume topology changes; leaving it stale is how a lost volume
stops being noticed.

The verifier records the UID of the backup it last reported in
`/var/lib/k3s-backup/velero-last-reported` and refuses to ping twice for the same one, so a skipped
schedule stops the heartbeat even while yesterday's backup is still inside `MAX_AGE_HOURS`. Two
consequences to know before you go live: the first run after install pings immediately, and
deleting that state file causes one extra ping for a backup already reported. **Never "fix" a firing
alert by deleting it.**

### 5.4 — Alert on root disk space `[local]`

The one in-cluster alert, because it's the one failure the cluster itself can still report. `/`
holds the datastore, every `local-path` volume and the backup staging directory; at 100% full K3s
stops writing and the backup fails with it.

```bash
kubectl get prometheusrule -A | head            # confirms the operator-based stack
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
            runbook: "docs/07-setup.md#54--alert-on-root-disk-space-local"
```

```bash
kubectl apply -f k3s-backup-host-rule.yaml
kubectl -n monitoring get prometheusrule k3s-backup-host
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
| 3 (volume count) | `sudo sed -i 's/^MIN_EXPECTED_PVBS=.*/MIN_EXPECTED_PVBS=99/' /etc/k3s-backup/velero-monitor.env`, then run the service | Exits non-zero with "captured 6 pod volumes; expected at least 99", no ping. **Put the real value back** |
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

set -a; . /etc/k3s-backup/backup.env; set +a
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s/daily/" | tail -8
```

Expect one new dated folder per day, one more under `k3s/weekly/` after the first Sunday, and S3
usage flat at roughly 200 MB once the lifecycle rules start expiring things.

> Every `aws` command here needs that `set -a; . backup.env; set +a` line first — it's what puts the
> credentials and bucket name into the shell. Without it you get `Unable to locate credentials`,
> which looks like a permissions problem and isn't.

**One check that can only happen on a Sunday:** after the first weekend, confirm Job 1 wrote the
same committed set under `k3s/weekly/` and that Velero ran the weekly Schedule rather than the daily
one.

```bash
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s/weekly/"
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
| 5.4 | `kubectl -n monitoring delete prometheusrule k3s-backup-host` |
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
