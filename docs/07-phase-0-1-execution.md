# 07 — Phase 0 & 1: Step-by-Step Commands (safe to run in production)

This is the hands-on companion to [04 — Implementation TODO](04-implementation-todo.md), covering
phases [#9](../../issues/9) and [#10](../../issues/10). Every command below is meant to be typed
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
skip — see [02 §8](02-backup-strategy.md#8-what-is-explicitly-not-backed-up)). Our recovery plan
is: *set up a plain Ubuntu server, install the matching K3s version, then put K3s's own saved
state back on top of it.*

There's one deliberate exception worth calling out. The "full" backup run also grabs about 1 MB
of the server's OS-level settings — network settings, firewall rules, `/etc/ssh`, allowed logins,
timezone, and the list of installed packages. That's not technically K3s, but it's what turns
[restore step 2](03-restore-runbook.md#step-2--restore-node-level-os-configuration) from *"try to
remember the static IP and firewall rules from memory, during an actual outage"* into *"just
unpack this file."* This is part of
[Phase 1](04-implementation-todo.md#phase-1--node--cluster-state-backup-track-a) and closes gap
[#5](../../issues/5).

We recommend keeping this unless you have a specific reason not to. If you want a strictly
K3s-only backup, add this line to `/etc/k3s-backup/backup.env`:

```ini
BACKUP_NODE_CONFIG=0
```

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
[#8](../../issues/8), [#4](../../issues/4), and [#13](../../issues/13) from
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
[01 §17](01-discovery-baseline.md#17-hosting-provider--datalix-treated-as-on-premise). This closes
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

### B.5 — Try out the container image list feature (item 8)

```bash
sudo k3s kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sed '/^$/d' | sort -u
```

**Check:** you should get a list of unique container images, roughly matching the apps listed in
[01 §13](01-discovery-baseline.md#13-argocd). This is exactly what our backup script will save
automatically — running it by hand first means no surprises later.

---

## Stage C — Set up AWS `[local]`

Run all of these from your own laptop, using your admin AWS login. **Nothing in this stage
touches `k3-master` at all.**

The order matters here: we create the encryption key first, because
[gap 5](05-gaps-and-open-questions.md#5-secrets-reach-s3-unencrypted-unless-sse-kms-is-configured)
already told us that turning on encryption later doesn't apply to files already uploaded before
that point. The bucket needs to be encrypted from its very first file.

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
> ([gap 1](05-gaps-and-open-questions.md#1-hosting-provider--resolved-datalix-treated-as-on-premise)).
> A backup that only lives on `k3-master` itself dies right along with `k3-master`. This S3
> bucket is the only copy that would survive a disk failure, a fire, or theft — that's the entire
> reason it needs to be somewhere else, not because we specifically prefer AWS.
>
> S3 is just the destination we picked, as explained in
> [02 §5](02-backup-strategy.md#5-s3-storage-design). Any off-server location would satisfy this
> requirement — only the upload step inside
> [`k3s-track-a-backup.sh`](../scripts/k3s-track-a-backup.sh) would need to change. What's **not**
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
      "Sid": "UseTheDrKeyForEncryptOnly",
      "Effect": "Allow",
      "Action": ["kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"],
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

> Notice this login deliberately has **no ability to delete files, and no ability to decrypt**.
> A login that lives on a production server, and can only ever *add* encrypted files, is a login
> that a hacked server can't use to destroy or read our existing backups. Deleting old backups on
> a schedule is handled separately, by S3's own cleanup rules in Phase 4 — never by this login.

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
[02 §5](02-backup-strategy.md#5-s3-storage-design), it must **never** be placed on `k3-master`.
Also assign a named person to be responsible for rotating this
([gap #8](05-gaps-and-open-questions.md#8-no-named-owner-for-credential-rotation), every 90 days)
right now, rather than putting it off until Phase 6 — it only takes a few seconds while you're
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

Now let's confirm our safety limits actually work — **both of the following must fail:**

```bash
# should be blocked: this login can't delete files
sudo -E aws s3api delete-object --bucket "$S3_BUCKET" --key "_egress-test/k3-egress-test.txt"
```

```bash
# should be blocked: uploading without encryption
sudo -E aws s3api put-object --bucket "$S3_BUCKET" --key "_egress-test/plaintext.txt" \
  --body /tmp/k3-egress-test.txt
```

Both of these should return `AccessDenied`. If either one actually succeeds, our least-privilege
setup isn't actually working — go back and fix it. Clean up from `[local]` using your admin
login:

```bash
aws s3 rm "s3://$BUCKET/_egress-test/" --recursive
rm -f /tmp/k3-egress-test.txt   # on the server
```

> Since versioning is turned on, that `rm` command just adds a "delete marker" rather than
> permanently erasing anything — that's expected and intentional.

---

## Stage E — Install the backup script and do a test run `[node]`

The script itself is [`scripts/k3s-track-a-backup.sh`](../scripts/k3s-track-a-backup.sh) in this
repo. Copy it over **from the repo**, don't just paste it into a text editor directly on the
server — the repo is our one true copy, per our working agreement.

### E.1 — Copy it onto the server

From `[local]`, inside your own clone of this repo:

```bash
scp scripts/k3s-track-a-backup.sh <user>@45.90.98.51:/tmp/
scp scripts/systemd/k3s-backup@.service scripts/systemd/k3s-backup-db.timer \
    scripts/systemd/k3s-backup-full.timer <user>@45.90.98.51:/tmp/
```

Then on `[node]`:

```bash
sudo install -m 0750 -o root -g root /tmp/k3s-track-a-backup.sh /usr/local/sbin/k3s-track-a-backup.sh
sudo install -d -m 0700 -o root -g root /var/backups/k3s
```

**Check:**

```bash
bash -n /usr/local/sbin/k3s-track-a-backup.sh && echo "syntax OK"
sudo /usr/local/sbin/k3s-track-a-backup.sh 2>&1 | head -2   # this should show a usage error, as expected
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
sudo DRY_RUN=1 /usr/local/sbin/k3s-track-a-backup.sh full
```

**Check:**

```bash
sudo ls -lah /var/backups/k3s/*/
```

For a `full` run, you should see roughly these files:

| File | Roughly how big |
|----------|---------------|
| `state-*.db` | ~60–90 MB |
| `server-identity-*.tar.gz` | small — a few hundred KB |
| `config-*.tar.gz` | ~4 KB |
| `manifests-*.tar.gz` | ~20 KB |
| `node-config-*.tar.gz` | small |
| `images-*.txt`, `image-digests-*.txt` | a few KB |
| a `.sha256` fingerprint file next to each one | ~100 bytes |

And in the script's own output, you should see: `snapshot ok (read-only), integrity_check=ok`.

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

Do the small one first. If anything's wrong with the upload step, you'll find out from one 64 MB
file, instead of from six different files at once.

```bash
sudo /usr/local/sbin/k3s-track-a-backup.sh db
```

**Check:**

```bash
set -a; . /etc/k3s-backup/backup.env; set +a
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/cluster-state/db/"
```

Now do the full backup:

```bash
sudo /usr/local/sbin/k3s-track-a-backup.sh full
```

**Check — every folder from [02 §5](02-backup-strategy.md#5-s3-storage-design) should now have
something in it:**

```bash
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/" --recursive --human-readable
```

You should see files under `cluster-state/db/`, `cluster-state/server-identity/`, `config/`,
`manifests/`, `node-config/`, and `image-manifest/` — each one with a matching `.sha256`
fingerprint file next to it.

Folders you *won't* see yet: `velero/` (that's Phase 2) and `argocd-export/` (that's Phase 3).
That's expected at this stage.

And once again, the thing that actually matters most:

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A | grep -v Running | head
```

You should see: the restart count unchanged, the node still `Ready`, and only the four
already-known-broken demo apps from
[01 §13](01-discovery-baseline.md#13-argocd) — `demo-app`, `nginx-app`, `nginx-app-dev`,
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

LATEST=$(aws s3 ls "s3://$BUCKET/cluster-state/db/" | grep '\.db$' | sort | tail -1 | awk '{print $4}')
echo "$LATEST"
aws s3 cp "s3://$BUCKET/cluster-state/db/$LATEST" .
aws s3 cp "s3://$BUCKET/cluster-state/db/$LATEST.sha256" .
```

**Check — the fingerprint should still match after downloading:**

```bash
sha256sum -c "$LATEST.sha256"
```

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

**Check — the identity archive should contain what a real restore would need:**

```bash
aws s3 cp "s3://$BUCKET/cluster-state/server-identity/$(aws s3 ls "s3://$BUCKET/cluster-state/server-identity/" | grep 'tar.gz$' | sort | tail -1 | awk '{print $4}')" .
tar -tzf server-identity-*.tar.gz | head -40
tar -tzf server-identity-*.tar.gz | wc -l
```

Compare this list against what you found in step B.1. It should be the exact same set of files —
if not, the archive is missing something.

```bash
cd ~ && rm -rf ~/k3-restore-check
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

> **A restore-time gotcha, worth remembering now:** the snapshot is one single, complete
> `state.db` file. When restoring, place it at
> `/var/lib/rancher/k3s/server/db/state.db` with **no `-wal` and no `-shm` file next to it**,
> while K3s is stopped. If you leave an old, stale `-wal` file from the previous server sitting
> next to a fresh snapshot, K3s can silently load the wrong data. This should be noted in
> [03 — Restore Runbook](03-restore-runbook.md).

---

## Stage H — Turn on the automatic schedule `[node]`

Per [04, Phase 1](04-implementation-todo.md#phase-1--node--cluster-state-backup-track-a): we use
systemd timers, matching how the server already schedules its one existing routine job.
**No cron** — this server doesn't currently have any scheduled root jobs set up through cron, and
we want to keep it that way.

```bash
sudo install -m 0644 -o root -g root /tmp/k3s-backup@.service        /etc/systemd/system/
sudo install -m 0644 -o root -g root /tmp/k3s-backup-db.timer        /etc/systemd/system/
sudo install -m 0644 -o root -g root /tmp/k3s-backup-full.timer      /etc/systemd/system/
sudo systemctl daemon-reload
```

**Check that the files themselves are valid before turning anything on:**

```bash
sudo systemd-analyze verify /etc/systemd/system/k3s-backup@.service
sudo systemctl cat k3s-backup@db.service | head -20
```

Test the scheduled job by hand once — this is exactly the path the automatic schedule will
follow later:

```bash
sudo systemctl start k3s-backup@db.service
sudo systemctl status k3s-backup@db.service --no-pager
sudo journalctl -u k3s-backup@db.service -n 40 --no-pager
```

**Check:** you should see `Main PID: ... (code=exited, status=0/SUCCESS)`, and the log should end
with `completed successfully`.

Only now, turn the automatic schedule on:

```bash
sudo systemctl enable --now k3s-backup-db.timer
sudo systemctl enable --now k3s-backup-full.timer
```

**Check:**

```bash
systemctl list-timers 'k3s-backup*' --all --no-pager
```

You should see `k3s-backup-db.timer` scheduled next at the coming 00/06/12/18:20 UTC slot, and
`k3s-backup-full.timer` at 02:15 UTC. These two are timed so they never run at exactly the same
moment — and even if they somehow did, the script has a built-in lock to prevent them from
colliding.

---

## Stage I — Let it run for a while `[node]`, then close out the issues

Per [04, Phase 4](04-implementation-todo.md#phase-4--automation--retention): **let this run on
its own for one full week before actually relying on it.**

Check daily, takes about 30 seconds:

```bash
systemctl list-timers 'k3s-backup*' --no-pager
journalctl -u 'k3s-backup@*' --since '24 hours ago' --no-pager | tail -30
df -h /
```

```bash
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/cluster-state/db/" | tail -5
```

You should see **4 new database backup files per day**, plus one of everything else once a day.

Also keep an eye on, specifically:

- **How much free disk space is left.** The script automatically deletes anything older than 3
  days from its temporary staging area, and refuses to run at all if less than 2 GB is free — but
  a job running every 6 hours on a disk that's already 64% full deserves a week of close
  attention.
- **How much is piling up in S3.** There are no auto-cleanup rules yet (that's Phase 4), so
  nothing ever gets deleted automatically, and since versioning is on, even overwritten files
  stick around. At roughly 80 MB per snapshot × 4 times a day, that's **about 320 MB/day, or
  9–10 GB/month — and it just keeps growing.** Setting up the
  [cleanup rules](02-backup-strategy.md#retention-matrix) before this becomes a real cost on our
  AWS bill is the single strongest reason not to let Phase 4 slip.

  > **Decision made: no compression.** We upload the database snapshot uncompressed on purpose,
  > so it can be checked — and restored — directly, with no extra decompress step needed during
  > an actual outage. Compressing it would have cut storage use by roughly 3–5×, but we chose a
  > simpler, faster restore over saving on storage cost. We can revisit this if the AWS bill
  > becomes a real concern.

After a clean week with no problems:

- Tick every box in [04, Phase 0 and Phase 1](04-implementation-todo.md)
- Close issues [#9](../../issues/9) and [#10](../../issues/10)
- Update the status table in the [README](../README.md)
- Write down what you found in B.1/B.2/B.3 in [05](05-gaps-and-open-questions.md), and close
  [#8](../../issues/8), [#4](../../issues/4), [#13](../../issues/13), [#5](../../issues/5),
  [#6](../../issues/6)
- Commit any changes you made to the script on the server back into `scripts/` in this repo

---

## If something goes wrong and you need to undo this

Nothing in phases 0–1 modifies K3s itself, so undoing any of this just means "remove what we
added."

| Stage | How to undo it |
|-------|-----------------|
| H | `sudo systemctl disable --now k3s-backup-db.timer k3s-backup-full.timer` then `sudo rm /etc/systemd/system/k3s-backup*` and `daemon-reload` |
| E–F | `sudo rm -f /usr/local/sbin/k3s-track-a-backup.sh; sudo rm -rf /var/backups/k3s` |
| D | `sudo rm -rf /etc/k3s-backup` — then disable the writer login: `aws iam delete-access-key --user-name k3-master-backup-writer --access-key-id <id>` |
| C | `aws s3 rm s3://$BUCKET --recursive`, `aws s3api delete-bucket --bucket $BUCKET`, delete both IAM users, then `aws kms schedule-key-deletion --key-id $KEY_ID --pending-window-in-days 30` |
| A–B | Nothing to undo — these steps only read information, never changed anything. |

**If a backup run ever seems to actually be affecting the server** (unlikely — it's set to run at
low priority, and it only ever reads from K3s's data, never writes to it):

```bash
sudo systemctl stop 'k3s-backup@*'
sudo systemctl disable --now k3s-backup-db.timer k3s-backup-full.timer
```

That stops the backup completely. It doesn't touch K3s at all. There's nothing to "undo" on the
K3s side, because the script never writes to it in the first place.

---

## What Phase 0 + 1 deliberately do **not** give us yet

Let's be honest about what's still missing while these phases are the only ones done:

| Not covered yet | Which phase covers it | What that means for us right now |
|-----------------|-------------|-------------------|
| Backing up Kubernetes objects at the object level (via Velero) | Phase 2 | We can rebuild **this specific server**. We can't yet restore into a brand new cluster or a different K3s version — [02, item 5](02-backup-strategy.md#component-5--kubernetes-resource-state) explains that the SQLite backup only helps if we rebuild the exact same server. |
| App data on disk (the 6 monitoring data volumes, ~7.8 GB) | Phase 2 | Our Prometheus/Loki/Grafana history is **not backed up at all** right now. |
| ArgoCD's exported settings | Phase 3 | ArgoCD's own config, secrets, and any manually-created Apps can't be recovered from Git alone. |
| Automatic cleanup of old backups | Phase 4 | Storage use keeps growing forever, with no limit. |
| Alerts when a backup fails | Phase 4 | The script does write a "last successful backup" timestamp if our monitoring tool's file-collector feature exists, but **nothing actually alerts on it yet**. A silently failing backup would stay silent. |
| Ever actually testing a restore | Phase 5 | *A backup that's never been restored is just a hope, not an actual plan.* |
| Any backup plan if a restore itself goes wrong | — | The server is on-premise with **no hosting-provider snapshot**
([gap 1](05-gaps-and-open-questions.md#1-hosting-provider--resolved-datalix-treated-as-on-premise)).
There's nothing else behind our S3 bucket as a fallback. |

Finishing Phase 1 means **our server-level backup (Track A) works.** It does **not** yet mean
we're fully recoverable. Move on to [#11](../../issues/11) next.
