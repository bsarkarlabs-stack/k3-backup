# 07 — Setup, stage by stage

The hands-on companion to [04 — Implementation TODO](04-implementation-todo.md). Every command is
meant to be run **one at a time**, checking the "check" that follows before moving on.

**Target server:** `k3-master` (`45.90.98.51`) — live production, **zero tolerance for downtime**.

Five stages, in order:

| Stage | What it does | Where | Downtime risk |
|-------|--------------|-------|---------------|
| [1](#stage-1--validate-the-server) | Validate — is everything we assumed still true? | `[node]` | **None** — read-only |
| [2](#stage-2--create-the-bucket-and-the-one-credential) | Create the bucket and the one AWS credential | `[local]` | **None** — doesn't touch the server |
| [3](#stage-3--deploy-job-1) | Deploy Job 1: the K3s backup + timer | `[node]` | **Very low** — only reads K3s's data |
| [4](#stage-4--deploy-job-2-velero) | Deploy Job 2: Velero | `[local]` | Low — installs into the cluster |
| [5](#stage-5--monitoring-and-the-restore-test) | Wire the alerts, then prove a restore works | both | **None** |

`[local]` means your own laptop with your AWS admin login. `[node]` means an SSH session on
`k3-master`.

**Ground rules.** Nothing in stages 1–3 restarts, reloads or reconfigures K3s. If you find yourself
about to type `systemctl restart k3s`, you've gone off-script — stop. Keep a second SSH session
open the whole time. Go top to bottom; later steps depend on earlier ones.

The safety claim that matters, stated plainly so you can verify it yourself: **the datastore
backup uses SQLite's built-in online backup API through a read-only connection, and because SQLite
is in WAL mode this never blocks anything else writing to the database.** A plain file copy would
have been the dangerous option — that's exactly why the script doesn't do one.

These shell variables are used throughout the `[local]` steps:

```bash
export AWS_PROFILE=<your-admin-profile>
export REGION=ap-south-1                  # Mumbai. Any region works — see stage 2.1
export BUCKET=k3-master-dr                # globally unique; add a suffix if taken
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "$REGION / $BUCKET / $ACCOUNT_ID"
```

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

---

## Stage 2 — Create the bucket and the one credential

All `[local]`, with your admin login. **Nothing here touches `k3-master`.**

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
      "NoncurrentVersionExpiration": { "NoncurrentDays": 2 } },

    { "ID": "k3s-weekly-31d", "Status": "Enabled",
      "Filter": { "Prefix": "k3s/weekly/" },
      "Expiration": { "Days": 31 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 2 } },

    { "ID": "preflight-tests-2d", "Status": "Enabled",
      "Filter": { "Prefix": "_preflight/" },
      "Expiration": { "Days": 2 } },

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

> ### 🚨 There is deliberately **no rule for `velero/` and none for `k3s-release/`**
>
> Velero's file-system backups live in a Kopia repository whose objects reference each other, and
> Velero expires them itself using each Schedule's `ttl`. An S3 expiry rule would delete chunks a
> still-valid backup depends on, and the corruption only shows up when you try to restore. If you
> want a safety net there, use a *noncurrent* version expiry only.
>
> `k3s-release/` holds the K3s binaries a future restore needs. It must never expire.

### 2.5 — Create the one credential the server gets

```bash
aws iam create-user --user-name k3-master-backup-writer

cat > /tmp/k3-dr-writer-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListOwnBucketOnly",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::$BUCKET"
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
    },
    {
      "Sid": "VeleroOwnsItsOwnPrefix",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::$BUCKET/velero/*"
    }
  ]
}
EOF

aws iam put-user-policy --user-name k3-master-backup-writer \
  --policy-name k3-master-dr-write --policy-document file:///tmp/k3-dr-writer-policy.json

aws iam create-access-key --user-name k3-master-backup-writer \
  --query 'AccessKey.{Id:AccessKeyId,Secret:SecretAccessKey}' --output table

rm -f /tmp/k3-dr-*.json
```

Read the *gaps* in that policy, because they're the design:

- **No `GetObject` on `k3s/*`.** The server writes backups and can never read one back. A
  compromised `k3-master` cannot download the cluster CA out of S3. The script confirms its own
  uploads by *listing* them and comparing sizes.
- **No `DeleteObject` on `k3s/*`.** Old backups expire via the lifecycle rules in 2.4, never via
  anything on the server.
- **`velero/*` gets full control on purpose.** Velero expires its own backups using `ttl` — TTL
  expiry *is* Velero issuing deletes. Remove it and nothing under `velero/` ever expires, the "7
  daily + 4 weekly" retention becomes fiction, and failed backups leave partial data behind.
  **Do not "harden" this away.**

Save the access key ID and secret somewhere safe right now — the secret is shown once. They go into
`/etc/k3s-backup/backup.env` in stage 3 and nowhere else. **Never commit them to this repo.**

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
```

Expect: four `true`s, versioning `Enabled`, encryption `AES256`, four lifecycle rules with **none**
on `velero/` or `k3s-release/`, and one inline policy on the user.

**This is the only place bucket settings get verified.** The on-node preflight deliberately doesn't
check them — that credential can't read bucket configuration, and it shouldn't be able to.

---

## Stage 3 — Deploy Job 1

### 3.1 — Write the config `[node]`

```bash
sudo install -d -m 0700 -o root -g root /etc/k3s-backup
sudo install -m 0600 -o root -g root /dev/null /etc/k3s-backup/backup.env
sudo nano /etc/k3s-backup/backup.env
```

```ini
S3_BUCKET=k3-master-dr
AWS_REGION=<your-region>
AWS_ACCESS_KEY_ID=<from stage 2.5>
AWS_SECRET_ACCESS_KEY=<from stage 2.5>
# The only alert that still works when this server is dead. See 02 §7.
HEARTBEAT_URL=
```

**Check:**

```bash
sudo stat -c '%a %U:%G %n' /etc/k3s-backup /etc/k3s-backup/backup.env
```

`700 root:root` and `600 root:root`. Anything readable by other users here is a problem to fix
immediately — this file holds write access to the bucket containing the cluster CA.

> `HEARTBEAT_URL` can stay empty for now; the script warns on every run until it's set. Filling it
> in is [gap 2](05-gaps-and-open-questions.md#2-the-heartbeat-has-nowhere-to-report-to-yet) and
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
see three things — the `.tar.gz`, its `.sha256`, and `MANIFEST.json`.

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
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/" --recursive --human-readable
```

```text
k3s/daily/2026-09-02/MANIFEST.json
k3s/daily/2026-09-02/k3s-2026-09-02.tar.gz
k3s/daily/2026-09-02/k3s-2026-09-02.tar.gz.sha256
k3s-release/v1.34.5+k3s1/RESTORE.txt
k3s-release/v1.34.5+k3s1/k3s
```

**That folder is one complete restore set.** The `k3s-release/` upload happens once per version —
tomorrow's run won't repeat it.

If today is Sunday you'll also see the same three objects under `k3s/weekly/`. That's the retention
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
DATE=$(aws s3 ls "s3://$BUCKET/k3s/daily/" | awk '{print $2}' | tr -d '/' | sort | tail -1)
aws s3 cp "s3://$BUCKET/k3s/daily/$DATE/" . --recursive
sha256sum -c ./*.sha256
```

That one `sha256sum -c` verifies the whole backup, and it's the same command
[restore step 1](03-restore-runbook.md#step-1--pick-a-backup-and-read-its-manifest) tells you to run
during an outage.

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

**Check:** next run at 02:15 UTC — 45 minutes ahead of the Velero schedule, so the SQLite reader
and Velero's node-agent are never on the disk together. The script also takes a lock, so a slow run
can never overlap the next one.

---

## Stage 4 — Deploy Job 2 (Velero)

**This is half the design, not an optional extra.** Job 1 cannot restore a deleted PVC or a single
deleted Secret, and `local-path` destroys a volume's files the instant its PVC goes away.

### 4.1 — Install the CLI and find the kubelet root `[node]`

Velero's file-system backup reads pod volumes through a hostPath into the kubelet root. K3s does not
always use the stock `/var/lib/kubelet`, and **a mismatch starts cleanly and backs up nothing** —
it looks like an empty backup, not an error.

```bash
sudo ls -la /var/lib/kubelet/pods 2>/dev/null | head -3
sudo k3s kubectl get --raw "/api/v1/nodes/$(hostname)/proxy/configz" 2>/dev/null | head -c 400; echo
```

Write down what you find. You'll compare the node-agent's hostPath against it in 4.3.

### 4.2 — Install Velero `[local]`

```bash
cat > ./velero-credentials <<'EOF'
[default]
aws_access_key_id=<the writer key from 2.5>
aws_secret_access_key=<the writer secret>
EOF
chmod 600 ./velero-credentials

export S3_BUCKET="$BUCKET" AWS_REGION="$REGION" CREDS_FILE=./velero-credentials
./scripts/velero/install-velero.sh

shred -u ./velero-credentials
kubectl apply -f scripts/velero/schedule-daily.yaml
kubectl apply -f scripts/velero/schedule-weekly.yaml
```

No encryption flags are passed — the bucket's default SSE-S3 encrypts every object on arrival.

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

Also confirm, while you're here:

- Cluster-scoped resources are in the backup (CRDs, ClusterRoles, StorageClass).
- The `argocd` namespace backup contains its Secrets and Applications — that's what retires the
  separate ArgoCD export for good.
- One small restore into a scratch namespace actually works — see
  [03 §B](03-restore-runbook.md#b--restoring-one-pvc-or-one-object).
- After a week, that old backups really do expire — proof the `velero/` delete permission is right.

---

## Stage 5 — Monitoring and the restore test

### 5.1 — Wire the four alerts

Design and thresholds are in [02 §7](02-backup-strategy.md#7-knowing-it-works). In short:

| # | Alert | Status |
|---|-------|--------|
| 1 | No Job 1 backup arrived in 26 h — **off-server heartbeat** | ⏳ channel undecided ([gap 2](05-gaps-and-open-questions.md#2-the-heartbeat-has-nowhere-to-report-to-yet)) |
| 2 | Velero's last backup isn't `Completed` — `velero_backup_last_successful_timestamp`, in-cluster | to do |
| 3 | **Fewer pod volumes in the last backup than the cluster has PVCs** — in-cluster | to do |
| 4 | Root disk free under 10% — in-cluster | to do |

Alert 3 is not a duplicate of alert 2. A Velero backup that captured **zero** volumes still finishes
`Completed`, so alert 2 stays green through the exact failure
[gap 6](05-gaps-and-open-questions.md) describes. Count the volumes, not the status:

```bash
LAST=$(velero backup get -o name | head -1 | cut -d/ -f2)
kubectl -n velero get podvolumebackups -l velero.io/backup-name="$LAST" \
  --field-selector status.phase=Completed --no-headers | wc -l
kubectl get pvc -A --no-headers | wc -l        # the two numbers must match
```

Once the heartbeat channel is chosen, it's one line:

```bash
sudo sed -i 's|^HEARTBEAT_URL=.*|HEARTBEAT_URL=https://...|' /etc/k3s-backup/backup.env
sudo systemctl start k3s-backup.service     # confirm "heartbeat sent" in the log
```

**Test each alert by deliberately breaking it.** An untested alert is a decoration. Stop the timer
for a day, or point `HEARTBEAT_URL` at a dead endpoint, and confirm someone is actually told.

Remember why alert 1 is the one that matters: alerts 2, 3 and 4 run inside the cluster we're
protecting, so they die with the server.

### 5.2 — Watch the first few runs `[node]`

Takes about 30 seconds a day, for two or three days — not a week, because the alerts are the
monitoring plan, not you.

```bash
systemctl list-timers 'k3s-backup*' --no-pager
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

### 5.3 — Prove a restore works

**Nothing before this counts as proven.** Run
[§C of the restore runbook](03-restore-runbook.md#c--the-restore-test) on a throwaway VM, then
record the real timings in the runbook and set a reminder to repeat it every 3–6 months.

---

## Undoing any of this

Nothing in stages 1–3 modifies K3s, so undoing means "remove what we added."

| Stage | How to undo |
|-------|-------------|
| 3.8 | `sudo systemctl disable --now k3s-backup.timer`, `sudo rm /etc/systemd/system/k3s-backup.*`, `daemon-reload` |
| 3.2–3.6 | `sudo rm -f /usr/local/sbin/k3s-server-backup.sh; sudo rm -rf /var/backups/k3s` |
| 3.1 | `sudo rm -rf /etc/k3s-backup`, then `aws iam delete-access-key --user-name k3-master-backup-writer --access-key-id <id>` |
| 2 | `aws s3 rm s3://$BUCKET --recursive`, `aws s3api delete-bucket --bucket $BUCKET`, `aws iam delete-user-policy …` then `delete-user` |
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
| A missed backup being noticed | The heartbeat channel is chosen and wired (5.1) |
| Any proof a restore works | The restore test is run (5.3) |
| RPO/RTO being agreed rather than assumed | Someone signs off [02 §1](02-backup-strategy.md#1-two-numbers-to-agree-on-first--still-open) |
| A fallback if a restore itself goes wrong | Nothing. On-premise, no hosting-provider snapshot, nothing behind the S3 bucket |
