# 07 — Phase 0 & 1: Step-by-Step Commands (safe to run in production)

This is the hands-on companion to [04 — Implementation TODO](04-implementation-todo.md), covering
phases [#9](../../../issues/9) and [#10](../../../issues/10). Every command below is meant to be typed
or pasted **one at a time**, checking the "check" section after each one before moving to the
next.

**Target server:** `k3-master` (`45.90.98.51`) — this is a live production server, and we have
**zero tolerance for downtime** while doing this.

---

## 0. How to use this document

1. Go top to bottom. Later steps depend on the ones before them.
2. After every command, run the "check" step that follows it. If it doesn't match what's
   expected, **stop** — don't guess and move on to the next step anyway.
3. Nothing in Phase 0 or Phase 1 restarts, reloads, or reconfigures K3s. If you find yourself
   about to type `systemctl restart k3s`, you've gone off-script — stop.
4. Keep a second SSH session open to `k3-master` the whole time. If your main session ever
   freezes up, you can use the second one to figure out what happened, instead of blindly
   reconnecting.
5. Do this during a quiet, low-traffic time anyway — not because any step here is actually risky,
   but because the first time you run something new, it deserves someone paying close attention.

### How risky is each stage?

| Stage | What it touches | Downtime risk | Why |
|-------|-----------------|---------------|-----|
| A — Double-check everything | Nothing — just reads information | **None** | Just runs `df`, `systemctl is-active`, `ls`, etc. |
| B — Fill in the unknowns | Nothing — just reads information | **None** | Just runs `find`, `kubectl get`, `dmidecode`. |
| C — Set up AWS | Your AWS account, not the server | **None** | This runs from your own laptop. |
| D — Set up login + test connection | Creates `/etc/k3s-backup/`, and one throwaway test file in S3 | **None** | Brand new folder, unrelated to K3s. |
| E — Install script (test run only) | Creates a file in `/usr/local/sbin/`, reads K3s's data, temporarily stores ~100 MB in `/var/backups` | **Very low** | Only reads K3s's data, never writes to it; disk space is checked first. |
| F — First real backup | Same as above, plus actually uploading to S3 | **Very low** | About 100 MB uploaded, done at low priority so it doesn't compete with K3s. |
| G — Prove the backup can actually be restored | Downloads a copy to your own laptop | **None** | This check happens entirely off the server. |
| H — Turn on the automatic schedule | Adds two new scheduled jobs | **Very low** | Brand new scheduled jobs; nothing existing gets touched. |

Here's the one safety claim that really matters, stated plainly so you can verify it yourself:
**the SQLite backup uses the database's built-in "safe copy" feature, through a read-only
connection — and since SQLite is in "WAL" mode (an internal live-writing mode), this doesn't
block or interfere with anything else trying to write to the database at the same time.** A plain
file copy would have been the dangerous option — that's exactly why the script doesn't do one.

### What this covers — just K3s, nothing more

This backs up **K3s only**, not the entire server disk. No full disk image, no copy of
`/var/lib/rancher/k3s/agent` (that's the 43 GB of container images/cache, which we deliberately
skip — see [02 §3](02-backup-strategy.md#what-job-1-deliberately-does-not-back-up)). Our recovery plan
is: *set up a plain Ubuntu server, install the matching K3s version, then put K3s's own saved
state back on top of it.*

There's one deliberate exception worth calling out. The run also grabs about 1 MB of the server's
OS-level settings — network settings, firewall rules, `/etc/ssh`, allowed logins, timezone, and the
list of installed packages. That's not technically K3s, but it's what turns
[restore step 2](03-restore-runbook.md#step-2--prepare-the-host) from *"try to remember the static
IP and firewall rules from memory, during an actual outage"* into *"just unpack this file."* It
rides along in the same job and the same folder — no extra schedule, no extra retention rule. This
is part of [Phase 1](04-implementation-todo.md#phase-1--job-1-k3s-server-backup) and closes gap
[#5](../../../issues/5).

We recommend keeping this unless you have a specific reason not to. If you want a strictly
K3s-only backup, add this line to `/etc/k3s-backup/backup.env`:

```ini
INCLUDE_NODE_CONFIG=0
```

> **This document covers job 1 only.** Job 2 (Velero — every Kubernetes object, plus all PVC data)
> is a separate install: [`scripts/velero/`](../scripts/velero/) and
> [04 Phase 2](04-implementation-todo.md#phase-2--job-2-velero). Job 1 alone cannot restore a
> deleted PVC or a single deleted Secret.

### A quick note on how the instructions are labeled

Each command below is labeled with where to run it:

- `[local]` — on your own laptop (this is where your AWS admin login works)
- `[node]` — inside an SSH session on `k3-master`

These shell variables are used throughout the `[local]` steps:

```bash
export AWS_PROFILE=<your-admin-profile>
export REGION=ap-south-1                  # Mumbai. Feel free to change — see Stage C.0
export BUCKET=k3-master-dr                # see Stage C.2 if this name is already taken
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "$REGION / $BUCKET / $ACCOUNT_ID"
```

---

## Stage A.0 — Run the preflight checker first `[node]`

**Do this before anything else.** It's one command, it changes nothing, and it answers "is
everything actually in place?" in about 30 seconds — instead of finding out halfway through
Stage F.

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh
```

If you haven't copied it across yet:

```bash
scp scripts/k3s-backup-preflight.sh <user>@45.90.98.51:/tmp/
sudo install -m 0750 -o root -g root /tmp/k3s-backup-preflight.sh /usr/local/sbin/
```

### What it checks

| Section | What it confirms |
|---------|------------------|
| A — Tooling | `aws`, `tar`, `python3` + its sqlite module, `flock`, disk space, and that the K3s binary reports a version |
| B — Config | `backup.env` exists, is `600 root:root`, has every required setting, and that `KMS_KEY_ID` is a full ARN and not a bare key id |
| C — AWS | The login works, the bucket exists, public access is blocked, versioning is on, default encryption is SSE-KMS, the KMS key is reachable — **and it does a real 64 MB upload** |
| D — K3s data | Every file the backup reads exists, the token permissions are right, and the database passes an integrity check (read-only) |
| E — Namespaces | A table of what's actually running in every namespace, and which namespaces hold data on disk |
| F — Coverage | A plain list of what today's backup does **not** recover |

### Why the 64 MB upload matters

Section C deliberately uploads a large file, not just a small one. A small upload is single-part
and needs fewer permissions; anything over 8 MB becomes a **multi-part** upload, which is what our
64 MB database backup actually uses. Testing only with a small file passes and hides the problem
until the first real backup ([#21](../../../issues/21)).

### Reading the result

| Exit | Meaning |
|------|---------|
| `0` — READY | Everything checks out. Go to Stage E's dry run |
| `2` — READY, with warnings | Safe to proceed, but read the warnings — some mean a future failure would go unnoticed |
| `1` — NOT READY | Blocking problems. **Don't run the backup script.** Every failure prints the exact command to fix it |

### Useful options

```bash
sudo ./k3s-backup-preflight.sh --no-aws      # local checks only, before AWS exists
sudo ./k3s-backup-preflight.sh --no-upload   # AWS checks without the 64 MB test upload
```

> Run this **before Stage C too**, with `--no-aws`. It'll tell you what's missing locally, so you
> aren't creating AWS resources only to discover the server can't use them.

> The test files it uploads land in `s3://<bucket>/_preflight/` with fixed names, so repeat runs
> overwrite rather than pile up. The backup login can't delete (by design), so clear them with an
> admin login when you're done, or let a lifecycle rule expire that prefix.

---

## Stage A — Double-check everything still matches `[node]`

Our whole plan is built on the facts in
[01 — Discovery Baseline](01-discovery-baseline.md). That was just a snapshot at one point in
time — let's confirm it's still true before building anything on top of it.

```bash
hostnamectl | head -3
k3s --version
systemctl is-active k3s && systemctl is-enabled k3s
```

```bash
df -h /
df -i /
```

```bash
sudo ls -la /var/lib/rancher/k3s/server/db/
sudo k3s etcd-snapshot ls 2>&1 | head -2
```

**Check:**

- Hostname should be `k3-master`, K3s version should be `v1.34.5+k3s1`, and the service should be
  both `active` and `enabled`.
- The main disk should have **at least 5 GB free**. We recorded 34 GB free during discovery —
  anything under 5 GB means stop right now and free up space first. Stage E temporarily uses
  about 100 MB, but a completely full disk on a live K3s server is its own separate emergency.
- The `db/` folder should contain `state.db`, `state.db-wal`, and `state.db-shm`.
- `etcd-snapshot ls` should still say `etcd datastore disabled` — confirming that we really do
  need the SQLite backup approach, not a K3s built-in snapshot.

> If the K3s version has changed since our discovery pass, update the version number in
> [01](01-discovery-baseline.md) before continuing. A restore needs the *exact matching* K3s
> version — an outdated version number in our docs would cause a restore to fail later.

---

## Stage B — Fill in the read-only unknowns `[node]`

These commands don't change anything on the server. They help us answer the open questions
[#8](../../../issues/8), [#4](../../../issues/4), and [#13](../../../issues/13) from
[05 — Gaps](05-gaps-and-open-questions.md), all of which affect exactly what Stage E needs to
back up.

### B.1 — List what's inside `server/tls/` and `server/cred/` (closes gap 9)

> 🔒 **Only list file names and permissions. Never open or read these files.** Their actual
> contents are the cluster's private keys.

```bash
sudo find /var/lib/rancher/k3s/server/tls  -printf '%M %u:%g %10s %p\n' | sort -k4
sudo find /var/lib/rancher/k3s/server/cred -printf '%M %u:%g %10s %p\n' | sort -k4
sudo du -sh /var/lib/rancher/k3s/server/tls /var/lib/rancher/k3s/server/cred
```

**Check:** every file listed should be inside `tls/`, `cred/`, or one of their subfolders. Our
Stage E backup grabs both folders completely, so if you spot anything *outside* those two
folders that looks like it's part of the cluster's identity (a stray `.key`, `.crt`, or
`-ca.` file sitting directly under `server/`), write it down as a new finding in
[05](05-gaps-and-open-questions.md) and make sure Stage E's backup covers it too.

```bash
# anything identity-related sitting loose directly under server/
sudo find /var/lib/rancher/k3s/server -maxdepth 1 -type f -printf '%M %10s %p\n'
```

While you're here, also write down **when the certificates expire** ([#19](../../../issues/19)). This
reads expiry dates only — it never opens any private key:

```bash
for c in /var/lib/rancher/k3s/server/tls/*.crt; do
  printf '%-58s ' "$(basename "$c")"
  sudo openssl x509 -enddate -noout -in "$c" 2>/dev/null || echo "couldn't read"
done
```

**Check:** you should see two clear groups, and the gap between them is the whole point:

| Certificate | How far out it should expire |
|-------------|------------------------------|
| Anything ending in `-ca.crt` (the master certificates) | Roughly **10 years** away |
| Everything else (the everyday certificates) | Roughly **1 year** away |

Write both dates into [01](01-discovery-baseline.md). They matter during a restore: if we ever
restore a backup that's older than the *everyday* certificate expiry, K3s throws certificate errors
on startup and then **fixes them itself**, reissuing from the still-valid master certificate.
Knowing the real dates is what lets whoever's doing the restore tell that apart from a genuinely
broken identity — see
[03, step 6](03-restore-runbook.md#certificate-errors-the-normal-kind-vs-the-real-problem).

> If any of the **master** certificates are within about a year of expiring, stop and raise it.
> That's a problem with the live cluster, not with our backups, and it will not fix itself.

### B.1a — Is secrets-encryption turned on? (read-only)

K3s can optionally encrypt Kubernetes Secrets *inside* its own database. If that's switched on,
there's a key file — `cred/encryption-config.json` — **without which every Secret in a restored
database is unreadable**.

```bash
sudo ls -la /var/lib/rancher/k3s/server/cred/
sudo k3s secrets-encrypt status 2>&1 | head -5
```

**Check:** we're only answering "is it on or off?"

| What you see | What it means | What to do |
|--------------|---------------|------------|
| `Encryption Status: Enabled` | Secrets are encrypted in the database | Note it in [01](01-discovery-baseline.md). `cred/` becomes **the** most critical thing we back up — it's already covered by our Stage E backup, but a restore must confirm `encryption-config.json` is in place *before* starting K3s |
| `Encryption Status: Disabled` | Secrets sit in the database as plain text | Note it. Our S3 bucket encryption and careful handling of `state.db` are then the *only* things protecting them |
| Command not found / errors | Older or restricted setup | Just record whether `encryption-config.json` exists in the listing above |

> Either answer is fine — we back up `cred/` completely regardless. This is about knowing how
> loudly to flag it, and what a restore has to double-check.

### B.1b — Does node-exporter actually exist, and where does it read from? ([#22](../../../issues/22))

Our backup script writes a "last successful backup" metric into a folder on the server:
`/var/lib/node_exporter/textfile_collector`. If nothing is reading that folder, the metric is
written into the void — and the alerting we're planning in Phase 3 would be built on something
that silently does nothing. (This is exactly why
[02 §8](02-backup-strategy.md#8-knowing-it-works) makes the primary alert the *age of the newest
object in S3* instead: that proves the backup arrived, whatever node-exporter turns out to be.)

Discovery never confirmed node-exporter is even installed, so let's find out:

```bash
# is it running directly on the server?
systemctl list-units --all --no-pager | grep -i node.exporter
ls -la /var/lib/node_exporter/textfile_collector 2>&1 | head -3
```

```bash
# or is it running inside the cluster?
sudo k3s kubectl get ds,deploy -A | grep -i node-exporter
```

```bash
# if it's in the cluster, does it mount a folder from the server for text files?
sudo k3s kubectl get ds -A -o yaml 2>/dev/null \
  | grep -i -A3 'textfile\|node-exporter' | head -30
```

**Check** — write down which of these is true:

| What you find | What it means for alerting |
|---------------|----------------------------|
| Running on the server, with that folder present | Good. Confirm the exact folder and set `TEXTFILE_DIR` in `backup.env` explicitly rather than trusting our guessed default |
| Running in the cluster, no server folder mounted | The metric goes nowhere. Phase 3 needs a different approach — see [#22](../../../issues/22) |
| Not installed at all | Same conclusion: the metric hook does nothing today |

> Worth considering either way: instead of trusting the script to report its own success, we could
> alert on **how old the newest file in S3 is**. That checks the backup genuinely *arrived*, not
> just that the script thought it finished. Record your finding on [#22](../../../issues/22).

### B.2 — Find out where our HTTPS certificates actually come from (closes gap 2)

```bash
sudo k3s kubectl get ingress,ingressroute -A
sudo k3s kubectl get secrets -A --field-selector type=kubernetes.io/tls
```

```bash
sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -i -B2 -A4 'acme\|certresolver\|entryPoint'
sudo k3s kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].spec.volumes[*].name}{"\n"}'
```

**Check:** you're really just trying to answer one question here — *if there's an `acme.json`
file (the certificate storage Traefik might use automatically), where does it actually live?*

| What you see | What it means | What to do |
|--------------|---------|--------|
| HTTPS Secrets exist, no automatic-certificate setup | Certificates are stored as regular Kubernetes Secrets | ✅ Already covered by Velero (Phase 2). Note this in [05](05-gaps-and-open-questions.md) and close gap #4. |
| Automatic-certificate setup found, storage is temporary (`emptyDir`) | The certificate data disappears if the pod restarts | 🚨 This is **not backed up at all** right now. A restore would produce a website with no valid HTTPS certificate. Flag this before Phase 2. |
| Automatic-certificate setup found, storage is a real data volume | The certificate data is saved to disk | ✅ Already covered by Phase 2's Velero backup — but double check that specific data volume is included in the schedule. |
| No HTTPS setup found at all here | Certificates are handled somewhere upstream of this server | Write down where exactly it's handled. |

### B.3 — Confirm real hardware vs. a virtual machine (mostly resolved already — gap 1)

We already know the hosting provider is **Datalix**, and we're treating this as an on-premise
server with **no** snapshot safety net available. This command just double-checks whether we're
on real hardware or inside a virtual machine — it doesn't change anything about our plan either
way, but it's good to know:

```bash
systemd-detect-virt
```

**Check:** `none` means real hardware; anything else names which virtualization software we're
running inside. Either way, there's no hosting-provider snapshot to fall back on — already
written down in
[01 §17](01-discovery-baseline.md#17-who-hosts-this-server--not-fully-confirmed-at-first-later-resolved). This closes
gap #13.

### B.4 — Confirm we can do a safe SQLite backup (Phase 0 item)

```bash
python3 -c "import sqlite3; print('python sqlite3 module OK, sqlite', sqlite3.sqlite_version)"
```

**Check:** this should print a version number. If it does, **you don't need to install
anything** — Python's built-in `sqlite3` module has the exact same safe backup feature as the
separate command-line tool. This keeps Phase 0 free of installing any new software on a
production server.

Only if this fails:

```bash
sudo apt-get update && sudo apt-get install -y sqlite3
```

> Installing `sqlite3` this way doesn't touch K3s at all, but it would still be the only new
> software installed anywhere in this whole guide. Try the Python approach first.

### B.5 — Note which container images we depend on (informational)

```bash
sudo k3s kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sed '/^$/d' | sort -u
```

**Check:** a list of unique images, roughly matching the apps in
[01 §13](01-discovery-baseline.md#13-argocd-deploys-our-apps-automatically-from-git).

> This used to be saved as its own backup job and its own S3 folder. It isn't any more: Velero
> stores every workload spec and each spec names its image, and `registries.yaml` (where to pull
> them from) is in job 1's archive. Running this by hand is still a useful sanity check — it just
> isn't something we need to store daily.

---

## Stage C — Set up AWS `[local]`

Run all of these from your own laptop, using your admin AWS login. **Nothing in this stage
touches `k3-master` at all.**

The order matters here: we create the encryption key first, because
[bucket security](02-backup-strategy.md#bucket-security--not-optional) depends on it — turning on
encryption later does **not** apply to files already uploaded before that point. The bucket needs
to be encrypted from its very first file.

### C.0 — Pick a region (just one line to change, any of these work)

A "region" is simply **which physical AWS data center will store our files**. AWS requires you
to pick one when creating a bucket — there's no such thing as a region-less bucket. It **can't be
changed later** — moving regions means creating a brand new bucket and copying everything over.

Our daily upload is only about 320 MB, so speed isn't really a factor here. Pick based on cost and
on where our team (and any legal/compliance requirements) actually are:

| Region | Code | Good choice when... |
|--------|------|-----------|
| Mumbai | `ap-south-1` | Our team is in India. **This is our current default.** |
| N. Virginia | `us-east-1` | This is AWS's cheapest region. Has one small quirk, noted below. |
| Frankfurt | `eu-central-1` | Closest to where our Datalix server actually is; keeps data inside the EU if that matters for compliance. |

Set this once using the variable block above. **Nothing else in this guide changes** — every
command below just reads from `$REGION`:

```bash
export REGION=ap-south-1     # or us-east-1, or eu-central-1
```

> **Why we're sending this data off-site at all:** our server is on-premise with no
> hosting-provider snapshot feature
> (Datalix, treated as on-premise — [05](05-gaps-and-open-questions.md#closed-by-the-simplified-design)).
> A backup that only lives on `k3-master` itself dies right along with `k3-master`. This S3
> bucket is the only copy that would survive a disk failure, a fire, or theft — that's the entire
> reason it needs to be somewhere else, not because we specifically prefer AWS.
>
> S3 is just the destination we picked, as explained in
> [02 §2](02-backup-strategy.md#2-where-it-all-goes). Any off-server location would satisfy this
> requirement — only the upload step inside
> [`k3s-server-backup.sh`](../scripts/k3s-server-backup.sh) would need to change. What's **not**
> acceptable is a destination on the same machine — including the MinIO storage running inside
> our own cluster, since that lives on the exact same disk we're trying to protect against.

### C.1 — Create a dedicated encryption key

```bash
KEY_ID=$(aws kms create-key \
  --region "$REGION" \
  --description "k3-master DR backup encryption (cluster CA, tokens, K8s Secrets)" \
  --key-usage ENCRYPT_DECRYPT \
  --key-spec SYMMETRIC_DEFAULT \
  --query KeyMetadata.KeyId --output text)
echo "$KEY_ID"

aws kms create-alias --region "$REGION" \
  --alias-name alias/k3-master-dr --target-key-id "$KEY_ID"

KEY_ARN=$(aws kms describe-key --region "$REGION" --key-id "$KEY_ID" \
  --query KeyMetadata.Arn --output text)
echo "$KEY_ARN"
```

```bash
aws kms enable-key-rotation --region "$REGION" --key-id "$KEY_ID"
```

**Check:**

```bash
aws kms describe-key --region "$REGION" --key-id alias/k3-master-dr \
  --query 'KeyMetadata.{State:KeyState,Manager:KeyManager,Spec:KeySpec}'
aws kms get-key-rotation-status --region "$REGION" --key-id "$KEY_ID"
```

You should see `State: Enabled`, `Manager: CUSTOMER`, and rotation set to `true`.

> Write down `$KEY_ARN` somewhere outside of AWS. **If this key is ever deleted, every backup
> encrypted with it becomes permanently unreadable** — including the exact backups you'd be
> trying to restore from during an emergency.

### C.2 — Create the S3 bucket

```bash
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi
```

> This is written as an `if` statement on purpose: `us-east-1` is the one region that **rejects**
> the extra `--create-bucket-configuration` flag, while every other region **requires** it.
> Pasting this exact block works no matter which region you picked.

> Bucket names have to be **globally unique across all of AWS**, so if `k3-master-dr` is already
> taken by someone else, this command will fail with `BucketAlreadyExists`. If that happens, use
> something like `k3-master-dr-<yourorg>` instead and update `$BUCKET` — every later command
> reads that variable, so that's the only change you'd need to make.

### C.3 — Block all public access, before anything gets uploaded

```bash
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### C.4 — Turn on file history (versioning)

```bash
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

### C.5 — Turn on default encryption

```bash
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration "{
    \"Rules\": [{
      \"ApplyServerSideEncryptionByDefault\": {
        \"SSEAlgorithm\": \"aws:kms\",
        \"KMSMasterKeyID\": \"$KEY_ARN\"
      },
      \"BucketKeyEnabled\": true
    }]
  }"
```

### C.6 — Add a bucket rule that blocks unencrypted uploads and the wrong key

```bash
cat > /tmp/k3-dr-bucket-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DenyInsecureTransport",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::$BUCKET", "arn:aws:s3:::$BUCKET/*"],
      "Condition": { "Bool": { "aws:SecureTransport": "false" } }
    },
    {
      "Sid": "DenyUnencryptedObjectUploads",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET/*",
      "Condition": {
        "StringNotEquals": { "s3:x-amz-server-side-encryption": "aws:kms" }
      }
    },
    {
      "Sid": "DenyWrongKmsKey",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::$BUCKET/*",
      "Condition": {
        "StringNotEquals": {
          "s3:x-amz-server-side-encryption-aws-kms-key-id": "$KEY_ARN"
        }
      }
    }
  ]
}
EOF

aws s3api put-bucket-policy --bucket "$BUCKET" --policy file:///tmp/k3-dr-bucket-policy.json
```

**Check for all of C.2 through C.6 together:**

```bash
aws s3api get-public-access-block --bucket "$BUCKET"
aws s3api get-bucket-versioning  --bucket "$BUCKET"
aws s3api get-bucket-encryption  --bucket "$BUCKET"
aws s3api get-bucket-policy      --bucket "$BUCKET" --query Policy --output text | head -c 400; echo
```

All four blocking settings should say `true`; versioning should say `Enabled`; encryption should
show `aws:kms` with your key's ARN; and the policy should be there.

### C.6a — Retention rules, so the bucket doesn't grow forever

Set these up **now**, while you're already in the bucket settings. Without them nothing is ever
deleted, and versioning means even overwrites pile up.

A lifecycle rule can only say *"delete N days after upload"*. That single limitation is the whole
reason job 1 writes into two folders: `k3s/daily/` every day, and `k3s/weekly/` on Sundays as well.
Two folders, two rules, and we get 7 daily + 4 weekly restore points.

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
      "Expiration": { "Days": 2 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 1 } },

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

**Check:**

```bash
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[].{ID:ID,Prefix:Filter.Prefix,Days:Expiration.Days}' --output table
```

> ### 🚨 There is deliberately **no rule for `velero/`**
>
> Velero's file-system backups live in a Kopia repository whose objects reference each other, and
> Velero expires them itself using the `ttl` on each Schedule. An S3 expiry rule would delete chunks
> that a still-valid backup depends on — and the corruption only shows up when you try to restore.
> **Never add a current-version expiry on `velero/`.** If you want a safety net there, use a
> *noncurrent* version expiry only.

The other two rules are worth understanding rather than just pasting:

| Rule | Why it's there |
|------|----------------|
| `abort-stuck-uploads` | Our `state.db` upload is multi-part. If one dies halfway, the uploaded chunks sit there costing money and are invisible to `aws s3 ls`. This cleans them up. |
| `NoncurrentVersionExpiration` | Versioning is on, and job 1 uses fixed filenames inside a dated folder — so a re-run on the same day *does* create a noncurrent version. Two days is enough to recover from a bad overwrite without keeping them forever. |

> The `_preflight/` rule tidies up after the preflight checker's test uploads, since the backup
> login can't delete them itself.

### C.7 — Create the least-privilege login that lives on the server

```bash
aws iam create-user --user-name k3-master-backup-writer
```

```bash
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
      "Sid": "WriteBackups",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"],
      "Resource": "arn:aws:s3:::$BUCKET/*"
    },
    {
      "Sid": "VeleroExpiresItsOwnBackups",
      "Effect": "Allow",
      "Action": ["s3:DeleteObject"],
      "Resource": "arn:aws:s3:::$BUCKET/velero/*"
    },
    {
      "Sid": "UseTheDrKeyForBackupUploads",
      "Effect": "Allow",
      "Action": ["kms:Encrypt", "kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"],
      "Resource": "$KEY_ARN"
    }
  ]
}
EOF

aws iam put-user-policy --user-name k3-master-backup-writer \
  --policy-name k3-master-dr-write --policy-document file:///tmp/k3-dr-writer-policy.json
```

```bash
aws iam create-access-key --user-name k3-master-backup-writer \
  --query 'AccessKey.{Id:AccessKeyId,Secret:SecretAccessKey}' --output table
```

> Notice this login **cannot delete anything under `k3s/`**. A login that lives on a production
> server and can only ever *add* files there is a login a hacked server can't use to destroy our
> existing backups. Expiring old `k3s/` backups is handled entirely by S3's own lifecycle rules
> (C.6a) — never by this login.

> ⚠️ **Why `s3:DeleteObject` on `velero/` is not optional**
>
> Velero expires its own backups using the `ttl` on each Schedule — TTL expiry *is* Velero issuing
> deletes. Without this statement nothing under `velero/` ever expires, and the "7 daily + 4
> weekly" retention becomes fiction while the bucket grows forever. Velero also can't clean up
> after a failed backup, leaving partial data behind.
>
> It's scoped to `velero/*` on purpose. That prefix is Velero's own repository, which it must
> manage; the K3s artifacts under `k3s/` stay undeletable by anything on the server.
>
> **Do not "harden" this by removing it.** If you want to verify the blast radius is what you
> think it is, the check in Stage D.3 already proves a delete against `k3s/` is denied.

> ⚠️ **Why `kms:Decrypt` is in that list, even though it looks wrong** ([#21](../../../issues/21))
>
> It's tempting to leave `kms:Decrypt` out — "the backup only ever writes, so why let it decrypt?"
> That breaks the backup, for a non-obvious reason.
>
> The `aws s3 cp` command automatically switches to a **multi-part upload** for anything over
> 8 MB, and our database backup is around 64 MB. Multi-part uploads to an encrypted bucket need
> `kms:Decrypt` as well as `kms:GenerateDataKey`. Without it, every database upload fails with
> `AccessDenied` — an error that reads like an S3 permissions problem and sends you looking in
> completely the wrong place.
>
> It also doesn't actually widen access: this login already has `s3:GetObject` above, so it could
> read backups either way. The restrictions that genuinely matter — **no delete outside
> `velero/`**, only this one encryption key, and bucket versioning turned on — are all still in
> place.

Save the access key ID and secret somewhere safe right now — the secret is only shown once. They
go into `/etc/k3s-backup/backup.env` in Stage D, and nowhere else. **Never commit them to this
repo.**

### C.8 — Create a separate, restore-only login, and store it offline

```bash
aws iam create-user --user-name k3-master-restore-reader

cat > /tmp/k3-dr-reader-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketVersions"],
      "Resource": "arn:aws:s3:::$BUCKET"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::$BUCKET/*"
    },
    {
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:DescribeKey"],
      "Resource": "$KEY_ARN"
    }
  ]
}
EOF

aws iam put-user-policy --user-name k3-master-restore-reader \
  --policy-name k3-master-dr-read --policy-document file:///tmp/k3-dr-reader-policy.json

aws iam create-access-key --user-name k3-master-restore-reader \
  --query 'AccessKey.{Id:AccessKeyId,Secret:SecretAccessKey}' --output table
```

**Check:**

```bash
aws iam list-user-policies --user-name k3-master-backup-writer
aws iam list-user-policies --user-name k3-master-restore-reader
```

Store the **reader** login somewhere safe, like a password manager or offline vault. Per
[02 §2](02-backup-strategy.md#bucket-security--not-optional), it must **never** be placed on
`k3-master`. Also assign a named person to be responsible for rotating this
([gap 7](05-gaps-and-open-questions.md#7-nobody-owns-rotating-the-s3-credentials), every 90 days)
right now, rather than putting it off until Phase 5 — it only takes a few seconds while you're
already setting this up.

```bash
rm -f /tmp/k3-dr-*.json
```

---

## Stage D — Put the login on the server and prove it can reach S3 `[node]`

### D.1 — Create the config folder

```bash
sudo install -d -m 0700 -o root -g root /etc/k3s-backup
```

### D.2 — Write the `backup.env` config file

```bash
sudo install -m 0600 -o root -g root /dev/null /etc/k3s-backup/backup.env
sudo nano /etc/k3s-backup/backup.env
```

Fill it in with your real values:

```ini
S3_BUCKET=k3-master-dr
AWS_REGION=<your-region>
KMS_KEY_ID=<the KEY_ARN from step C.1>
AWS_ACCESS_KEY_ID=<from step C.7>
AWS_SECRET_ACCESS_KEY=<from step C.7>
```

**Check:**

```bash
sudo stat -c '%a %U:%G %n' /etc/k3s-backup /etc/k3s-backup/backup.env
```

This should say `700 root:root` and `600 root:root`. Anything readable by other users here is a
real problem to fix immediately — this file holds write access to the bucket containing our
cluster's master certificate.

### D.3 — Prove the connection actually works, with a throwaway test file

```bash
set -a; . /etc/k3s-backup/backup.env; set +a
export AWS_DEFAULT_REGION="$AWS_REGION"

echo "k3-master egress test $(date -u +%FT%TZ)" > /tmp/k3-egress-test.txt

sudo -E aws s3 cp /tmp/k3-egress-test.txt "s3://$S3_BUCKET/_egress-test/" \
  --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID"
```

**Check — this proves our whole Stage C setup actually works end-to-end:**

```bash
sudo -E aws s3api head-object --bucket "$S3_BUCKET" --key "_egress-test/k3-egress-test.txt" \
  --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId,Size:ContentLength}'
```

You should see `SSE: aws:kms` and your key's ARN. If it says `AES256` or nothing at all, the
bucket's default encryption or its policy didn't apply properly — go back and fix C.5/C.6 before
uploading anything real.

#### Now repeat it with a *large* file — this part is not optional

The test above uploaded about 50 bytes. That's a **single-part** upload, and it does **not**
exercise the same code path our real backup uses ([#21](../../../issues/21)).

Anything over 8 MB is uploaded by `aws s3 cp` as a **multi-part** upload, which needs an extra
permission (`kms:Decrypt`). Our database backup is around 64 MB, so it always takes that path. If
we only ever tested with a tiny file, we'd get a green light here and then a confusing
`AccessDenied` failure later at Stage F — during the first real backup.

```bash
# if this is a new shell since D.3 started, load the config again first:
set -a; . /etc/k3s-backup/backup.env; set +a

# 64 MB of zeros, roughly the size of our real database backup
dd if=/dev/zero of=/tmp/k3-egress-big.bin bs=1M count=64 status=none

sudo -E aws s3 cp /tmp/k3-egress-big.bin "s3://$S3_BUCKET/_egress-test/" \
  --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID"
```

**Check:**

```bash
sudo -E aws s3api head-object --bucket "$S3_BUCKET" --key "_egress-test/k3-egress-big.bin" \
  --query '{SSE:ServerSideEncryption,Size:ContentLength}'
```

Expect `SSE: aws:kms` and a size of `67108864`.

> If **this** upload fails with `AccessDenied` while the small one succeeded, the cause is almost
> certainly a missing `kms:Decrypt` in the backup login's permissions. Go back to
> [C.7](#c7--create-the-least-privilege-login-that-lives-on-the-server) and confirm it's in the
> list. This is exactly the failure this larger test exists to catch early.

```bash
rm -f /tmp/k3-egress-big.bin
```

Now let's confirm our safety limits actually work — **both of the following must fail:**

```bash
set -a; . /etc/k3s-backup/backup.env; set +a

# should be blocked: this login cannot delete anything outside velero/
sudo -E aws s3api delete-object --bucket "$S3_BUCKET" --key "_egress-test/k3-egress-test.txt"
```

```bash
# should be blocked: uploading without encryption
sudo -E aws s3api put-object --bucket "$S3_BUCKET" --key "_egress-test/plaintext.txt" \
  --body /tmp/k3-egress-test.txt
```

Both of these should return `AccessDenied`. If either one actually succeeds, our least-privilege
setup isn't actually working — go back and fix it.

**And one that must *succeed*** — this is the permission Velero needs to expire its own backups,
and the one people remove by mistake while "hardening" the policy:

```bash
sudo -E aws s3 cp /tmp/k3-egress-test.txt "s3://$S3_BUCKET/velero/_permcheck.txt" \
  --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID"
sudo -E aws s3api delete-object --bucket "$S3_BUCKET" --key "velero/_permcheck.txt"
```

If that delete returns `AccessDenied`, Velero will never expire a backup and the "7 daily +
4 weekly" retention silently becomes "keep everything forever". Add the `VeleroExpiresItsOwnBackups`
statement from C.7 before going any further.

Clean up from `[local]` using your admin login:

```bash
aws s3 rm "s3://$BUCKET/_egress-test/" --recursive
rm -f /tmp/k3-egress-test.txt   # on the server
```

> Since versioning is turned on, that `rm` command just adds a "delete marker" rather than
> permanently erasing anything — that's expected and intentional.

---

## Stage E — Install the backup script and do a test run `[node]`

The script itself is [`scripts/k3s-server-backup.sh`](../scripts/k3s-server-backup.sh) in this
repo. Copy it over **from the repo**, don't just paste it into a text editor directly on the
server — the repo is our one true copy, per our working agreement.

### E.1 — Copy it onto the server

From `[local]`, inside your own clone of this repo:

```bash
scp scripts/k3s-server-backup.sh <user>@45.90.98.51:/tmp/
scp scripts/systemd/k3s-backup.service scripts/systemd/k3s-backup.timer <user>@45.90.98.51:/tmp/
```

Then on `[node]`:

```bash
sudo install -m 0750 -o root -g root /tmp/k3s-server-backup.sh /usr/local/sbin/k3s-server-backup.sh
sudo install -m 0644 -o root -g root /tmp/k3s-backup.service /tmp/k3s-backup.timer /etc/systemd/system/
sudo install -d -m 0700 -o root -g root /var/backups/k3s
```

**Check:**

```bash
bash -n /usr/local/sbin/k3s-server-backup.sh && echo "syntax OK"
sudo /usr/local/sbin/k3s-server-backup.sh db 2>&1 | head -3   # should refuse: there are no modes any more
```

### E.2 — Write down the current state, so we can prove nothing changed

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
sudo ls -la /var/lib/rancher/k3s/server/db/
```

Save this output somewhere — Stage F will compare against it.

### E.3 — Test run: build every backup file, but upload nothing

```bash
sudo DRY_RUN=1 /usr/local/sbin/k3s-server-backup.sh
```

**Check:**

```bash
sudo ls -lah /var/backups/k3s/*/
```

You should see exactly four artifacts, each with a `.sha256` next to it:

| File | Roughly how big |
|----------|---------------|
| `state.db` | ~60–90 MB |
| `k3s-identity.tar.gz` | small — a few hundred KB |
| `node-config.tar.gz` | ~1 MB |
| `MANIFEST.json` | a few KB |
| a `.sha256` fingerprint file next to each one | ~100 bytes |

Filenames carry no timestamp on purpose — the dated folder is the timestamp, so a re-run on the
same day replaces that day's set cleanly instead of leaving half-matched files behind.

In the script's own output you should see `snapshot ok (read-only), integrity_check=ok`, followed
by a line like `manifest: k3s=v1.34.5+k3s1 os=... artifacts=3`.

Check the manifest actually recorded a real version — this is the file a restore reads first:

```bash
sudo python3 -m json.tool /var/backups/k3s/*/MANIFEST.json | head -20
```

> If `k3s_version` says `unknown`, the script couldn't read `/usr/local/bin/k3s`. Fix that before
> going any further — a manifest without a version defeats the entire point of having one
> ([#17](../../../issues/17)).

> If you instead see `WARNING: read-only open failed ... using query_only fallback`, the backup
> is still safe — the connection is still locked to read-only at the database level — but make a
> note of it, since it means this server's live-writing behavior is slightly different than we
> expected.

Now confirm K3s is exactly where you left it:

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
```

`ActiveEnterTimestamp` and `NRestarts` **must exactly match what you saw in E.2**. This is our
actual proof that this whole phase caused zero downtime.

### E.4 — Clean up the test files

```bash
sudo rm -rf /var/backups/k3s/*/
df -h /
```

---

## Stage F — Do the first real backup `[node]`

One run, one folder. The 64 MB `state.db` is the file that exercises the multipart upload path, so
if the login is wrong you find out immediately rather than later.

```bash
sudo /usr/local/sbin/k3s-server-backup.sh
```

**Check:**

```bash
set -a; . /etc/k3s-backup/backup.env; set +a
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/" --recursive --human-readable
```

You should see one dated folder holding the complete set, each file with a matching `.sha256`:

```text
k3s/daily/2026-08-18/state.db
k3s/daily/2026-08-18/k3s-identity.tar.gz
k3s/daily/2026-08-18/node-config.tar.gz
k3s/daily/2026-08-18/MANIFEST.json
```

**That folder is a complete restore set.** There is nothing to correlate across prefixes and no
pairing to work out — a restore picks a date and takes everything in it.

If today is a Sunday you'll see the same four files under `k3s/weekly/2026-08-18/` as well. That's
the retention design, not a duplicate bug: two prefixes so two lifecycle rules can express
7 daily + 4 weekly.

You *won't* see `velero/` yet — that's [Phase 2](04-implementation-todo.md#phase-2--job-2-velero),
and until it exists no PVC data and no single deleted object can be restored.

And once again, the thing that actually matters most:

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A | grep -v Running | head
```

You should see: the restart count unchanged, the node still `Ready`, and only the four
already-known-broken demo apps from
[01 §13](01-discovery-baseline.md#13-argocd-deploys-our-apps-automatically-from-git) — `demo-app`, `nginx-app`, `nginx-app-dev`,
`nginx-app11`. **Those were already broken before you started — ignore them, don't chase them
down.**

---

## Stage G — Prove the backup can actually be restored `[local]`

The last item in Phase 1 is *"confirm a full run produces the expected files"* — but seeing a
green checkmark isn't proof of that. Let's actually check, from your own laptop, using the
**restore-reader** login from step C.8 — this also happens to prove that login actually works,
before you'd ever need it in a real emergency.

```bash
export AWS_ACCESS_KEY_ID=<reader key>
export AWS_SECRET_ACCESS_KEY=<reader secret>
export AWS_DEFAULT_REGION="$REGION"
mkdir -p ~/k3-restore-check && cd ~/k3-restore-check

# one folder = one complete restore set. Pick the newest date and take all of it.
DATE=$(aws s3 ls "s3://$BUCKET/k3s/daily/" | awk '{print $2}' | tr -d '/' | sort | tail -1)
echo "restoring from $DATE"
aws s3 cp "s3://$BUCKET/k3s/daily/$DATE/" . --recursive
ls -lah
```

**Check the manifest is there and usable ([#17](../../../issues/17))**

This is the file a real restore opens first, so let's prove it works *before* we need it:

```bash
python3 - MANIFEST.json <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("K3s version :", d["k3s_version"])
print("OS          :", d["os_release"])
print("Files       :", d["artifact_count"])
assert d["k3s_version"] != "unknown", \
    "manifest has no K3s version - fix this before relying on these backups"
for a in d["artifacts"]:
    print(f"  {a['filename']:24} {a['bytes']:>12,}  {a['sha256'][:16]}...")
PY
```

**Check — every fingerprint still matches after the download:**

```bash
sha256sum -c ./*.sha256
LATEST=state.db
```

That one command verifies the whole set. It's also exactly what
[restore step 1](03-restore-runbook.md#step-1--pick-a-backup-and-read-its-manifest) tells you to
run during a real outage — so if it works here, it works there.

**Check — this should be a valid, complete SQLite database, not a corrupted file:**

```bash
python3 - "$LATEST" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
print("integrity_check:", db.execute("PRAGMA integrity_check").fetchone()[0])
print("tables:", [r[0] for r in db.execute(
    "SELECT name FROM sqlite_master WHERE type='table'")])
print("kine rows:", db.execute("SELECT count(*) FROM kine").fetchone()[0])
PY
```

You should see `integrity_check: ok`, a table called `kine`, and a real, non-zero row count.
That row count is your proof this is actually a snapshot of the live cluster's data, not just an
empty shell.

**Check — the identity archive contains what a real restore would need:**

```bash
tar -tzf k3s-identity.tar.gz | head -40
tar -tzf k3s-identity.tar.gz | wc -l

# the six things that must be in there
for p in server/tls server/cred server/token server/manifests etc/rancher/k3s k3s.service; do
  tar -tzf k3s-identity.tar.gz | grep -q "$p" && echo "OK   $p" || echo "MISSING  $p"
done
```

Compare the `tls/` and `cred/` listings against what you found in step B.1 — it should be the exact
same set of files. The archive is rooted at `/`, so a restore is a single `tar -xzf ... -C /`.

```bash
cd ~ && rm -rf ~/k3-restore-check
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

> **A restore-time gotcha, worth remembering now:** the snapshot is one single, complete
> `state.db` file. When restoring, place it at
> `/var/lib/rancher/k3s/server/db/state.db` with **no `-wal` and no `-shm` file next to it**,
> while K3s is stopped. If you leave an old, stale `-wal` file from the fresh install sitting
> next to a restored snapshot, K3s can silently load the wrong data. This is
> [restore step 4](03-restore-runbook.md#step-4--restore-the-cluster-identity-and-the-datastore).

---

## Stage H — Turn on the automatic schedule `[node]`

Per [04, Phase 1](04-implementation-todo.md#phase-1--job-1-k3s-server-backup): we use a systemd
timer, matching how the server already schedules its one existing routine job. **No cron** — this
server doesn't currently have any scheduled root jobs set up through cron, and we want to keep it
that way.

The two unit files were already installed in E.1. Reload and validate:

```bash
sudo systemctl daemon-reload
sudo systemd-analyze verify /etc/systemd/system/k3s-backup.service
sudo systemctl cat k3s-backup.service | head -20
```

Test the scheduled job by hand once — this is exactly the path the timer will follow later:

```bash
sudo systemctl start k3s-backup.service
sudo systemctl status k3s-backup.service --no-pager
sudo journalctl -u k3s-backup.service -n 40 --no-pager
```

**Check:** `Main PID: ... (code=exited, status=0/SUCCESS)`, and the log ends with
`completed successfully`.

Only now, turn the schedule on:

```bash
sudo systemctl enable --now k3s-backup.timer
```

**Check:**

```bash
systemctl list-timers 'k3s-backup*' --all --no-pager
```

You should see `k3s-backup.timer` scheduled next at 02:15 UTC. That's 45 minutes ahead of the
Velero schedule you'll add in Phase 2, so the SQLite reader and Velero's node-agent are never on the
disk at the same time. The script also takes a lock, so a slow run can never overlap the next one.

---

## Stage I — Let it run for a while `[node]`, then close out the issues

Per [04, Phase 3](04-implementation-todo.md#phase-3--retention-and-alerting): **let this run on
its own for one full week before actually relying on it.**

Check daily, takes about 30 seconds:

```bash
systemctl list-timers 'k3s-backup*' --no-pager
journalctl -u k3s-backup.service --since '24 hours ago' --no-pager | tail -30
df -h /
```

```bash
set -a; . /etc/k3s-backup/backup.env; set +a
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/k3s/daily/" | tail -8
```

You should see **one new dated folder per day**, and one more under `k3s/weekly/` after the first
Sunday.

> Every `aws` command in this document needs that `set -a; . backup.env; set +a` line first — it is
> what puts the credentials and bucket name into the shell. Without it you get
> `Unable to locate credentials`, which looks like a permissions problem and isn't.

Also keep an eye on, specifically:

- **How much free disk space is left.** The script deletes anything older than 3 days from its
  staging area and refuses to run at all if less than 2 GB is free — but a new job on a disk that's
  already 64% full deserves a week of attention.
- **How much is piling up in S3.** If you set up the two lifecycle rules in C.6a, this stays flat
  at roughly 1 GB. If you skipped them, nothing is ever deleted and versioning means overwrites
  pile up too — at ~90 MB a day that's ~2.7 GB/month, growing without limit. See
  [02 §6](02-backup-strategy.md#6-retention--7-daily--4-weekly).

  > **Decision made: no compression.** We upload the database snapshot uncompressed on purpose,
  > so it can be checked — and restored — directly, with no extra decompress step needed during
  > an actual outage. Compressing it would have cut storage use by roughly 3–5×, but we chose a
  > simpler, faster restore over saving on storage cost. We can revisit this if the AWS bill
  > becomes a real concern.

After a clean week with no problems:

- Tick every box in [04, Phase 0 and Phase 1](04-implementation-todo.md)
- Close issues [#9](../../../issues/9) and [#10](../../../issues/10)
- Update the status table in the [README](../README.md)
- Write down what you found in B.1/B.2/B.3 in [05](05-gaps-and-open-questions.md), and close
  [#8](../../../issues/8), [#4](../../../issues/4), [#13](../../../issues/13), [#5](../../../issues/5),
  [#6](../../../issues/6)
- Commit any changes you made to the script on the server back into `scripts/` in this repo

---

## If something goes wrong and you need to undo this

Nothing in phases 0–1 modifies K3s itself, so undoing any of this just means "remove what we
added."

| Stage | How to undo it |
|-------|-----------------|
| H | `sudo systemctl disable --now k3s-backup.timer` then `sudo rm /etc/systemd/system/k3s-backup.*` and `daemon-reload` |
| E–F | `sudo rm -f /usr/local/sbin/k3s-server-backup.sh; sudo rm -rf /var/backups/k3s` |
| D | `sudo rm -rf /etc/k3s-backup` — then disable the writer login: `aws iam delete-access-key --user-name k3-master-backup-writer --access-key-id <id>` |
| C | `aws s3 rm s3://$BUCKET --recursive`, `aws s3api delete-bucket --bucket $BUCKET`, delete both IAM users, then `aws kms schedule-key-deletion --key-id $KEY_ID --pending-window-in-days 30` |
| A–B | Nothing to undo — these steps only read information, never changed anything. |

**If a backup run ever seems to actually be affecting the server** (unlikely — it's set to run at
low priority, and it only ever reads from K3s's data, never writes to it):

```bash
sudo systemctl stop k3s-backup.service
sudo systemctl disable --now k3s-backup.timer
```

That stops the backup completely. It doesn't touch K3s at all. There's nothing to "undo" on the
K3s side, because the script never writes to it in the first place.

---

## What Phase 0 + 1 deliberately do **not** give us yet

Let's be honest about what's still missing while these phases are the only ones done:

| Not covered yet | Covered by | What that means right now |
|-----------------|-------------|-------------------|
| **PVC data** — the 6 monitoring volumes, ~7.8 GB | Phase 2 (Velero) | Prometheus/Loki/Grafana history is **not backed up at all**. A restore brings the monitoring stack back empty. |
| **Restoring one deleted object** | Phase 2 | No way to put back a single Deployment or Secret. The only lever is rolling the whole datastore back, which reverts everything else too. And because `local-path` deletes a volume's files the instant its PVC goes, an accidental `kubectl delete pvc` is **permanent** today. |
| **Restoring into a fresh or different-version cluster** | Phase 2 | Job 1's snapshot only helps when rebuilding **this** server at **this** K3s version. |
| Automatic cleanup of old backups | Phase 3 | Only if you skipped C.6a — otherwise this is already done. |
| Alerts when a backup fails | Phase 3 | The script writes a "last success" timestamp if node-exporter's textfile directory exists, but **nothing alerts on it yet**. A silently failing backup stays silent. |
| Ever actually testing a restore | Phase 4 | *A backup that's never been restored is a hope, not a plan.* |
| A fallback if a restore itself goes wrong | — | On-premise, **no hosting-provider snapshot** ([05](05-gaps-and-open-questions.md)). There's nothing behind the S3 bucket. |

Finishing Phase 1 means **job 1 works** — this server can be rebuilt. It does **not** mean we're
recoverable: half the design is job 2. Move on to [#11](../../../issues/11) next.
