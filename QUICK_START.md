# K3s Backup — Execution Runbook

**Goal:** two backup jobs running daily to S3, and a restore we have actually tested.

**Who this is for:** one DevOps engineer. Follow top to bottom. Do not skip a step. Do not enable the timer until the first real Job 1 backup has reached S3.

**Total time:** 1–2 weeks. Most of that time is waiting for scheduled runs.

| Day | Where | Time | What happens |
|-----|-------|------|--------------|
| 1 | k3-master | 30 min | Read-only validation / preflight (`--no-aws`) |
| 2–3 | laptop (AWS CLI) | 1–2 hrs | AWS S3, KMS, IAM setup |
| 4 | k3-master | 30 min | Install Job 1, re-run preflight **with** AWS, dry-run |
| 5 | k3-master | 30 min | First real Job 1 backup, then enable the timer |
| 6–7 | k3-master | 1 hr | Install Velero, prove PVC backups, scratch restore tests |
| Week 2+ | — | daily | Watch backups, then test a full-server restore on a throwaway host |

Laptop AWS steps use bash (Git Bash or WSL on Windows). k3-master steps are run over SSH.

---

## Architecture (do not change)

- K3s datastore stays **SQLite**. No etcd migration.
- **Job 1** = K3s SQLite + server identity/config backup (`k3s-server-backup.sh`).
- **Job 2** = Velero Kubernetes resource + PVC filesystem backup.
- Velero uses **node-agent / File-System Backup**. No CSI snapshots.
- AWS S3 bucket: **`k3-master-dr`**
- Region: **`ap-south-1`**
- Retention: **7 daily + 4 weekly**
- No MySQL/PostgreSQL backup. There is no app database to back up.
- Never use plain `cp` on the live SQLite datastore. Job 1 uses SQLite online backup.
- Never print AWS secret keys, the K3s token, Kubernetes Secret values, TLS private keys, or encryption keys.

| Time (UTC) | Job | What it writes |
|------------|-----|----------------|
| 02:15 daily | Job 1 | `s3://k3-master-dr/k3s/daily/YYYY-MM-DD/` and, on Sundays, also `k3s/weekly/YYYY-MM-DD/` |
| 03:00 daily | Job 2 daily | Velero backup, TTL `168h` |
| 04:00 Sunday | Job 2 weekly | Velero backup, TTL `720h` (~4 weekly backups) |

Job 1 cannot restore a deleted PVC or a single deleted Secret. Velero is the only thing that can.

---

## DAY 1 — Read-only validation / preflight

**Risk for this whole day: Read-only.** Nothing on the cluster is changed.

k3-master address used below: `root@45.90.98.51`. Run laptop copy commands from the repo root.

### Step 1 — Copy the preflight checker to k3-master

**Run on:** laptop

**Risk:** Read-only (copies a file to `/tmp` only)

**Command:**

```bash
scp scripts/k3s-backup-preflight.sh root@45.90.98.51:/tmp/
```

**What this command does:**
Copies the preflight script from this repo onto the server’s `/tmp` folder. It does not install it yet and does not run it.

**Why we need it:**
The checker must be on k3-master before we can prove the server is ready. The repo copy is the one true script.

**Expected result:**
The copy finishes with no error. The file exists at `/tmp/k3s-backup-preflight.sh` on k3-master.

**If result is different:**
Confirm you are in the repo root (`ls scripts/k3s-backup-preflight.sh`). Then retry SSH:

```bash
ssh root@45.90.98.51 'hostname; ls -l /tmp/k3s-backup-preflight.sh'
```

**Verification before continuing:**

```bash
ssh root@45.90.98.51 'ls -l /tmp/k3s-backup-preflight.sh'
```

---

### Step 2 — Install the preflight checker

**Run on:** k3-master

**Risk:** Makes change (installs one script under `/usr/local/sbin` only)

**Command:**

```bash
sudo install -m 0750 -o root -g root /tmp/k3s-backup-preflight.sh /usr/local/sbin/k3s-backup-preflight.sh
```

**What this command does:**
Installs the script as root-owned, mode `0750`, in `/usr/local/sbin`. It does not start backups and does not touch K3s.

**Why we need it:**
Later days call this path. Installing it once keeps the command the same every time.

**Expected result:**
No error. The installed file is owned by `root:root` and mode `750`.

**If result is different:**
If `install: cannot stat` appears, Step 1 did not copy the file. Re-run Step 1. If permission denied, you are not root:

```bash
sudo -n true && echo root_ok || echo need_sudo
ls -l /tmp/k3s-backup-preflight.sh
```

**Verification before continuing:**

```bash
sudo ls -l /usr/local/sbin/k3s-backup-preflight.sh
sudo stat -c '%a %U:%G %n' /usr/local/sbin/k3s-backup-preflight.sh
```

Expect: `750 root:root /usr/local/sbin/k3s-backup-preflight.sh`

---

### Step 3 — Run preflight with AWS skipped

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws
```

**What this command does:**
Runs every local check: tools, K3s files, SQLite integrity (read-only), namespaces, and coverage. It skips bucket/KMS/login checks because AWS does not exist yet. It changes nothing on the cluster.

**Why we need it:**
Day 1 must prove the server can run Job 1 before we create AWS resources. AWS failures on Day 1 are expected if you omit `--no-aws`. Do not omit it today.

**Expected result:**
A PASS / WARN / FAIL line for each check, then a summary:

| Result | Meaning | What to do |
|--------|---------|------------|
| `READY` (exit 0) | Local checks passed | Continue Day 1 TLS checks |
| `READY, with warnings` (exit 2) | Safe to continue, but read every WARN | Continue only after you understand each warning |
| `NOT READY` (exit 1) | Blocking FAIL | Stop. The script prints the exact fix command. Run that command, then re-run this step |

AWS checks are skipped. That is expected.

**If result is different:**
Read the `Things to fix, and how:` block at the bottom. Run the printed fix command. Common first FAIL is missing `aws`:

```bash
sudo apt-get update && sudo apt-get install -y awscli
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws
```

If `python3` is missing:

```bash
sudo apt-get update && sudo apt-get install -y python3
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws
```

**Verification before continuing:**

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws; echo EXIT:$?
```

Continue only when the summary is `READY` or `READY, with warnings` (exit 0 or 2), not `NOT READY` (exit 1).

---

### Step 4 — How to read PASS / WARN / FAIL

**Run on:** k3-master (no extra command; this is how you read Step 3)

**Risk:** Read-only

**Command:**

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws; echo EXIT:$?
```

**What this command does:**
Repeats the same checker so you can map the summary to a go / no-go decision.

**Why we need it:**
A green-looking log is not enough. The exit code is the gate.

**Expected result:**

- `PASS` = that one check is good.
- `WARN` = not blocking today, but a later failure could go unnoticed. Read it.
- `FAIL` = blocking. Do not install Job 1. Do not create a fake workaround.
- Exit `0` = READY.
- Exit `2` = READY, with warnings.
- Exit `1` = NOT READY. Stop.

**If result is different:**
Do not continue to AWS setup while exit is `1`. Re-run the exact fix command printed by the script, then re-run this step.

**Verification before continuing:**

```bash
echo "Continue Day 1 TLS checks only if EXIT was 0 or 2"
```

---

### Step 5 — List Traefik / Ingress HTTPS routes

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo k3s kubectl get ingress,ingressroute -A
```

**What this command does:**
Lists Ingress and Traefik IngressRoute objects in every namespace. It does not change routing.

**Why we need it:**
We must know which hostnames use HTTPS before we can find where the certificates live.

**Expected result:**
A table of routes (or `No resources found` for one of the two types). Note the namespaces and hostnames.

**If result is different:**
If `k3s kubectl` fails, confirm K3s is running:

```bash
systemctl is-active k3s
sudo k3s kubectl get nodes
```

**Verification before continuing:**

```bash
sudo k3s kubectl get ingress,ingressroute -A
```

---

### Step 6 — Inspect Traefik for ACME / certresolver

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -i -B2 -A4 'acme\|certresolver\|entryPoint'
```

**What this command does:**
Shows whether Traefik is using Let’s Encrypt ACME or a cert resolver. It prints config keys, not private keys.

**Why we need it:**
If Traefik stores certificates in `acme.json` on an `emptyDir`, nothing in this backup design saves them. A restore would come back with broken HTTPS.

**Expected result:**
One of the patterns in Step 8. You should see either ACME/certresolver settings, or no ACME lines at all.

**If result is different:**
If Traefik is not named `traefik` or not in `kube-system`:

```bash
sudo k3s kubectl get deploy,ds -A | grep -i traefik
```

Then re-run the `get deploy ... -o yaml | grep` command against the real namespace/name.

**Verification before continuing:**

```bash
sudo k3s kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o jsonpath='{range .items[*]}{.metadata.name}{" volumes="}{range .spec.volumes[*]}{.name}{","}{end}{"\n"}{end}'
```

---

### Step 7 — Identify the TLS certificate source

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo k3s kubectl get secrets -A --field-selector type=kubernetes.io/tls
sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -i -B2 -A8 'acme.json\|emptyDir\|secret\|secretName\|hostPath\|persistentVolumeClaim'
sudo k3s kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o jsonpath='{range .items[*].spec.volumes[*]}{.name}{"\t"}{.emptyDir}{"\t"}{.secret.secretName}{"\t"}{.hostPath.path}{"\t"}{.persistentVolumeClaim.claimName}{"\n"}{end}'
```

**What this command does:**
Lists Kubernetes TLS Secrets, then shows how Traefik mounts certificate data: Secret, `emptyDir`, host file, or PVC. It does not print Secret values.

**Why we need it:**
The backup design only covers some certificate sources. You must know which one is in use before you trust a restore.

**Expected result:**
Enough output to pick **one** row in the table below.

| What you see | Certificate source | Covered by this backup design? |
|--------------|--------------------|--------------------------------|
| TLS Secrets exist, and Traefik has **no** ACME/`acme.json` | Kubernetes TLS Secrets | **Yes — Job 2 (Velero)** backs up Secrets |
| ACME/`certresolver` found, volume is `emptyDir` | `acme.json` in temporary pod disk | **No.** HTTPS will be broken after restore until certificates are issued again or this storage is fixed |
| ACME found, volume is a PVC | `acme.json` on a volume | **Yes — Job 2**, but only after that PVC appears under Pod Volume Backups |
| ACME found, volume is a `hostPath` under `/var/lib/rancher/k3s/server` or `/etc/rancher/k3s` | file on the K3s server identity/config paths | **Yes — Job 1** identity/config archive |
| ACME found, `hostPath` somewhere else | file on the host outside Job 1 paths | **No**, unless you later confirm that path is inside `k3s-identity.tar.gz` |
| TLS Secrets exist **and** ACME on `emptyDir` | mixed | Secrets are covered by Velero; the ACME file is **not** |
| No Ingress HTTPS and no TLS Secrets and no ACME | certificates live in front of this server (load balancer / CDN) | This design does not back up that upstream box. Write down where TLS is terminated |

**If result is different:**
If no Traefik pod is found, search all namespaces:

```bash
sudo k3s kubectl get pods -A | grep -i traefik
sudo k3s kubectl get secrets -A --field-selector type=kubernetes.io/tls
```

If you still cannot tell the source, stop and do not claim HTTPS is protected.

**Verification before continuing:**

```bash
echo "Write down the certificate source and whether Job 1, Job 2, both, or neither covers it."
sudo k3s kubectl get secrets -A --field-selector type=kubernetes.io/tls --no-headers | wc -l
```

Do not continue to Day 2 until you have written that answer. If the source is `acme.json` on `emptyDir`, HTTPS is **not** covered by this design. Record that now.

---

## DAY 2–3 — AWS S3, KMS, IAM setup

Run these from your laptop with an AWS **admin** login. Nothing in this section restarts K3s.

### Step 8 — Validate AWS CLI identity

**Run on:** laptop / AWS CLI

**Risk:** Read-only

**Command:**

```bash
aws sts get-caller-identity
```

**What this command does:**
Shows which AWS account and IAM principal you are logged in as.

**Why we need it:**
Bucket, KMS, and IAM users must be created in the **same** account that will hold `k3-master-dr`. A wrong profile creates resources in the wrong account.

**Expected result:**
JSON with `UserId`, `Account` (12-digit account ID), and `Arn`.

**If result is different:**
If `Unable to locate credentials` or `ExpiredToken`:

```bash
aws configure list
aws sts get-caller-identity --profile default
```

Set `AWS_PROFILE` to the admin profile that can create KMS, S3, and IAM, then retry Step 8.

**Verification before continuing:**

```bash
aws sts get-caller-identity --query Account --output text
```

You need a 12-digit account ID before continuing.

---

### Step 9 — Set reusable shell variables

**Run on:** laptop / AWS CLI

**Risk:** Read-only (sets shell variables only)

**Command:**

```bash
export AWS_PROFILE=<your-admin-profile>
export REGION=ap-south-1
export BUCKET=k3-master-dr
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export KEY_ALIAS=alias/k3-master-dr
export WRITER_USER=k3-master-backup-writer
export READER_USER=k3-master-restore-reader
echo "REGION=$REGION"
echo "BUCKET=$BUCKET"
echo "ACCOUNT_ID=$ACCOUNT_ID"
echo "KEY_ALIAS=$KEY_ALIAS"
echo "WRITER_USER=$WRITER_USER"
echo "READER_USER=$READER_USER"
```

**What this command does:**
Stores the region, bucket name, account ID, KMS alias name, and IAM user names in this shell. It does not create AWS resources yet.

**Why we need it:**
Every later AWS command reads these names. One typo in the bucket or region breaks encryption and uploads.

**Expected result:**
`REGION=ap-south-1`, `BUCKET=k3-master-dr`, a 12-digit `ACCOUNT_ID`, and the two IAM user names.

**If result is different:**
If `ACCOUNT_ID` is empty, Step 8 failed. Fix credentials, then re-run this whole block in the **same** terminal. Do not start a new terminal without exporting these again.

**Verification before continuing:**

```bash
echo "$REGION / $BUCKET / $ACCOUNT_ID / $WRITER_USER / $READER_USER"
```

---

### Step 10 — Create the KMS key

**Run on:** laptop / AWS CLI

**Risk:** Makes change (creates a KMS key in your AWS account)

**Command:**

```bash
KEY_ID=$(aws kms create-key \
  --region "$REGION" \
  --description "k3-master DR backup encryption (cluster CA, tokens, K8s Secrets)" \
  --key-usage ENCRYPT_DECRYPT \
  --key-spec SYMMETRIC_DEFAULT \
  --query KeyMetadata.KeyId --output text)
echo "KEY_ID=$KEY_ID"
```

**What this command does:**
Creates a customer-managed symmetric KMS key used to encrypt every backup object.

**Why we need it:**
S3 default encryption will use this key. If this key is deleted later, every backup encrypted with it becomes unreadable.

**Expected result:**
A UUID printed as `KEY_ID=...`

**If result is different:**
If `AccessDenied`, this login cannot create keys:

```bash
aws iam get-user
aws kms create-key --region "$REGION" --description "permission-test" 2>&1 | head -20
```

Use an admin login and retry. Do not reuse some other application’s KMS key.

**Verification before continuing:**

```bash
aws kms describe-key --region "$REGION" --key-id "$KEY_ID" \
  --query 'KeyMetadata.{KeyId:KeyId,State:KeyState,Manager:KeyManager}' --output table
```

Expect `State = Enabled`, `Manager = CUSTOMER`.

---

### Step 11 — Create the KMS alias

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws kms create-alias --region "$REGION" \
  --alias-name "$KEY_ALIAS" --target-key-id "$KEY_ID"
```

**What this command does:**
Names the key `alias/k3-master-dr` so later commands do not depend on remembering the UUID.

**Why we need it:**
Job 1 and the bucket encryption settings need a stable name for this key.

**Expected result:**
No error.

**If result is different:**
If `AlreadyExists`, describe the existing alias and confirm it points at **this** key:

```bash
aws kms list-aliases --region "$REGION" --query "Aliases[?AliasName=='$KEY_ALIAS']"
```

If it points at a different key, stop. Do not overwrite another team’s alias.

**Verification before continuing:**

```bash
aws kms describe-key --region "$REGION" --key-id "$KEY_ALIAS" \
  --query 'KeyMetadata.KeyId' --output text
```

It must print the same `KEY_ID` as Step 10.

---

### Step 12 — Save the full KMS key ARN

**Run on:** laptop / AWS CLI

**Risk:** Read-only

**Command:**

```bash
KEY_ARN=$(aws kms describe-key --region "$REGION" --key-id "$KEY_ID" \
  --query KeyMetadata.Arn --output text)
echo "KEY_ARN=$KEY_ARN"
```

**What this command does:**
Reads the full key ARN and stores it in `KEY_ARN`.

**Why we need it:**
`KMS_KEY_ID` in `backup.env` **must** be the full ARN, not the bare key id. A bare id makes the bucket reject uploads with `AccessDenied`.

**Expected result:**
A line like:

```text
KEY_ARN=arn:aws:kms:ap-south-1:123456789012:key/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

**If result is different:**
If the value does not start with `arn:aws:kms:ap-south-1:`:

```bash
aws kms describe-key --region "$REGION" --key-id "$KEY_ID" --query KeyMetadata.Arn --output text
```

Do not continue until it is a full ARN.

**Verification before continuing:**

```bash
echo "$KEY_ARN" | grep -E '^arn:aws:kms:ap-south-1:[0-9]{12}:key/'
```

---

### Step 13 — Enable yearly KMS key rotation

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws kms enable-key-rotation --region "$REGION" --key-id "$KEY_ID"
```

**What this command does:**
Turns on automatic yearly rotation of the key material. Old backups stay readable.

**Why we need it:**
This is the DR key for cluster identity and Secrets. Rotation should be on from day one.

**Expected result:**
No error.

**If result is different:**

```bash
aws kms get-key-rotation-status --region "$REGION" --key-id "$KEY_ID"
```

If `AccessDenied`, use the admin login. If rotation is already enabled, continue.

**Verification before continuing:**

```bash
aws kms get-key-rotation-status --region "$REGION" --key-id "$KEY_ID"
```

Expect `"KeyRotationEnabled": true`.

---

### Step 14 — Create the S3 bucket

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
```

**What this command does:**
Creates bucket `k3-master-dr` in `ap-south-1`. It does not yet turn on encryption, versioning, or public-access block.

**Why we need it:**
This bucket is the only off-server copy of Job 1 and Job 2 backups.

**Expected result:**
A `Location` URL containing `k3-master-dr`.

**If result is different:**
If `BucketAlreadyOwnedByYou`, the bucket already exists in **this** account — continue to Step 15 and verify settings.
If `BucketAlreadyExists`, the name is taken globally. Stop and do not invent a new architecture here; pick `k3-master-dr-<yourorg>`, set `BUCKET` to that name, and use that name everywhere else in this runbook.

```bash
aws s3api head-bucket --bucket "$BUCKET" --region "$REGION"
aws s3api get-bucket-location --bucket "$BUCKET"
```

**Verification before continuing:**

```bash
aws s3api get-bucket-location --bucket "$BUCKET"
```

Expect `ap-south-1` (or `LocationConstraint` = `ap-south-1`).

---

### Step 15 — Block all public access

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

**What this command does:**
Turns on all four S3 public-access blocks so the bucket cannot be made public by ACL or policy accident.

**Why we need it:**
The bucket will hold the cluster CA, tokens, and Kubernetes Secrets. It must not be public.

**Expected result:**
No error.

**If result is different:**

```bash
aws s3api get-public-access-block --bucket "$BUCKET"
```

If `NoSuchPublicAccessBlockConfiguration`, the put failed. Re-run this step with the admin login.

**Verification before continuing:**

```bash
aws s3api get-public-access-block --bucket "$BUCKET"
```

All four values must be `true`.

---

### Step 16 — Enable S3 versioning

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

**What this command does:**
Keeps previous copies when Job 1 overwrites the same filename in the same day’s folder.

**Why we need it:**
Job 1 uses fixed filenames inside a dated folder. A second run on the same day would otherwise destroy the first copy.

**Expected result:**
No error.

**If result is different:**

```bash
aws s3api get-bucket-versioning --bucket "$BUCKET"
```

If `Status` is missing or `Suspended`, re-run this step.

**Verification before continuing:**

```bash
aws s3api get-bucket-versioning --bucket "$BUCKET"
```

Expect `"Status": "Enabled"`.

---

### Step 17 — Enable default SSE-KMS encryption

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

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

**What this command does:**
Makes every new object encrypt with SSE-KMS using the DR key. Do this **before** any real backup is uploaded. Turning encryption on later does not encrypt objects already stored.

**Why we need it:**
Backups contain cluster identity and Secrets. Default encryption is part of the existing design.

**Expected result:**
No error.

**If result is different:**
If `InvalidArgument` or `AccessDenied` on the key, confirm `KEY_ARN` is the full ARN from Step 12:

```bash
echo "$KEY_ARN"
aws kms describe-key --region "$REGION" --key-id "$KEY_ARN" --query KeyMetadata.KeyState
aws s3api get-bucket-encryption --bucket "$BUCKET"
```

**Verification before continuing:**

```bash
aws s3api get-bucket-encryption --bucket "$BUCKET"
```

Expect `SSEAlgorithm` = `aws:kms` and `KMSMasterKeyID` equal to `$KEY_ARN`.

---

### Step 18 — Verify bucket security settings together

**Run on:** laptop / AWS CLI

**Risk:** Read-only

**Command:**

```bash
aws s3api get-public-access-block --bucket "$BUCKET"
aws s3api get-bucket-versioning --bucket "$BUCKET"
aws s3api get-bucket-encryption --bucket "$BUCKET"
```

**What this command does:**
Re-reads public-access block, versioning, and default encryption.

**Why we need it:**
Do not create IAM users until the bucket itself is locked down.

**Expected result:**
All four public-access flags `true`; versioning `Enabled`; encryption `aws:kms` with your key ARN.

**If result is different:**
Re-run the matching Step 15, 16, or 17, then re-run this step. Do not continue while any of the three is wrong.

**Verification before continuing:**

```bash
aws s3api get-public-access-block --bucket "$BUCKET" --query 'PublicAccessBlockConfiguration'
aws s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text
aws s3api get-bucket-encryption --bucket "$BUCKET" --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault'
```

---

### Step 19 — Create lifecycle rules (7 daily + 4 weekly)

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
cat > /tmp/k3-dr-lifecycle.json <<'EOF'
{
  "Rules": [
    {
      "ID": "k3s-daily-8d",
      "Status": "Enabled",
      "Filter": { "Prefix": "k3s/daily/" },
      "Expiration": { "Days": 8 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 2 }
    },
    {
      "ID": "k3s-weekly-31d",
      "Status": "Enabled",
      "Filter": { "Prefix": "k3s/weekly/" },
      "Expiration": { "Days": 31 },
      "NoncurrentVersionExpiration": { "NoncurrentDays": 2 }
    },
    {
      "ID": "abort-stuck-uploads",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 3 }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" --lifecycle-configuration file:///tmp/k3-dr-lifecycle.json
```

**What this command does:**
- Expires current objects under `k3s/daily/` after 8 days (keeps ~7 daily restore points).
- Expires current objects under `k3s/weekly/` after 31 days (keeps ~4 weekly restore points).
- Aborts incomplete multipart uploads after 3 days (needed because `state.db` is ~64 MB).
- Does **not** add any current-object expiration on `velero/`.

**Why we need it:**
S3 can only say “delete N days after upload”. That is why Job 1 writes two prefixes. Velero expires its own objects with TTL. An S3 expire rule on `velero/` would delete chunks that still-valid backups need.

**Expected result:**
No error from `put-bucket-lifecycle-configuration`.

**If result is different:**

```bash
cat /tmp/k3-dr-lifecycle.json
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET"
```

If JSON is invalid, recreate the file and retry. Do not add a `velero/` expiration rule to “fix” it.

**Verification before continuing:**

```bash
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[].{ID:ID,Prefix:Filter.Prefix,Days:Expiration.Days,Abort:AbortIncompleteMultipartUpload.DaysAfterInitiation}' \
  --output table
```

---

### Step 20 — Prove there is no current-object expiration on `velero/`

**Run on:** laptop / AWS CLI

**Risk:** Read-only

**Command:**

```bash
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output json
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[?contains(Filter.Prefix, `velero`) || ID==`velero`]' --output json
```

**What this command does:**
Prints every lifecycle rule and specifically searches for anything targeting `velero`.

**Why we need it:**
A normal `Expiration.Days` on `velero/` corrupts Velero file-system backups. The damage only shows up at restore time.

**Expected result:**
Rules present: `k3s-daily-8d` (8 days), `k3s-weekly-31d` (31 days), and `abort-stuck-uploads` (no `Expiration`).
The second command returns `[]` or no rule whose prefix is `velero/`.
No rule with `"Expiration"` applies to prefix `velero/`.

**If result is different:**
If you see a rule with `"Prefix": "velero/"` and `"Expiration"`, delete that rule. Rebuild `/tmp/k3-dr-lifecycle.json` from Step 19 (only those three rules) and re-apply:

```bash
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" --lifecycle-configuration file:///tmp/k3-dr-lifecycle.json
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --output json
```

**Verification before continuing:**

```bash
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" --query 'Rules[].{ID:ID,Prefix:Filter.Prefix,Expiration:Expiration}' --output table
```

---

### Step 21 — Create the Backup Writer IAM policy file

**Run on:** laptop / AWS CLI

**Risk:** Makes change (writes a local JSON file)

**Command:**

```bash
cat > /tmp/k3-dr-writer-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListOwnBucketOnly",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"],
      "Resource": "arn:aws:s3:::$BUCKET"
    },
    {
      "Sid": "WriteBackups",
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": "arn:aws:s3:::$BUCKET/*"
    },
    {
      "Sid": "DeleteOnlyVeleroPrefix",
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
python3 -m json.tool /tmp/k3-dr-writer-policy.json > /dev/null && echo writer_policy_json_ok
```

**What this command does:**
Writes the Backup Writer policy to disk and checks it is valid JSON.

**Why we need it:**
This is the login that will live on k3-master. It can write backups. It can delete **only** under `velero/*` (so Velero TTL can expire Job 2 objects). It cannot delete Job 1 objects under `k3s/`.

**Why `kms:Decrypt` is required:**
`aws s3 cp` uses a **multipart** upload for files over 8 MB. `state.db` is about 64 MB, so it always uses multipart. Multipart uploads to an SSE-KMS bucket need `kms:Decrypt` as well as `kms:GenerateDataKey`. Without `kms:Decrypt`, a small test file works and the real database upload fails with `AccessDenied`.

**Why Velero needs `s3:DeleteObject` only on `velero/*`:**
Velero expires backups by deleting its own objects when TTL is reached. That delete is Velero, not an S3 lifecycle rule. Job 1 must **not** be deletable by the login stored on the production server. Restricting delete to `velero/*` gives Velero TTL without letting a compromised server wipe `k3s/` backups.

**Expected result:**
`writer_policy_json_ok`. The file contains your real bucket name and full `KEY_ARN`.

**If result is different:**
If JSON is invalid, `KEY_ARN` or `BUCKET` was empty. Re-run Step 9 and Step 12 in this terminal, then re-run this step.

```bash
echo "BUCKET=$BUCKET"
echo "KEY_ARN=$KEY_ARN"
python3 -m json.tool /tmp/k3-dr-writer-policy.json | head
```

**Verification before continuing:**

```bash
python3 -m json.tool /tmp/k3-dr-writer-policy.json | grep -E 'DeleteObject|kms:Decrypt|velero'
```

You must see `s3:DeleteObject` on `.../velero/*` and `kms:Decrypt`.

---

### Step 22 — Create the Backup Writer IAM user

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws iam create-user --user-name "$WRITER_USER"
```

**What this command does:**
Creates IAM user `k3-master-backup-writer`.

**Why we need it:**
This is the only AWS login that will be stored on k3-master.

**Expected result:**
JSON including `"UserName": "k3-master-backup-writer"`.

**If result is different:**
If `EntityAlreadyExists`, the user is already there. Continue to attach the policy:

```bash
aws iam get-user --user-name "$WRITER_USER"
```

**Verification before continuing:**

```bash
aws iam get-user --user-name "$WRITER_USER" --query 'User.UserName' --output text
```

---

### Step 23 — Attach the Backup Writer policy

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws iam put-user-policy --user-name "$WRITER_USER" \
  --policy-name k3-master-dr-write --policy-document file:///tmp/k3-dr-writer-policy.json
```

**What this command does:**
Attaches the JSON from Step 21 as an inline policy on the writer user.

**Why we need it:**
Without this policy the access keys cannot upload to S3 or use KMS.

**Expected result:**
No error.

**If result is different:**

```bash
aws iam get-user-policy --user-name "$WRITER_USER" --policy-name k3-master-dr-write --query PolicyName
python3 -m json.tool /tmp/k3-dr-writer-policy.json > /dev/null
```

If `MalformedPolicyDocument`, the JSON file is wrong. Fix Step 21 and retry this step.

**Verification before continuing:**

```bash
aws iam list-user-policies --user-name "$WRITER_USER"
aws iam get-user-policy --user-name "$WRITER_USER" --policy-name k3-master-dr-write \
  --query 'PolicyDocument.Statement[].Sid' --output text
```

Expect policy name `k3-master-dr-write` and Sids including `DeleteOnlyVeleroPrefix` and `UseTheDrKeyForBackupUploads`.

---

### Step 24 — Create Backup Writer access keys

**Run on:** laptop / AWS CLI

**Risk:** Makes change (creates credentials)

**Command:**

```bash
aws iam create-access-key --user-name "$WRITER_USER" \
  --query 'AccessKey.{Id:AccessKeyId,Secret:SecretAccessKey}' --output table
```

**What this command does:**
Creates one access key pair for the writer user and prints it **once**.

**Why we need it:**
These keys go into `/etc/k3s-backup/backup.env` on k3-master, and into the Velero credentials file. They must **not** be committed to git.

**Expected result:**
A table with `Id` (starts with `AKIA...`) and `Secret`. Save both in a password manager now.

**If result is different:**
If `LimitExceeded`, list and delete unused keys **only if you know they are unused**:

```bash
aws iam list-access-keys --user-name "$WRITER_USER"
```

Do not print the secret again; AWS will not show it later.

**Verification before continuing:**

```bash
aws iam list-access-keys --user-name "$WRITER_USER" --query 'AccessKeyMetadata[].Status' --output text
```

Expect `Active`. Do not paste the secret into this document or into chat.

**These writer credentials must go on k3-master** (Day 4 `backup.env`, and later the Velero secret). They are the backup-writer login, not the restore-reader login.

---

### Step 25 — Create the Restore Reader IAM policy file

**Run on:** laptop / AWS CLI

**Risk:** Makes change (writes a local JSON file)

**Command:**

```bash
cat > /tmp/k3-dr-reader-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBackupBucket",
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketVersions"],
      "Resource": "arn:aws:s3:::$BUCKET"
    },
    {
      "Sid": "ReadBackups",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": "arn:aws:s3:::$BUCKET/*"
    },
    {
      "Sid": "DecryptDrKey",
      "Effect": "Allow",
      "Action": ["kms:Decrypt", "kms:DescribeKey"],
      "Resource": "$KEY_ARN"
    }
  ]
}
EOF
python3 -m json.tool /tmp/k3-dr-reader-policy.json > /dev/null && echo reader_policy_json_ok
```

**What this command does:**
Writes a read-only policy: list, get, and KMS decrypt. No `s3:PutObject`. No `s3:DeleteObject`.

**Why we need it:**
Full-server restore uses this login from a laptop or a replacement host. It must not live on the production server.

**Expected result:**
`reader_policy_json_ok`.

**If result is different:**
Re-export `BUCKET` and `KEY_ARN`, then recreate the file.

```bash
echo "BUCKET=$BUCKET KEY_ARN=$KEY_ARN"
python3 -m json.tool /tmp/k3-dr-reader-policy.json | head
```

**Verification before continuing:**

```bash
python3 -m json.tool /tmp/k3-dr-reader-policy.json | grep -E 'DeleteObject|PutObject|kms:Decrypt'
```

You must see `kms:Decrypt`. You must **not** see `DeleteObject` or `PutObject`.

---

### Step 26 — Create the Restore Reader IAM user

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws iam create-user --user-name "$READER_USER"
```

**What this command does:**
Creates IAM user `k3-master-restore-reader`.

**Why we need it:**
Restore must still work if k3-master is gone or compromised. That requires a second login stored offline.

**Expected result:**
JSON with `"UserName": "k3-master-restore-reader"`.

**If result is different:**
If `EntityAlreadyExists`:

```bash
aws iam get-user --user-name "$READER_USER"
```

Then continue.

**Verification before continuing:**

```bash
aws iam get-user --user-name "$READER_USER" --query 'User.UserName' --output text
```

---

### Step 27 — Attach the Restore Reader policy

**Run on:** laptop / AWS CLI

**Risk:** Makes change

**Command:**

```bash
aws iam put-user-policy --user-name "$READER_USER" \
  --policy-name k3-master-dr-read --policy-document file:///tmp/k3-dr-reader-policy.json
```

**What this command does:**
Attaches the read-only policy to the restore user.

**Why we need it:**
Without it, restore downloads from S3 will fail when you need them most.

**Expected result:**
No error.

**If result is different:**

```bash
aws iam get-user-policy --user-name "$READER_USER" --policy-name k3-master-dr-read --query PolicyName
```

**Verification before continuing:**

```bash
aws iam list-user-policies --user-name "$READER_USER"
aws iam list-user-policies --user-name "$WRITER_USER"
```

Expect `k3-master-dr-read` on the reader and `k3-master-dr-write` on the writer.

---

### Step 28 — Create Restore Reader access keys

**Run on:** laptop / AWS CLI

**Risk:** Makes change (creates credentials)

**Command:**

```bash
aws iam create-access-key --user-name "$READER_USER" \
  --query 'AccessKey.{Id:AccessKeyId,Secret:SecretAccessKey}' --output table
```

**What this command does:**
Creates the restore-only access key pair and prints it once.

**Why we need it:**
You will use these keys on a laptop or throwaway restore host, never as the daily backup login.

**Expected result:**
A table with `Id` and `Secret`. Store them in a password manager / offline vault.

**These credentials must NOT be stored on k3-master.** Do not put them in `/etc/k3s-backup/backup.env`. Do not put them in the Velero secret. If k3-master is compromised, the attacker must not be able to read backups with a key that was sitting on that same disk.

**If result is different:**

```bash
aws iam list-access-keys --user-name "$READER_USER"
```

**Verification before continuing:**

```bash
aws iam list-access-keys --user-name "$READER_USER" --query 'AccessKeyMetadata[].Status' --output text
rm -f /tmp/k3-dr-writer-policy.json /tmp/k3-dr-reader-policy.json /tmp/k3-dr-lifecycle.json
```

Expect `Active`, then local policy files removed.

---

### Step 29 — Test AWS/S3 connectivity with the writer keys

**Run on:** laptop / AWS CLI

**Risk:** Makes change (uploads a small test object)

**Command:**

```bash
export AWS_ACCESS_KEY_ID=<WRITER_ACCESS_KEY_ID>
export AWS_SECRET_ACCESS_KEY=<WRITER_SECRET_ACCESS_KEY>
export AWS_DEFAULT_REGION="$REGION"
unset AWS_PROFILE
echo "k3-master egress test $(date -u +%FT%TZ)" > /tmp/k3-egress-test.txt
aws s3 cp /tmp/k3-egress-test.txt "s3://$BUCKET/_egress-test/" \
  --sse aws:kms --sse-kms-key-id "$KEY_ARN"
```

**What this command does:**
Uploads a tiny text file using the **writer** keys and SSE-KMS.

**Why we need it:**
This proves identity, bucket, region, and KMS grants work for a simple put. It is **not** enough by itself; the next step tests multipart.

**Expected result:**
`upload: ... to s3://k3-master-dr/_egress-test/k3-egress-test.txt`

**If result is different:**
If `AccessDenied`, check: full `KEY_ARN`, writer policy attached, region `ap-south-1`:

```bash
aws sts get-caller-identity
aws s3 ls "s3://$BUCKET/"
aws kms describe-key --key-id "$KEY_ARN" --query KeyMetadata.KeyState
```

Do not use the restore-reader keys here (they cannot put objects).

**Verification before continuing:**

```bash
aws s3api head-object --bucket "$BUCKET" --key "_egress-test/k3-egress-test.txt" \
  --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId,Size:ContentLength}'
```

Expect `SSE = aws:kms` and the DR key ARN.

---

### Step 30 — Realistic ~64 MB upload test (multipart / kms:Decrypt)

**Run on:** laptop / AWS CLI

**Risk:** Makes change (uploads a 64 MB test object)

**Command:**

```bash
dd if=/dev/zero of=/tmp/k3-egress-big.bin bs=1M count=64 status=none
aws s3 cp /tmp/k3-egress-big.bin "s3://$BUCKET/_egress-test/" \
  --sse aws:kms --sse-kms-key-id "$KEY_ARN"
```

**What this command does:**
Uploads 64 MB of zeros. AWS CLI uses multipart upload for objects over 8 MB. This is the same path as `state.db`.

**Why we need it:**
A small file can succeed even when `kms:Decrypt` is missing. The real Job 1 backup would then fail. This test catches that before production data is involved.

**Expected result:**
Upload completes with no `AccessDenied`.

**If result is different:**
If the small file in Step 29 worked and this fails with `AccessDenied`, the writer policy is missing `kms:Decrypt`. Re-apply Step 21–23 with `kms:Decrypt` included, wait a few seconds, and retry this step:

```bash
aws iam get-user-policy --user-name "$WRITER_USER" --policy-name k3-master-dr-write \
  --query 'PolicyDocument.Statement[?Sid==`UseTheDrKeyForBackupUploads`].Action'
```

**Verification before continuing:**

```bash
aws s3api head-object --bucket "$BUCKET" --key "_egress-test/k3-egress-big.bin" \
  --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId,Size:ContentLength}'
```

---

### Step 31 — Verify the 64 MB object and SSE-KMS

**Run on:** laptop / AWS CLI

**Risk:** Read-only

**Command:**

```bash
aws s3api head-object --bucket "$BUCKET" --key "_egress-test/k3-egress-big.bin" \
  --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId,Size:ContentLength}'
```

**What this command does:**
Reads the object metadata: encryption algorithm, KMS key, and size.

**Why we need it:**
We must see `aws:kms` and size `67108864`. `AES256` means the DR KMS key was not used.

**Expected result:**
`SSE = aws:kms`, `Size = 67108864`, `Key` = your `$KEY_ARN`.

**If result is different:**
If size is not `67108864`, the upload was truncated. Re-run Step 30.
If `SSE` is `AES256` or empty, re-run Step 17, then delete and re-upload:

```bash
aws s3api get-bucket-encryption --bucket "$BUCKET"
```

**Verification before continuing:**

```bash
aws s3 ls "s3://$BUCKET/_egress-test/" --human-readable
```

---

### Step 32 — Remove the test objects (admin login)

**Run on:** laptop / AWS CLI

**Risk:** Makes change (deletes test objects only)

**Command:**

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export AWS_PROFILE=<your-admin-profile>
aws s3 rm "s3://$BUCKET/_egress-test/" --recursive
rm -f /tmp/k3-egress-test.txt /tmp/k3-egress-big.bin
```

**What this command does:**
Deletes the `_egress-test/` objects using the **admin** login, then removes local temp files. The writer login cannot delete `k3s/` or `_egress-test/` objects (delete is allowed only on `velero/*`).

**Why we need it:**
Test objects are not backups. Leave the bucket clean before Job 1.

**Expected result:**
`delete: s3://k3-master-dr/_egress-test/...` for the test files.

**If result is different:**
If `AccessDenied`, you are still using writer keys. `unset` the writer keys, set `AWS_PROFILE` to admin, and retry:

```bash
aws sts get-caller-identity
aws s3 rm "s3://$BUCKET/_egress-test/" --recursive
```

Versioning may leave a delete marker. That is expected.

**Verification before continuing:**

```bash
aws s3 ls "s3://$BUCKET/_egress-test/" --recursive
```

Expect no remaining current objects (empty output).

---

## DAY 4 — Install and validate Job 1

Do not enable the systemd timer today.

### Step 33 — Create `/etc/k3s-backup/`

**Run on:** k3-master

**Risk:** Makes change (new directory only)

**Command:**

```bash
sudo install -d -m 0700 -o root -g root /etc/k3s-backup
```

**What this command does:**
Creates the backup config directory, owner `root`, mode `0700`.

**Why we need it:**
This is where `backup.env` will live. Mode `0700` keeps other users out.

**Expected result:**
Directory exists.

**If result is different:**

```bash
sudo ls -ld /etc/k3s-backup
```

If it exists with the wrong mode, run:

```bash
sudo chown root:root /etc/k3s-backup
sudo chmod 0700 /etc/k3s-backup
```

**Verification before continuing:**

```bash
sudo stat -c '%a %U:%G %n' /etc/k3s-backup
```

Expect `700 root:root /etc/k3s-backup`.

---

### Step 34 — Create `backup.env` with required variable names

**Run on:** k3-master

**Risk:** Makes change (creates the credentials file)

**Command:**

```bash
sudo install -m 0600 -o root -g root /dev/null /etc/k3s-backup/backup.env
sudo nano /etc/k3s-backup/backup.env
```

Put **only** these variable names in the file. Fill in real values on the server. **Never put real secret values in this document.**

```ini
S3_BUCKET=k3-master-dr
AWS_REGION=ap-south-1
KMS_KEY_ID=arn:aws:kms:ap-south-1:<ACCOUNT_ID>:key/<KEY_UUID>
AWS_ACCESS_KEY_ID=<WRITER_ACCESS_KEY_ID>
AWS_SECRET_ACCESS_KEY=<WRITER_SECRET_ACCESS_KEY>
```

Optional (default is already `1`; only add this line if you want to turn host-config capture off):

```ini
INCLUDE_NODE_CONFIG=1
```

**What this command does:**
Creates a root-only env file Job 1 reads on every run.

**Why we need it:**
The script refuses to run without `S3_BUCKET`, `AWS_REGION`, and a **full** `KMS_KEY_ID` ARN, plus the writer keys.

**Expected result:**
File exists, mode `600`, owner `root`. `KMS_KEY_ID` starts with `arn:aws:kms:`. Keys are the **writer** keys from Step 24, not the restore-reader keys.

**If result is different:**
If you pasted a bare key id (no `arn:aws:kms:`), every upload will fail. Fix the file:

```bash
sudo grep -E '^(S3_BUCKET|AWS_REGION|KMS_KEY_ID|AWS_ACCESS_KEY_ID)=' /etc/k3s-backup/backup.env
```

That grep does **not** print the secret key. If `KMS_KEY_ID` is not a full ARN, edit it.

**Verification before continuing:**

```bash
sudo stat -c '%a %U:%G %n' /etc/k3s-backup /etc/k3s-backup/backup.env
sudo grep -E '^(S3_BUCKET|AWS_REGION|KMS_KEY_ID)=' /etc/k3s-backup/backup.env
```

Expect `700` on the directory, `600` on the file, `S3_BUCKET=k3-master-dr`, `AWS_REGION=ap-south-1`, and `KMS_KEY_ID=arn:aws:kms:...`.

---

### Step 35 — Copy Job 1 script and systemd units from the laptop

**Run on:** laptop

**Risk:** Makes change (copies files to `/tmp` on the server)

**Command:**

```bash
scp scripts/k3s-server-backup.sh root@45.90.98.51:/tmp/
scp scripts/systemd/k3s-backup.service scripts/systemd/k3s-backup.timer root@45.90.98.51:/tmp/
```

**What this command does:**
Copies Job 1 and the systemd unit files to `/tmp`. It does not enable the timer.

**Why we need it:**
The repo is the one true copy of the script and units.

**Expected result:**
Three files on the server under `/tmp`.

**If result is different:**

```bash
ls scripts/k3s-server-backup.sh scripts/systemd/k3s-backup.service scripts/systemd/k3s-backup.timer
ssh root@45.90.98.51 'ls -l /tmp/k3s-server-backup.sh /tmp/k3s-backup.service /tmp/k3s-backup.timer'
```

**Verification before continuing:**

```bash
ssh root@45.90.98.51 'ls -l /tmp/k3s-server-backup.sh /tmp/k3s-backup.service /tmp/k3s-backup.timer'
```

---

### Step 36 — Install `k3s-server-backup.sh`

**Run on:** k3-master

**Risk:** Makes change (installs the backup script)

**Command:**

```bash
sudo install -m 0750 -o root -g root /tmp/k3s-server-backup.sh /usr/local/sbin/k3s-server-backup.sh
sudo install -d -m 0700 -o root -g root /var/backups/k3s
```

**What this command does:**
Installs Job 1 to `/usr/local/sbin` and creates the local staging directory.

**Why we need it:**
The systemd service calls `/usr/local/sbin/k3s-server-backup.sh`. Staging is where dry-run artifacts are left for inspection.

**Expected result:**
Script mode `750`, staging dir mode `700`.

**If result is different:**

```bash
bash -n /usr/local/sbin/k3s-server-backup.sh && echo syntax_ok
ls -l /tmp/k3s-server-backup.sh
```

**Verification before continuing:**

```bash
sudo stat -c '%a %U:%G %n' /usr/local/sbin/k3s-server-backup.sh /var/backups/k3s
bash -n /usr/local/sbin/k3s-server-backup.sh && echo syntax_ok
```

---

### Step 37 — Install the systemd service and timer (do not enable yet)

**Run on:** k3-master

**Risk:** Makes change (installs unit files only)

**Command:**

```bash
sudo install -m 0644 -o root -g root /tmp/k3s-backup.service /etc/systemd/system/k3s-backup.service
sudo install -m 0644 -o root -g root /tmp/k3s-backup.timer /etc/systemd/system/k3s-backup.timer
```

**What this command does:**
Places the service and timer units on disk. It does **not** start them.

**Why we need it:**
The timer is how Job 1 runs at 02:15 UTC. Enabling it is Day 5, after a successful manual backup.

**Expected result:**
Both files exist under `/etc/systemd/system/`.

**If result is different:**

```bash
ls -l /tmp/k3s-backup.service /tmp/k3s-backup.timer
sudo ls -l /etc/systemd/system/k3s-backup.service /etc/systemd/system/k3s-backup.timer
```

**Verification before continuing:**

```bash
sudo ls -l /etc/systemd/system/k3s-backup.service /etc/systemd/system/k3s-backup.timer
systemctl is-enabled k3s-backup.timer || true
```

Expect the files to exist, and the timer **not** enabled (`disabled` or `not-found` until reload).

---

### Step 38 — Reload systemd (required after installing unit files)

**Run on:** k3-master

**Risk:** Makes change (reloads unit metadata only; does not start K3s or the backup)

**Command:**

```bash
sudo systemctl daemon-reload
sudo systemd-analyze verify /etc/systemd/system/k3s-backup.service
```

**What this command does:**
Makes systemd read the new unit files. `daemon-reload` is required **after installing or changing** unit files. It is not required before every backup run.

**Why we need it:**
Without reload, `enable` / `start` later can use a missing or old unit.

**Expected result:**
`verify` prints no errors (empty output is OK).

**If result is different:**
If verify reports a missing file or syntax error:

```bash
sudo systemctl cat k3s-backup.service
sudo systemctl cat k3s-backup.timer
```

Fix the installed files from the repo copies, then run `daemon-reload` again.

**Verification before continuing:**

```bash
systemctl status k3s-backup.timer --no-pager || true
systemctl status k3s-backup.service --no-pager || true
```

Expect loaded units, **inactive**, timer **not** running.

---

### Step 39 — Re-run preflight WITH AWS enabled

**Run on:** k3-master

**Risk:** Makes change (uploads throwaway objects under `_preflight/` only)

**Command:**

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh
```

**What this command does:**
Repeats local checks **and** AWS checks, including a real 64 MB upload to `s3://k3-master-dr/_preflight/`.

**Why we need it:**
This is the gate before dry-run. It proves the keys on the server, the bucket, KMS, and multipart upload all work from k3-master.

**Expected result:**
Summary `READY` (exit 0) or `READY, with warnings` (exit 2). Blocking checks must not FAIL.

**If result is different:**
**Stop.** Do not dry-run and do not run a real backup.

- If `KMS_KEY_ID` is not a full ARN, fix `/etc/k3s-backup/backup.env` and re-run this step.
- If 64 MB upload fails but you thought laptop upload worked, the **server** file has the wrong keys or missing `kms:Decrypt`:

```bash
sudo grep -E '^(S3_BUCKET|AWS_REGION|KMS_KEY_ID|AWS_ACCESS_KEY_ID)=' /etc/k3s-backup/backup.env
sudo /usr/local/sbin/k3s-backup-preflight.sh
```

The script prints the exact fix command for each FAIL.

**Verification before continuing:**

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh; echo EXIT:$?
```

Continue only if exit is `0` or `2`. If exit is `1`, stop.

---

### Step 40 — Job 1 dry-run (`DRY_RUN=1`)

**Run on:** k3-master

**Risk:** Makes change (writes local staging files only; does **not** upload; does **not** write inside K3s data)

**Command:**

```bash
sudo DRY_RUN=1 /usr/local/sbin/k3s-server-backup.sh; echo EXIT:$?
```

**What this command does:**
Runs the real Job 1 path: SQLite **online backup** (not `cp`), identity tar, optional node-config tar, checksums, and `MANIFEST.json`. `DRY_RUN=1` skips S3 upload and keeps the staging directory.

**Why dry-run is required:**
It proves the snapshot, archives, manifest, and checksums on disk **before** any production objects are written to S3. It also proves we are not using a live `cp` of `state.db`.

**Expected result:**
Exit `0`. Log lines include `snapshot ok` and `integrity_check=ok`, then `DRY_RUN=1 — skipping upload`, then `completed successfully`.

**If result is different:**
If the script dies on missing config, fix `backup.env`. If disk is full:

```bash
df -h /
sudo journalctl -u k3s -n 20 --no-pager
sudo ls -la /var/lib/rancher/k3s/server/db/
```

If you see `this script takes no arguments`, you passed `db` or `full`. Run it with **no** arguments, only `DRY_RUN=1`.

**Verification before continuing:**

```bash
echo EXIT_MUST_BE_0
sudo ls -la /var/backups/k3s/
```

---

### Step 41 — Verify the generated backup directory

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo ls -lah /var/backups/k3s/*/
```

**What this command does:**
Lists today’s staging folder. The folder name is the UTC date. Filenames have no extra timestamp.

**Why we need it:**
One folder is one restore set. If the folder is missing, dry-run did not keep artifacts.

**Expected result:**
Exactly these artifacts (plus a `.sha256` next to each):

```text
state.db
k3s-identity.tar.gz
node-config.tar.gz
MANIFEST.json
```

`node-config.tar.gz` is present unless `INCLUDE_NODE_CONFIG=0`.

**If result is different:**
If the directory is empty, dry-run failed or cleanup ran without `DRY_RUN=1`:

```bash
sudo ls -la /var/backups/k3s
sudo DRY_RUN=1 /usr/local/sbin/k3s-server-backup.sh
```

If `node-config.tar.gz` is missing, check `INCLUDE_NODE_CONFIG` in `backup.env`. Default is on.

**Verification before continuing:**

```bash
sudo bash -c 'ls -1 /var/backups/k3s/*/ | sort'
```

---

### Step 42 — Verify SQLite snapshot integrity

**Run on:** k3-master

**Risk:** Read-only (opens the **snapshot**, not the live datastore)

**Command:**

```bash
sudo python3 - /var/backups/k3s/*/state.db <<'PY'
import glob, sqlite3, sys
paths = glob.glob(sys.argv[1])
if not paths:
    raise SystemExit("state.db not found")
db = sqlite3.connect(paths[0])
print("integrity_check:", db.execute("PRAGMA integrity_check").fetchone()[0])
print("tables:", [r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")])
print("kine_rows:", db.execute("SELECT count(*) FROM kine").fetchone()[0])
PY
```

**What this command does:**
Runs SQLite `integrity_check` on the backup file and counts `kine` rows.

**Why we need it:**
This is the cluster datastore. A torn copy would restore into a corrupt cluster. The live file was snapshotted with the online backup API, not `cp`.

**Expected result:**
`integrity_check: ok`, a `kine` table, and a non-zero `kine_rows` count.

**If result is different:**
If `ok` is not printed, **do not upload this snapshot**. Re-run dry-run. Confirm the live DB exists:

```bash
sudo ls -la /var/lib/rancher/k3s/server/db/
sudo python3 -c "import sqlite3; print(sqlite3.sqlite_version)"
```

Never “fix” it with `cp /var/lib/rancher/k3s/server/db/state.db`.

**Verification before continuing:**

```bash
sudo ls -lh /var/backups/k3s/*/state.db
```

Expect roughly tens of MB (often ~60–90 MB), not 0 bytes.

---

### Step 43 — Verify `MANIFEST.json` and recorded K3s version

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo python3 -m json.tool /var/backups/k3s/*/MANIFEST.json
echo "--- live k3s ---"
k3s --version
echo "--- manifest k3s_version ---"
sudo python3 -m json.tool /var/backups/k3s/*/MANIFEST.json | grep k3s_version
```

**What this command does:**
Pretty-prints the manifest and compares `k3s_version` to the live binary.

**Why we need it:**
A restore must install **exactly** this K3s version. If the manifest says `unknown`, the restore will guess and fail.

**Expected result:**
Valid JSON. `k3s_version` is a real version (for example `v1.34.5+k3s1`), **not** `unknown`, and it matches `k3s --version`. `artifact_count` matches the files you listed.

**If result is different:**
If `k3s_version` is `unknown`:

```bash
ls -l /usr/local/bin/k3s
/usr/local/bin/k3s --version
```

Fix the binary path/version, re-run dry-run, and re-check the manifest. Do not continue with `unknown`.

**Verification before continuing:**

```bash
sudo python3 -m json.tool /var/backups/k3s/*/MANIFEST.json | grep -E '"k3s_version"|"artifact_count"|"hostname"'
```

---

### Step 44 — Verify archive file listings without printing secrets

**Run on:** k3-master

**Risk:** Read-only (`tar -tzf` lists names only; it does not extract or print key material)

**Command:**

```bash
sudo tar -tzf /var/backups/k3s/*/k3s-identity.tar.gz | grep -vE '\.(key)$'
echo "--- required paths ---"
for p in var/lib/rancher/k3s/server/tls var/lib/rancher/k3s/server/cred var/lib/rancher/k3s/server/token var/lib/rancher/k3s/server/manifests etc/rancher/k3s etc/systemd/system/k3s.service; do
  sudo tar -tzf /var/backups/k3s/*/k3s-identity.tar.gz | grep -q "$p" && echo "OK   $p" || echo "MISSING  $p"
done
echo "--- node-config (names only) ---"
sudo tar -tzf /var/backups/k3s/*/node-config.tar.gz | head -40
```

**What this command does:**
Lists archive **paths**. It does not `cat` the token, private keys, or `encryption-config.json`.

**Why we need it:**
A restore unpacks this archive onto `/`. Missing `tls`, `cred`, or `token` means the identity backup is incomplete.

**Expected result:**
Each required path prints `OK`. `node-config.tar.gz` lists host files such as `node-config/netplan` / `ssh` (names only).

**If result is different:**
If any required path is `MISSING`, dry-run should have refused. Re-run dry-run and confirm those paths exist on the server:

```bash
sudo ls -ld /var/lib/rancher/k3s/server/tls /var/lib/rancher/k3s/server/cred /var/lib/rancher/k3s/server/token /etc/rancher/k3s /etc/systemd/system/k3s.service
```

Do **not** run `tar -xzf ... -O` or `cat` on token/key files.

**Verification before continuing:**

```bash
sudo tar -tzf /var/backups/k3s/*/k3s-identity.tar.gz | wc -l
```

Expect a non-zero count.

---

### Step 45 — Verify checksums

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo bash -c 'cd /var/backups/k3s/* && sha256sum -c ./*.sha256'
```

**What this command does:**
Checks each artifact against its `.sha256` file.

**Why we need it:**
The same check is used during restore. If it fails here, the restore set is already bad.

**Expected result:**
Every file prints `OK`.

**If result is different:**
Re-run dry-run. Do not upload a mismatched set:

```bash
sudo DRY_RUN=1 /usr/local/sbin/k3s-server-backup.sh
sudo bash -c 'cd /var/backups/k3s/* && sha256sum -c ./*.sha256'
```

**Verification before continuing:**

```bash
sudo bash -c 'cd /var/backups/k3s/* && sha256sum -c ./*.sha256 && echo CHECKSUMS_OK'
```

---

## DAY 5 — First real Job 1 backup, then enable the timer

### Step 46 — Run the first REAL Job 1 backup

**Run on:** k3-master

**Risk:** Makes change (uploads to S3). Does not restart K3s. Does not write into the live datastore.

**Command:**

```bash
sudo /usr/local/sbin/k3s-server-backup.sh; echo EXIT:$?
```

**What this command does:**
Builds the same artifacts as dry-run, then uploads them with SSE-KMS to `s3://k3-master-dr/k3s/daily/YYYY-MM-DD/`. On Sunday it also uploads the same files to `k3s/weekly/YYYY-MM-DD/`.

**Why we need it:**
A dry-run never proves S3. Automation must not start until this manual run succeeds.

**Expected result:**
`EXIT:0` and a log line `completed successfully`. Local staging may be deleted after a successful upload (that is normal).

**If result is different:**
If exit is not 0, **do not enable the timer**. Read the script error. If `AccessDenied` on `state.db`, it is still the multipart / `kms:Decrypt` / bare-ARN problem:

```bash
sudo grep -E '^(S3_BUCKET|AWS_REGION|KMS_KEY_ID|AWS_ACCESS_KEY_ID)=' /etc/k3s-backup/backup.env
sudo /usr/local/sbin/k3s-backup-preflight.sh
```

**Verification before continuing:**

```bash
echo "Continue only if EXIT was 0"
```

---

### Step 47 — Verify objects reached S3 on `k3s/daily/`

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
set -a
sudo sed -n '1,20p' /etc/k3s-backup/backup.env >/dev/null
set +a
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a; export AWS_DEFAULT_REGION="$AWS_REGION"; aws s3 ls "s3://$S3_BUCKET/k3s/daily/" --recursive --human-readable'
```

**What this command does:**
Lists Job 1 objects under `k3s/daily/` using the writer keys already on the server. It lists keys and sizes, not file contents.

**Why we need it:**
The backup is not real until the objects exist in S3.

**Expected result:**
A dated prefix `k3s/daily/YYYY-MM-DD/` containing:

```text
state.db
state.db.sha256
k3s-identity.tar.gz
k3s-identity.tar.gz.sha256
node-config.tar.gz
node-config.tar.gz.sha256
MANIFEST.json
MANIFEST.json.sha256
```

**Sunday `k3s/weekly/` behavior:**
If today is Sunday UTC (`date -u +%u` prints `7`), the **same** run also writes the same files under `k3s/weekly/YYYY-MM-DD/`. That is the retention design (two prefixes, two lifecycle rules). It is not a duplicate-job bug. If today is not Sunday, `k3s/weekly/` may be empty. Do not add a second scheduled job to force a weekly copy.

**If result is different:**
If `k3s/daily/` is empty, the upload failed even if you thought exit was 0. Re-run Step 46 and capture the full log:

```bash
sudo /usr/local/sbin/k3s-server-backup.sh
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a; aws s3 ls "s3://$S3_BUCKET/" --recursive | head'
```

**Verification before continuing:**

```bash
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a; export AWS_DEFAULT_REGION="$AWS_REGION"; aws s3 ls "s3://$S3_BUCKET/k3s/daily/" --recursive'
date -u +%u
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a; export AWS_DEFAULT_REGION="$AWS_REGION"; aws s3 ls "s3://$S3_BUCKET/k3s/weekly/" --recursive || true'
```

---

### Step 48 — Verify Job 1 object encryption

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a
export AWS_DEFAULT_REGION="$AWS_REGION"
DATE=$(aws s3 ls "s3://$S3_BUCKET/k3s/daily/" | awk "{print \$2}" | tr -d "/" | sort | tail -1)
echo DATE=$DATE
aws s3api head-object --bucket "$S3_BUCKET" --key "k3s/daily/$DATE/state.db" \
  --query "{SSE:ServerSideEncryption,Key:SSEKMSKeyId,Size:ContentLength}"
'
```

**What this command does:**
Checks that `state.db` in the newest daily folder is SSE-KMS with the DR key.

**Why we need it:**
Unencrypted or AES256-only objects do not match this design.

**Expected result:**
`SSE = aws:kms` and `Key` equal to the full KMS ARN in `backup.env`. Size is tens of MB.

**If result is different:**
If `NoSuchKey`, the prefix/date is wrong:

```bash
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a; aws s3 ls "s3://$S3_BUCKET/k3s/daily/" --recursive'
```

If `SSE` is not `aws:kms`, stop and fix bucket default encryption (Step 17) before more uploads.

**Verification before continuing:**

```bash
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a; echo "$KMS_KEY_ID"'
```

Confirm that printed ARN matches `Key` from `head-object` (same value; this prints the ARN, not the AWS secret).

---

### Step 49 — Enable the systemd timer (only after a successful manual backup)

**Run on:** k3-master

**Risk:** Makes change (starts daily automation)

**Command:**

```bash
sudo systemctl enable --now k3s-backup.timer
```

**What this command does:**
Enables Job 1 at boot and starts the timer. Next run is 02:15 UTC (with up to 10 minutes randomized delay).

**Why we need it:**
This is the only Job 1 schedule. Do not enable it before Steps 46–48 succeeded.

**Expected result:**
`Created symlink ... k3s-backup.timer` (or already enabled), no error.

**If result is different:**
If `Unit not found`, unit files are missing or `daemon-reload` was skipped:

```bash
sudo ls -l /etc/systemd/system/k3s-backup.timer /etc/systemd/system/k3s-backup.service
sudo systemctl daemon-reload
sudo systemctl enable --now k3s-backup.timer
```

**Verification before continuing:**

```bash
systemctl is-enabled k3s-backup.timer
systemctl is-active k3s-backup.timer
```

Expect `enabled` and `active`.

---

### Step 50 — Verify timer status and next scheduled run

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
systemctl list-timers 'k3s-backup*' --all --no-pager
systemctl status k3s-backup.timer --no-pager
```

**What this command does:**
Shows whether the timer is active and **when it will fire next**.

**Why we need it:**
`enabled` without a next run means the calendar is not loaded.

**Expected result:**
`k3s-backup.timer` with a `NEXT` time around `02:15:00 UTC` (plus up to 600 seconds random delay). `Unit` is `k3s-backup.service`.

**If result is different:**
If `NEXT` is empty:

```bash
systemctl cat k3s-backup.timer
sudo systemctl daemon-reload
sudo systemctl restart k3s-backup.timer
systemctl list-timers 'k3s-backup*' --all --no-pager
```

**Verification before continuing:**

```bash
systemctl list-timers 'k3s-backup*' --all --no-pager
```

Do not continue to Velero until `NEXT` is visible.

---

### Step 51 — Job 1 logs (`journalctl`)

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo journalctl -u k3s-backup.service -n 50 --no-pager
sudo journalctl -u k3s-backup.service --since '48 hours ago' --no-pager | tail -30
```

**What this command does:**
Shows backup service logs. The timer itself has little output; the service unit has the run log.

**Why we need it:**
After the first scheduled night, this is how you confirm `completed successfully` without opening S3 first.

**Expected result:**
For the manual run you may see no service log yet if you invoked the script directly. After a `systemctl start` or timer fire, look for `completed successfully` and `status=0/SUCCESS`.

**If result is different:**
To produce a service log once without waiting for 02:15 (optional; only if Steps 46–48 already succeeded):

```bash
sudo systemctl start k3s-backup.service
sudo journalctl -u k3s-backup.service -n 40 --no-pager
```

**Verification before continuing:**

```bash
sudo journalctl -u k3s-backup.timer -n 20 --no-pager
```

---

## DAY 6–7 — Install and validate Velero (Job 2)

Job 1 cannot restore a deleted PVC or a single deleted Secret. Velero is Job 2 of 2.

Keep `defaultVolumesToFsBackup: true`. Do **not** use CSI snapshots.

### Step 52 — Install the Velero CLI

**Run on:** k3-master

**Risk:** Makes change (installs a binary)

**Command:**

```bash
VELERO_VERSION=v1.14.1
curl -fsSL -o /tmp/velero.tar.gz \
  "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-amd64.tar.gz"
tar -xzf /tmp/velero.tar.gz -C /tmp
sudo install -m 0755 /tmp/velero-${VELERO_VERSION}-linux-amd64/velero /usr/local/bin/velero
velero version --client-only
```

**What this command does:**
Installs Velero CLI `v1.14.1`, which matches the AWS plugin version pinned in `scripts/velero/install-velero.sh` (`v1.10.0`).

**Why we need it:**
`velero install`, `backup get`, and restore commands need this binary. Pin the version; do not leave it floating.

**Expected result:**
`Client: version: v1.14.1` (or the version you installed).

**If result is different:**
If `curl` fails, check outbound HTTPS. If the arch is not amd64:

```bash
uname -m
```

For `aarch64`, download `linux-arm64` instead of `linux-amd64` from the same GitHub release, then retry `install`.

**Verification before continuing:**

```bash
command -v velero
velero version --client-only
```

---

### Step 53 — Create the Velero credentials file on k3-master (writer keys only)

**Run on:** k3-master

**Risk:** Makes change (writes a credentials file)

**Command:**

```bash
sudo bash -c 'umask 077
set -a; . /etc/k3s-backup/backup.env; set +a
cat > /etc/k3s-backup/velero-credentials <<EOF
[default]
aws_access_key_id=${AWS_ACCESS_KEY_ID}
aws_secret_access_key=${AWS_SECRET_ACCESS_KEY}
EOF
chmod 0600 /etc/k3s-backup/velero-credentials
chown root:root /etc/k3s-backup/velero-credentials
'
```

**What this command does:**
Writes an AWS credentials file for Velero using the **same Backup Writer** keys already in `backup.env`. It does not print the secret.

**Why we need it:**
`velero install --secret-file` needs this format. Use writer keys so Velero can put objects and delete `velero/*` for TTL. Do **not** put restore-reader keys here.

**Expected result:**
File mode `600`, owner `root`. The file contains `[default]` and two keys. Do not `cat` it in logs or tickets.

**If result is different:**

```bash
sudo stat -c '%a %U:%G %n' /etc/k3s-backup/velero-credentials
sudo grep -c 'aws_access_key_id=' /etc/k3s-backup/velero-credentials
```

Expect `600 root:root` and count `1`. If count is 0, `backup.env` was not sourced.

**Verification before continuing:**

```bash
sudo stat -c '%a %U:%G %n' /etc/k3s-backup/velero-credentials
```

---

### Step 54 — Discover the K3s kubelet root path (before trusting PVC backups)

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
echo "=== kubelet cmdline root-dir ==="
sudo tr '\0' '\n' < /proc/$(pgrep -n -f 'kubelet')/cmdline | grep -E 'root-dir|^/var' || true
echo "=== candidate directories ==="
ls -ld /var/lib/kubelet /var/lib/kubelet/pods \
  /var/lib/rancher/k3s/agent/kubelet /var/lib/rancher/k3s/agent/kubelet/pods 2>&1
echo "=== resolved paths ==="
readlink -f /var/lib/kubelet 2>/dev/null || true
readlink -f /var/lib/rancher/k3s/agent/kubelet 2>/dev/null || true
```

**What this command does:**
Finds the kubelet `--root-dir` and whether `/var/lib/kubelet` is a real directory or a symlink to the K3s path.

**Why we need it:**
Velero node-agent reads pod volumes through a `hostPath` into the kubelet pods directory. K3s often uses `/var/lib/rancher/k3s/agent/kubelet`, not `/var/lib/kubelet`. If those paths do not match, the node-agent starts cleanly and backs up **no** PVC files.

**Expected result:**
You can write down **one** kubelet root, usually `/var/lib/rancher/k3s/agent/kubelet`, and confirm a `pods` directory exists under it. If `/var/lib/kubelet` resolves to the same path, Velero’s default may already match.

**If result is different:**
If `pgrep` finds nothing:

```bash
ps -ef | grep -i kubelet | grep -v grep
ls -ld /var/lib/rancher/k3s/agent/kubelet/pods
```

Do not skip this. Do not trust PVC backups until Step 56 confirms the DaemonSet `hostPath` matches this root.

**Verification before continuing:**

```bash
ls -ld /var/lib/rancher/k3s/agent/kubelet/pods
```

---

### Step 55 — Install Velero server, AWS plugin, node-agent, S3 location, filesystem backup

**Run on:** k3-master

**Risk:** Makes change (creates the `velero` namespace and controllers)

**Command:**

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export S3_BUCKET AWS_REGION KMS_KEY_ID
export CREDS_FILE=/etc/k3s-backup/velero-credentials
cd /root
'
```

Copy `scripts/velero/install-velero.sh` first if it is not on the server:

```bash
# from laptop
scp scripts/velero/install-velero.sh root@45.90.98.51:/tmp/
```

Then on k3-master:

```bash
sudo install -m 0750 -o root -g root /tmp/install-velero.sh /usr/local/sbin/install-velero.sh
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export S3_BUCKET AWS_REGION KMS_KEY_ID
export CREDS_FILE=/etc/k3s-backup/velero-credentials
/usr/local/sbin/install-velero.sh
'
```

**What this command does:**
Runs the existing installer. It installs Velero with the AWS plugin, prefix `velero`, SSE-KMS, **`--use-node-agent`**, **`--default-volumes-to-fs-backup`**, `--uploader-type kopia`, and **`--use-volume-snapshots=false`** (no CSI).

**Why we need it:**
This is Job 2. File-system backup is the only method that works with `local-path` PVCs. CSI snapshots are not used.

**Expected result:**
Installer waits until Velero is ready. `velero` namespace exists.

**If result is different:**
If `velero CLI not found`, complete Step 52. If `cannot read CREDS_FILE`, complete Step 53. If `AccessDenied` to S3, the writer policy or KMS ARN is wrong:

```bash
sudo k3s kubectl -n velero get pods
sudo k3s kubectl -n velero logs deploy/velero --tail=80
```

**Verification before continuing:**

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml k3s kubectl -n velero get pods
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup-location get
```

---

### Step 56 — Inspect node-agent hostPath and match it to the kubelet root

**Run on:** k3-master

**Risk:** Read-only unless you must patch (patch is Makes change)

**Command:**

```bash
sudo k3s kubectl -n velero get ds node-agent -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\t"}{.hostPath.path}{"\n"}{end}'
echo "--- kubelet pods dir ---"
ls -ld /var/lib/kubelet/pods /var/lib/rancher/k3s/agent/kubelet/pods 2>&1
echo "--- resolved ---"
readlink -f /var/lib/kubelet 2>/dev/null || true
readlink -f /var/lib/rancher/k3s/agent/kubelet 2>/dev/null || true
```

**What this command does:**
Prints every node-agent `hostPath`. The pods volume must be `<kubelet-root>/pods`.

**Why we need it:**
**What must match:** node-agent `hostPath` for pod volumes = the real K3s kubelet `pods` directory from Step 54. If Velero uses `/var/lib/kubelet/pods` but kubelet stores pods only under `/var/lib/rancher/k3s/agent/kubelet/pods`, and those are **not** the same directory (no symlink), PVC backups will be empty while the backup still says Completed.

**Do not trust PVC backups until this matches.**

**Expected result:**
A volume (often `host-pods`) whose `hostPath` is the same directory you confirmed in Step 54 (or a symlink to it). Node-agent pod `Running`.

**If result is different:**
If `host-pods` is `/var/lib/kubelet/pods` but the real directory is `/var/lib/rancher/k3s/agent/kubelet/pods` and they are **not** the same resolved path, patch the DaemonSet, then wait for a new pod:

```bash
REAL_PODS=/var/lib/rancher/k3s/agent/kubelet/pods
ls -ld "$REAL_PODS"
sudo k3s kubectl -n velero get ds node-agent -o json | sudo python3 -c "
import json,sys
root=sys.argv[1]
d=json.load(sys.stdin)
old='/var/lib/kubelet'
for v in d.get('spec',{}).get('template',{}).get('spec',{}).get('volumes',[]):
    hp=v.get('hostPath') or {}
    p=hp.get('path') or ''
    if p.startswith(old):
        hp['path']=root+p[len(old):]
        v['hostPath']=hp
json.dump(d, sys.stdout)
" /var/lib/rancher/k3s/agent/kubelet | sudo k3s kubectl apply -f -
sudo k3s kubectl -n velero rollout status ds/node-agent --timeout=180s
sudo k3s kubectl -n velero get ds node-agent -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\t"}{.hostPath.path}{"\n"}{end}'
```

**Verification before continuing:**

```bash
sudo k3s kubectl -n velero get ds node-agent -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\t"}{.hostPath.path}{"\n"}{end}'
sudo k3s kubectl -n velero get pods -l name=node-agent
```

---

### Step 57 — Confirm BackupStorageLocation is Available

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup-location get
sudo k3s kubectl -n velero get backupstoragelocation
```

**What this command does:**
Shows whether Velero can reach `s3://k3-master-dr/velero/`.

**Why we need it:**
If the location is not `Available`, backups cannot be stored.

**Expected result:**
`default` (or the installed name) phase `Available`. Provider `aws`, bucket `k3-master-dr`, prefix `velero`.

**If result is different:**

```bash
sudo k3s kubectl -n velero get backupstoragelocation -o yaml
sudo k3s kubectl -n velero logs deploy/velero --tail=100
```

Look for `AccessDenied`, wrong region, or wrong KMS ARN. Fix `backup.env` / writer policy / install flags, then re-run the installer.

**Verification before continuing:**

```bash
sudo k3s kubectl -n velero get backupstoragelocation -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}'
```

Expect `Available`. Do not apply schedules until this is true.

---

### Step 58 — Apply the daily Velero schedule (TTL 168h)

**Run on:** k3-master

**Risk:** Makes change (creates a Schedule)

**Command:**

Copy the file if needed:

```bash
# from laptop
scp scripts/velero/schedule-daily.yaml root@45.90.98.51:/tmp/
```

On k3-master, apply this YAML (same as the repo file):

```yaml
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily
  namespace: velero
spec:
  schedule: "0 3 * * *"
  useOwnerReferencesInBackup: false
  template:
    ttl: 168h0m0s
    includeClusterResources: true
    defaultVolumesToFsBackup: true
    snapshotVolumes: false
    storageLocation: default
    metadata:
      labels:
        tier: daily
```

```bash
sudo k3s kubectl apply -f /tmp/schedule-daily.yaml
```

If you did not copy the file, apply stdin:

```bash
sudo k3s kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: daily
  namespace: velero
spec:
  schedule: "0 3 * * *"
  useOwnerReferencesInBackup: false
  template:
    ttl: 168h0m0s
    includeClusterResources: true
    defaultVolumesToFsBackup: true
    snapshotVolumes: false
    storageLocation: default
    metadata:
      labels:
        tier: daily
EOF
```

**What this command does:**
Schedules Job 2 daily at **03:00 UTC**, 45 minutes after Job 1 (02:15). TTL `168h` keeps ~7 daily Velero backups. `snapshotVolumes: false` — no CSI. `defaultVolumesToFsBackup: true` stays on.

**Why we need it:**
This is the daily Job 2 schedule. Do not add extra scheduled jobs.

**Expected result:**
`schedule.velero.io/daily created` (or `configured`).

**If result is different:**

```bash
sudo k3s kubectl -n velero get schedule daily -o yaml
sudo k3s kubectl -n velero get crd | grep velero
```

If CRDs are missing, Step 55 did not finish.

**Verification before continuing:**

```bash
sudo k3s kubectl -n velero get schedule daily -o jsonpath='{.spec.schedule}{" ttl="}{.spec.template.ttl}{" fsb="}{.spec.template.defaultVolumesToFsBackup}{" snap="}{.spec.template.snapshotVolumes}{"\n"}'
```

Expect `0 3 * * *`, ttl `168h0m0s`, fsb `true`, snap `false`.

---

### Step 59 — Apply the weekly Velero schedule (~4 weekly backups)

**Run on:** k3-master

**Risk:** Makes change

**Command:**

```bash
sudo k3s kubectl apply -f - <<'EOF'
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: weekly
  namespace: velero
spec:
  schedule: "0 4 * * 0"
  useOwnerReferencesInBackup: false
  template:
    ttl: 720h0m0s
    includeClusterResources: true
    defaultVolumesToFsBackup: true
    snapshotVolumes: false
    storageLocation: default
    metadata:
      labels:
        tier: weekly
EOF
```

**What this command does:**
Schedules Job 2 weekly at **04:00 UTC on Sunday**, one hour after the daily Velero run so they never overlap. TTL `720h` is 30 days (~4 weekly backups). Same FSB settings, no CSI.

**Why we need it:**
Together with daily TTL 168h, this is the 7 daily + 4 weekly retention for Job 2. Daily and weekly stay staggered from each other and from Job 1.

**Expected result:**
`schedule.velero.io/weekly created` (or `configured`).

**If result is different:**

```bash
sudo k3s kubectl -n velero get schedule -o wide
```

**Verification before continuing:**

```bash
sudo k3s kubectl -n velero get schedule -o custom-columns=NAME:.metadata.name,CRON:.spec.schedule,TTL:.spec.template.ttl
```

Expect `daily` `0 3 * * *` `168h0m0s` and `weekly` `0 4 * * 0` `720h0m0s`.

---

### Step 60 — Create a manual Velero verification backup and wait

**Run on:** k3-master

**Risk:** Makes change (creates a backup; read-only against app data)

**Command:**

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
VERIFY_NAME=verify-$(date +%s)
echo "VERIFY_NAME=$VERIFY_NAME"
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup create "$VERIFY_NAME" --wait
```

**What this command does:**
Creates one on-demand backup of the whole cluster with default FSB, and waits until Velero finishes.

**Why we need it:**
Schedules have not proven PVC capture yet. A green Completed flag is **not** enough.

**Expected result:**
The command exits 0. Backup phase becomes `Completed`.

**If result is different:**
If it stays `InProgress` or `Failed`:

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup describe "$VERIFY_NAME" --details
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup logs "$VERIFY_NAME" | tail -80
```

**Verification before continuing:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
```

---

### Step 61 — Describe backup, logs, and Kubernetes objects

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
VERIFY_NAME=$(sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get -o json | python3 -c 'import json,sys; items=json.load(sys.stdin).get("items") or []; items=[i for i in items if str(i.get("metadata",{}).get("name","")).startswith("verify-")]; items.sort(key=lambda i: i["metadata"]["creationTimestamp"]); print(items[-1]["metadata"]["name"] if items else "")')
echo "VERIFY_NAME=$VERIFY_NAME"
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup describe "$VERIFY_NAME" --details
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup logs "$VERIFY_NAME" | tail -100
```

If `VERIFY_NAME` is empty, use the name printed in Step 60.

**What this command does:**
Shows backup status, included resources, and recent logs. `describe --details` is where **Pod Volume Backups** appear.

**Why we need it:**
We must see real Kubernetes objects (namespaces, workloads, Secrets **listed by name only**) and, separately, PVC file-system backups.

**Expected result:**
Phase `Completed`. Resource list includes namespaces such as `kube-system`, `monitoring`, `argocd`. Errors in logs are not ignored if they mention volumes.

**If result is different:**
If phase is `PartiallyFailed` or `Failed`, open logs:

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup logs "$VERIFY_NAME" | grep -iE 'error|fail|denied|timeout' | tail -50
```

Fix the cause, create a **new** `verify-$(date +%s)` backup, do not reuse a failed one as proof.

**Verification before continuing:**

```bash
sudo k3s kubectl get ns
sudo k3s kubectl get secrets -A --no-headers | wc -l
```

Secrets must exist in the live cluster (count > 0). Do not print Secret values.

---

### Step 62 — Verify all six monitoring PVCs in Pod Volume Backups

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
echo "=== live PVCs (expect six in monitoring) ==="
sudo k3s kubectl get pvc -A
echo "=== PodVolumeBackup objects for this backup ==="
sudo k3s kubectl -n velero get podvolumebackups -o wide
sudo k3s kubectl -n velero get podvolumebackups -l velero.io/backup-name="$VERIFY_NAME"
echo "=== node-agent pods ==="
sudo k3s kubectl -n velero get pods -l name=node-agent -o wide
echo "=== backup repositories ==="
sudo k3s kubectl -n velero get backuprepositories
echo "=== BackupStorageLocation ==="
sudo k3s kubectl -n velero get backupstoragelocation
```

**What this command does:**
Lists live PVCs, then Velero PodVolumeBackup objects, node-agent pods, backup repositories, and BSL.

**Why we need it:**
The six monitoring volumes are Prometheus, Loki/MinIO, Loki backend, Loki write, Grafana, and Alertmanager. They must appear as Pod Volume Backups for `$VERIFY_NAME`.

**If the backup says Completed but Pod Volume Backups are missing or empty, treat the backup as FAILED for PVC protection.** Do not trust it. Go back to Step 54–56 (kubelet path / hostPath) and create a new verify backup.

**Expected result:**
`kubectl get pvc -A` shows **six** Bound PVCs in `monitoring`.
`podvolumebackups` for `$VERIFY_NAME` has **six** entries (one per those volumes), phase `Completed`.
node-agent is `Running`.
`backuprepositories` exist and are not Failed.
BSL is `Available`.

**If result is different:**
If PVC count is not 6, list them and stop guessing:

```bash
sudo k3s kubectl -n monitoring get pvc
```

If PVCs exist but `podvolumebackups` is empty:

```bash
sudo k3s kubectl -n velero get ds node-agent -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\t"}{.hostPath.path}{"\n"}{end}'
sudo k3s kubectl -n velero logs -l name=node-agent --tail=80
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup describe "$VERIFY_NAME" --details | grep -A40 'Pod Volume Backup'
```

Fix hostPath, then run a **new** `velero backup create verify-$(date +%s) --wait`.

**Verification before continuing:**

```bash
sudo k3s kubectl -n velero get podvolumebackups --no-headers | wc -l
sudo k3s kubectl -n monitoring get pvc --no-headers | wc -l
```

---

### Step 63 — Safe Kubernetes object restore test (scratch ConfigMap)

**Run on:** k3-master

**Risk:** Makes change (scratch namespace only)

**Command:**

```bash
sudo k3s kubectl create namespace backup-cm-test
sudo k3s kubectl -n backup-cm-test create configmap restore-probe --from-literal=probe=k3-backup-cm-ok
sudo k3s kubectl -n backup-cm-test get configmap restore-probe -o jsonpath='{.data.probe}{"\n"}'
CM_BACKUP=cm-probe-$(date +%s)
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup create "$CM_BACKUP" --include-namespaces backup-cm-test --wait
sudo k3s kubectl -n backup-cm-test delete configmap restore-probe
sudo k3s kubectl -n backup-cm-test get configmap restore-probe || true
CM_RESTORE=cm-restore-$(date +%s)
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore create "$CM_RESTORE" --from-backup "$CM_BACKUP" --wait
sudo k3s kubectl -n backup-cm-test get configmap restore-probe -o jsonpath='{.data.probe}{"\n"}'
```

**What this command does:**
Creates a harmless ConfigMap in a scratch namespace, backs it up, deletes **only** that ConfigMap, restores it, and prints the restored value.

**Why we need it:**
This proves Job 2 can restore a single Kubernetes object without touching production namespaces.

**Expected result:**
Before delete: `k3-backup-cm-ok`. After delete: ConfigMap not found. After restore: `k3-backup-cm-ok` again. Restore phase `Completed`.

**If result is different:**
If restore Completed but ConfigMap is missing:

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore describe "$CM_RESTORE" --details
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore logs "$CM_RESTORE" | tail -50
sudo k3s kubectl -n backup-cm-test get all,cm
```

Do not retry against `monitoring` or `argocd`.

**Verification before continuing:**

```bash
sudo k3s kubectl -n backup-cm-test get configmap restore-probe -o jsonpath='{.data.probe}{"\n"}'
sudo k3s kubectl delete namespace backup-cm-test
```

Expect `k3-backup-cm-ok`, then namespace deleted.

---

### Step 64 — Safe PVC restore test (scratch PVC only, checksum)

**Run on:** k3-master

**Risk:** Makes change (scratch namespace / test PVC only)

**Command:**

```bash
sudo k3s kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: backup-pvc-test
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: probe-pvc
  namespace: backup-pvc-test
spec:
  accessModes: [ "ReadWriteOnce" ]
  storageClassName: local-path
  resources:
    requests:
      storage: 64Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: probe-pod
  namespace: backup-pvc-test
spec:
  containers:
    - name: box
      image: busybox:1.36
      command: ["sh", "-c", "echo k3-backup-pvc-ok > /data/probe.txt && sha256sum /data/probe.txt > /data/probe.txt.sha256 && sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: probe-pvc
EOF
sudo k3s kubectl -n backup-pvc-test wait --for=condition=Ready pod/probe-pod --timeout=180s
echo "=== original checksum ==="
sudo k3s kubectl -n backup-pvc-test exec probe-pod -- cat /data/probe.txt.sha256
ORIG=$(sudo k3s kubectl -n backup-pvc-test exec probe-pod -- cat /data/probe.txt.sha256)
PVC_BACKUP=pvc-probe-$(date +%s)
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup create "$PVC_BACKUP" \
  --include-namespaces backup-pvc-test \
  --default-volumes-to-fs-backup \
  --wait
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup describe "$PVC_BACKUP" --details
sudo k3s kubectl -n velero get podvolumebackups -l velero.io/backup-name="$PVC_BACKUP"
```

**Stop here if this backup has no PodVolumeBackup.** Treat it as failed. Do not delete anything yet. Fix node-agent hostPath (Step 56), then create a new backup name.

Then remove **only** the test resources and restore them:

```bash
sudo k3s kubectl delete namespace backup-pvc-test
PVC_RESTORE=pvc-restore-$(date +%s)
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore create "$PVC_RESTORE" --from-backup "$PVC_BACKUP" --wait
sudo k3s kubectl -n backup-pvc-test wait --for=condition=Ready pod/probe-pod --timeout=300s
echo "=== restored checksum ==="
sudo k3s kubectl -n backup-pvc-test exec probe-pod -- cat /data/probe.txt.sha256
sudo k3s kubectl -n backup-pvc-test exec probe-pod -- sha256sum -c /data/probe.txt.sha256
```

**What this command does:**
Writes a known file to a **new** test PVC, records SHA256, backs it up with Velero FSB, deletes only the test namespace, restores it, and checks the checksum.

**Why we need it:**
This is the proof that file-system backup can restore volume bytes. It is **not** a restore of Prometheus, Loki, Grafana, MinIO, or Alertmanager.

**Do NOT use Prometheus, Loki, Grafana, MinIO, Alertmanager, or any production PVC for this first restore test.**

**Expected result:**
Original and restored `probe.txt.sha256` lines are identical. `sha256sum -c` prints `probe.txt: OK`. Restore `Completed`. One PodVolumeBackup for `pvc-probe-*`.

**If result is different:**
If the pod never becomes Ready after restore:

```bash
sudo k3s kubectl -n backup-pvc-test get pvc,pod -o wide
sudo k3s kubectl -n backup-pvc-test describe pod probe-pod | tail -40
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore describe "$PVC_RESTORE" --details
```

If checksums differ, the PVC restore failed. Do not mark Job 2 accepted.

**Verification before continuing:**

```bash
sudo k3s kubectl -n backup-pvc-test exec probe-pod -- cat /data/probe.txt
sudo k3s kubectl delete namespace backup-pvc-test
```

Expect `k3-backup-pvc-ok`, then namespace deleted.

---

## WEEK 2+ — Monitor backups

Let both jobs run on their own for a week before you rely on them.

### Step 65 — Latest Job 1 backup and S3 newest object

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a
export AWS_DEFAULT_REGION="$AWS_REGION"
echo "=== k3s/daily ==="
aws s3 ls "s3://$S3_BUCKET/k3s/daily/"
echo "=== newest daily objects ==="
aws s3 ls "s3://$S3_BUCKET/k3s/daily/" --recursive --human-readable | tail
echo "=== k3s/weekly ==="
aws s3 ls "s3://$S3_BUCKET/k3s/weekly/" || true
'
```

**What this command does:**
Shows Job 1 prefixes and the newest uploaded objects.

**Why we need it:**
The newest dated folder under `k3s/daily/` should be **today or yesterday** (UTC). If it is older than 2 days, Job 1 is failing silently.

**Expected result:**
One new dated folder per day under `k3s/daily/`. After the first Sunday, also `k3s/weekly/`.

**If result is different:**
If the newest daily folder is stale:

```bash
systemctl list-timers 'k3s-backup*' --no-pager
sudo journalctl -u k3s-backup.service --since '48 hours ago' --no-pager | tail -50
```

**Verification before continuing:**

```bash
sudo bash -c 'set -a; . /etc/k3s-backup/backup.env; set +a; aws s3 ls "s3://$S3_BUCKET/" --recursive --human-readable | tail'
```

---

### Step 66 — systemd timer, Job 1 service logs, disk space

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
systemctl list-timers 'k3s-backup*' --all --no-pager
systemctl is-enabled k3s-backup.timer
systemctl is-active k3s-backup.timer
sudo journalctl -u k3s-backup.service --since '48 hours ago' --no-pager | tail -30
df -h /
df -i /
```

**What this command does:**
Checks the timer, recent Job 1 logs, and free disk/inodes.

**Why we need it:**
Job 1 stages under `/var/backups/k3s` and refuses to run if free space is under 2 GB. A full disk stops backups.

**Expected result:**
Timer `enabled`/`active`, a `NEXT` run, logs with `completed successfully`, `/` has several GB free (stop and free space if under 5 GB).

**If result is different:**
If logs show checksum or upload errors, do not ignore them. If disk is low:

```bash
sudo du -sh /var/backups/k3s /var/lib/rancher/k3s /var/log 2>/dev/null
sudo find /var/backups/k3s -maxdepth 1 -mindepth 1 -type d -mtime +3 -print
```

The script already prunes staging older than 3 days. Do not delete S3 backups from k3-master (writer cannot delete `k3s/` anyway).

**Verification before continuing:**

```bash
df -h /
systemctl list-timers 'k3s-backup*' --no-pager
```

---

### Step 67 — Latest Velero backup, BSL, PodVolumeBackup, node-agent

**Run on:** k3-master

**Risk:** Read-only

**Command:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
sudo k3s kubectl -n velero get backupstoragelocation
sudo k3s kubectl -n velero get podvolumebackups --sort-by=.metadata.creationTimestamp | tail -20
sudo k3s kubectl -n velero get pods -l name=node-agent
sudo k3s kubectl -n velero get backuprepositories
sudo k3s kubectl -n velero get schedule
```

**What this command does:**
Shows the latest Job 2 backups and whether PVC captures and the node-agent are healthy.

**Why we need it:**
A daily Velero backup should appear without anyone running a command. Completed **without** new PodVolumeBackups is still a PVC failure.

**Expected result:**
A new Velero backup each day. BSL `Available`. node-agent `Running`. Latest backup has PodVolumeBackups for the six monitoring PVCs.

**If result is different:**
If no new backup since yesterday:

```bash
sudo k3s kubectl -n velero get schedule daily -o yaml
sudo k3s kubectl -n velero logs deploy/velero --tail=80
```

If backups exist but PodVolumeBackups are missing, treat PVC protection as failed and return to Step 56.

**Verification before continuing:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
sudo k3s kubectl -n velero get backupstoragelocation -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}'
```

---

## Full-server restore (throwaway Ubuntu host)

Test this on a **throwaway** server first. Record how long it takes. That number is the real restore time.

Use the **restore-reader** keys from Step 28. Do not copy them onto production k3-master.

Replacement host target: Ubuntu 24.04 LTS, similar CPU/RAM/disk, hostname **`k3-master`**, x86_64 unless `MANIFEST.json` says otherwise.

### Step 68 — Prepare a fresh Ubuntu server

**Run on:** throwaway restore host

**Risk:** Makes change (on the throwaway host only)

**Command:**

```bash
sudo hostnamectl set-hostname k3-master
hostname
cat /etc/os-release | grep PRETTY_NAME
uname -m
df -h /
```

**What this command does:**
Sets hostname to `k3-master` and shows OS/arch/disk.

**Why we need it:**
K3s identifies the node by name inside the datastore. A different hostname registers a second node and leaves the original `NotReady`.

**Expected result:**
`hostname` prints `k3-master`. Ubuntu 24.04 (or the `os_release` from the manifest). Enough disk for K3s plus PVC restore (~97 GB was the original class of machine).

**If result is different:**
If hostname did not stick, reboot and re-check `hostname`. Do not install K3s until the name is `k3-master`.

**Verification before continuing:**

```bash
hostnamectl | head -3
```

---

### Step 69 — Configure restore-reader AWS credentials on the throwaway host

**Run on:** throwaway restore host / AWS CLI

**Risk:** Makes change (credentials on the throwaway host, not production)

**Command:**

```bash
export AWS_ACCESS_KEY_ID=<RESTORE_READER_ACCESS_KEY_ID>
export AWS_SECRET_ACCESS_KEY=<RESTORE_READER_SECRET_ACCESS_KEY>
export AWS_DEFAULT_REGION=ap-south-1
export BUCKET=k3-master-dr
aws sts get-caller-identity
aws s3 ls "s3://$BUCKET/k3s/daily/"
aws s3 ls "s3://$BUCKET/k3s/weekly/"
```

**What this command does:**
Logs in as the restore reader and lists available Job 1 restore sets.

**Why we need it:**
The production writer keys may be gone with the old server. Restore must work with the offline reader login.

**Expected result:**
`get-caller-identity` shows `k3-master-restore-reader`. Dated folders appear under `k3s/daily/` and possibly `k3s/weekly/`.

**If result is different:**
If `AccessDenied` on list, you used writer vs reader mixed up, or the reader policy is missing:

```bash
aws sts get-caller-identity
aws s3 ls
```

**Verification before continuing:**

```bash
aws s3 ls "s3://$BUCKET/k3s/daily/"
```

---

### Step 70 — Download the selected Job 1 backup set

**Run on:** throwaway restore host

**Risk:** Read-only against S3 (download)

**Command:**

```bash
mkdir -p ~/k3-restore && cd ~/k3-restore
DATE=$(aws s3 ls "s3://$BUCKET/k3s/daily/" | awk '{print $2}' | tr -d '/' | sort | tail -1)
echo "SELECTED_DATE=$DATE"
aws s3 cp "s3://$BUCKET/k3s/daily/$DATE/" . --recursive
ls -lah
```

To use a weekly set instead, change the prefix to `k3s/weekly/` and pick that date.

**What this command does:**
Downloads one complete restore set (every file in that dated folder).

**Why we need it:**
One folder is one restore. Do not mix files from two dates.

**Expected result:**
`state.db`, `k3s-identity.tar.gz`, `node-config.tar.gz` (if enabled), `MANIFEST.json`, and `.sha256` files.

**If result is different:**

```bash
aws s3 ls "s3://$BUCKET/k3s/daily/$DATE/"
```

If `kms:Decrypt` fails, the reader policy is missing KMS decrypt on the DR key.

**Verification before continuing:**

```bash
ls -lh ~/k3-restore
```

---

### Step 71 — Verify SHA256 and inspect `MANIFEST.json`

**Run on:** throwaway restore host

**Risk:** Read-only

**Command:**

```bash
cd ~/k3-restore
sha256sum -c ./*.sha256
python3 -m json.tool MANIFEST.json
python3 -m json.tool MANIFEST.json | grep k3s_version
```

**What this command does:**
Verifies checksums, then prints the manifest. Read `k3s_version` from the file. Do not guess the version from memory or from this paragraph.

**Why we need it:**
Installing the wrong K3s version is the fastest way to turn restore into a debug session.

**Expected result:**
All checksums `OK`. `k3s_version` is a concrete value, not `unknown`.

**If result is different:**
If checksums fail, re-download that date. Do not restore a truncated `state.db`.

```bash
rm -f ~/k3-restore/*
aws s3 cp "s3://$BUCKET/k3s/daily/$DATE/" ~/k3-restore/ --recursive
cd ~/k3-restore && sha256sum -c ./*.sha256
```

**Verification before continuing:**

```bash
python3 -m json.tool ~/k3-restore/MANIFEST.json | grep -E 'k3s_version|os_release|arch|artifact_count'
```

---

### Step 72 — Inspect host config archive (do not blindly overwrite `/etc`)

**Run on:** throwaway restore host

**Risk:** Read-only unless you copy selected files

**Command:**

```bash
cd ~/k3-restore
tar -tzf node-config.tar.gz | head -50
mkdir -p /tmp/node-config-inspect
tar -xzf node-config.tar.gz -C /tmp/node-config-inspect
ls /tmp/node-config-inspect
```

**What this command does:**
Lists and extracts node-config to `/tmp` for inspection (netplan, ufw, ssh, package list).

**Why we need it:**
You apply **what you need** (static IP, firewall) from this archive. Blindly unpacking onto `/` of a new OS can break SSH.

**Expected result:**
Readable files under `/tmp/node-config-inspect`. You copy selected settings, not the whole tree, onto the new host.

**If result is different:**
If `node-config.tar.gz` is missing, Job 1 ran with `INCLUDE_NODE_CONFIG=0`. Set hostname, network, and firewall by hand from your own notes.

**Verification before continuing:**

```bash
hostname
ip -br addr
```

---

### Step 73 — Install the matching K3s version from the manifest

**Run on:** throwaway restore host

**Risk:** Makes change / Production-impacting on this host (installs K3s)

**Command:**

```bash
cd ~/k3-restore
K3S_VER=$(python3 -c 'import json; print(json.load(open("MANIFEST.json"))["k3s_version"])')
echo "INSTALL_K3S_VERSION=$K3S_VER"
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VER" sh -
```

**What this command does:**
Installs **exactly** the K3s version recorded in `MANIFEST.json`, then lets the installer start K3s once so systemd units exist.

**Why we need it:**
The snapshot is not portable across K3s versions.

**Expected result:**
`k3s --version` matches `MANIFEST.json`. `systemctl is-active k3s` is `active` (you will stop it next).

**If result is different:**
If the installer pulls a different version, you omitted `INSTALL_K3S_VERSION`. Uninstall and retry:

```bash
k3s --version
python3 -m json.tool ~/k3-restore/MANIFEST.json | grep k3s_version
```

**Verification before continuing:**

```bash
k3s --version
systemctl is-active k3s
```

---

### Step 74 — Stop K3s before restoring data

**Run on:** throwaway restore host

**Risk:** ⚠️ RESTORE ONLY / DESTRUCTIVE (stops the Kubernetes API on this host)

**Command:**

```bash
sudo systemctl stop k3s
systemctl is-active k3s || echo k3s_stopped
```

**What this command does:**
Stops K3s so it cannot write to the datastore you are about to replace.

**Why we need it:**
K3s must never run while you replace `state.db` and identity files.

**Expected result:**
`inactive` / `k3s_stopped`.

**If result is different:**

```bash
sudo systemctl stop k3s
sleep 3
systemctl is-active k3s
sudo ss -lntp | grep 6443 || echo api_down
```

**Verification before continuing:**

```bash
systemctl is-active k3s || true
```

Must not be `active`.

---

### Step 75 — Restore K3s identity and config

**Run on:** throwaway restore host

**Risk:** ⚠️ RESTORE ONLY / DESTRUCTIVE (overwrites tls, cred, token, manifests, rancher config, systemd unit)

**Command:**

```bash
cd ~/k3-restore
sudo tar -xzf k3s-identity.tar.gz -C /
```

**What this command does:**
Extracts the identity archive onto `/`. That restores `server/tls`, `server/cred`, `server/token`, `server/manifests`, `/etc/rancher/k3s`, and `k3s.service`.

**Why we need it:**
The datastore is encrypted/bound to this identity. Restoring `state.db` without `tls`/`cred`/`token` will not yield a working cluster.

**Expected result:**
No tar error. Paths exist under `/var/lib/rancher/k3s/server/tls` and `cred`.

**If result is different:**

```bash
sudo tar -tzf ~/k3-restore/k3s-identity.tar.gz | head
sudo ls -ld /var/lib/rancher/k3s/server/tls /var/lib/rancher/k3s/server/cred
```

**Verification before continuing:**

```bash
sudo ls /var/lib/rancher/k3s/server/tls | head
sudo ls /var/lib/rancher/k3s/server/cred
sudo stat -c '%a %U:%G' /var/lib/rancher/k3s/server/token
```

Expect token mode `600` and `root:root`. Do not `cat` the token.

---

### Step 76 — Restore `state.db` and remove WAL/SHM files

**Run on:** throwaway restore host

**Risk:** ⚠️ RESTORE ONLY / DESTRUCTIVE (replaces the datastore)

**Command:**

```bash
cd ~/k3-restore
sudo install -m 0600 -o root -g root state.db /var/lib/rancher/k3s/server/db/state.db
sudo rm -f /var/lib/rancher/k3s/server/db/state.db-wal \
           /var/lib/rancher/k3s/server/db/state.db-shm
sudo ls -l /var/lib/rancher/k3s/server/db/
```

**What this command does:**
Installs the SQLite **online-backup** snapshot as `state.db`. It **removes** `state.db-wal` and `state.db-shm`. It does **not** restore those files, and you must not copy them from the live server backup (Job 1 does not ship them as the restore datastore).

**Why we need it:**
The snapshot already has WAL folded in. A leftover `-wal` from the fresh install describes a **different** database and can silently load the wrong data.

**Expected result:**
`db/` contains `state.db` and **not** `state.db-wal` / `state.db-shm`. Mode `600`.

**If result is different:**
If wal/shm reappear before you start K3s, you did not stop K3s. Go back to Step 74, remove wal/shm again, then continue.

```bash
systemctl is-active k3s || true
sudo rm -f /var/lib/rancher/k3s/server/db/state.db-wal /var/lib/rancher/k3s/server/db/state.db-shm
sudo ls /var/lib/rancher/k3s/server/db/
```

**Verification before continuing:**

```bash
sudo ls /var/lib/rancher/k3s/server/db/
sudo stat -c '%a %U:%G %n' /var/lib/rancher/k3s/server/db/state.db
```

---

### Step 77 — Restore ownership/permissions and systemd, then reload

**Run on:** throwaway restore host

**Risk:** ⚠️ RESTORE ONLY / DESTRUCTIVE (reloads systemd units)

**Command:**

```bash
sudo chown -R root:root /var/lib/rancher/k3s/server/tls /var/lib/rancher/k3s/server/cred /var/lib/rancher/k3s/server/db
sudo chmod 0700 /var/lib/rancher/k3s/server /var/lib/rancher/k3s/server/tls /var/lib/rancher/k3s/server/cred /var/lib/rancher/k3s/server/db
sudo chmod 0600 /var/lib/rancher/k3s/server/db/state.db
sudo chmod 0600 /var/lib/rancher/k3s/server/token
sudo systemctl daemon-reload
```

**What this command does:**
Sets safe ownership/modes on identity and datastore, then reloads systemd so the restored `k3s.service` is used.

**Why we need it:**
Wrong modes on `token` or `state.db` leak cluster secrets. systemd must see the restored unit.

**Expected result:**
`daemon-reload` succeeds. `state.db` and `token` are `600 root:root`.

**If result is different:**

```bash
sudo stat -c '%a %U:%G %n' /var/lib/rancher/k3s/server/token /var/lib/rancher/k3s/server/db/state.db
sudo systemctl cat k3s.service | head
```

**Verification before continuing:**

```bash
sudo ls /var/lib/rancher/k3s/server/db/
sudo systemctl daemon-reload
```

Confirm wal/shm are still absent.

---

### Step 78 — Start K3s and verify the API and node

**Run on:** throwaway restore host

**Risk:** Makes change / Production-impacting on this host

**Command:**

```bash
sudo systemctl start k3s
sudo k3s kubectl get --raw='/readyz?verbose' || true
sudo k3s kubectl get nodes
sudo k3s kubectl get nodes -o wide
```

**What this command does:**
Starts K3s and checks API readiness and node `Ready`.

**Why we need it:**
Do not restore Velero volumes on top of a control plane that is not Ready.

**Expected result:**
Node `k3-master` is `Ready`, version matches the manifest. `readyz` succeeds.

**If result is different:**
If `NotReady`, **stop** and inspect logs. Do not debug apps yet.

```bash
sudo journalctl -u k3s -n 100 --no-pager
sudo ls /var/lib/rancher/k3s/server/tls | head
sudo ls /var/lib/rancher/k3s/server/cred
```

Certificate expiry errors on a ~1-year-old backup can be normal (K3s reissues leaf certs from the CA). Wait, restart K3s once, re-check. **Never regenerate the cluster CA** to silence errors.

```bash
sudo systemctl restart k3s
sudo k3s kubectl get nodes
```

**Verification before continuing:**

```bash
sudo k3s kubectl get nodes
systemctl is-active k3s
```

---

### Step 79 — Verify namespaces, CRDs, Secrets (names only), Traefik, ArgoCD, monitoring

**Run on:** throwaway restore host

**Risk:** Read-only

**Command:**

```bash
sudo k3s kubectl get ns
sudo k3s kubectl get crd | head -50
sudo k3s kubectl get crd | wc -l
sudo k3s kubectl get secrets -A --no-headers | wc -l
sudo k3s kubectl get secrets -A --field-selector type=kubernetes.io/tls --no-headers | awk '{print $1,$2}'
sudo k3s kubectl -n kube-system get deploy,pods | grep -i traefik
sudo k3s kubectl -n argocd get pods
sudo k3s kubectl -n monitoring get pods
```

**What this command does:**
Checks that datastore restore brought back namespaces, CRDs, Secret **objects** (count and names only), Traefik, ArgoCD, and monitoring pods.

**Why we need it:**
Workloads return with SQLite. **PVC files are still empty** until Velero volume restore. Pods may CrashLoop until volumes are filled. That is expected for Prometheus/Loki/Grafana.

**Expected result:**
Namespaces include `kube-system`, `monitoring`, `argocd`. CRD count is non-zero. Secret count is non-zero. **Do not print Secret `.data` values.** Traefik and ArgoCD pods exist. Monitoring pods exist (they may not be healthy until PVC restore).

**If result is different:**
If namespaces are missing, `state.db` restore is wrong (wal/shm left behind, or wrong snapshot):

```bash
sudo ls /var/lib/rancher/k3s/server/db/
sudo journalctl -u k3s -n 50 --no-pager
```

**Verification before continuing:**

```bash
sudo k3s kubectl get ns
sudo k3s kubectl get nodes
```

---

### Step 80 — Reinstall / reconnect Velero on the restored host

**Run on:** throwaway restore host

**Risk:** Makes change

**Command:**

```bash
# Install Velero CLI if missing (same as Step 52)
# Create a credentials file from RESTORE READER for read-only practice,
# or from WRITER only if this throwaway host must also write backups.
# For a practice restore, prefer readOnly on the backup location.
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export S3_BUCKET=k3-master-dr
export AWS_REGION=ap-south-1
export KMS_KEY_ID=<FULL_KMS_KEY_ARN>
export CREDS_FILE=/root/velero-credentials
```

Write `/root/velero-credentials` in the same `[default]` format as Step 53, using keys you intend for this host. For a throwaway test, reader keys plus a read-only location avoid writing into production. If `velero install` cannot set read-only, **do not apply Schedules** on the practice cluster.

Then install (same flags as Job 2: AWS plugin, prefix `velero`, node-agent, FSB default, no CSI):

```bash
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.10.0 \
  --bucket "$S3_BUCKET" \
  --prefix velero \
  --secret-file "$CREDS_FILE" \
  --backup-location-config "region=${AWS_REGION},serverSideEncryption=aws:kms,kmsKeyId=${KMS_KEY_ID}" \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --uploader-type kopia \
  --use-volume-snapshots=false \
  --wait
sudo k3s kubectl -n velero get backupstoragelocation
```

Repeat Step 54–56 on this host so node-agent `hostPath` matches **this** machine’s kubelet root.

**What this command does:**
Gives the restored cluster a Velero client that can see existing backups in `s3://k3-master-dr/velero/`.

**Why we need it:**
PVC data is not in Job 1. Velero must restore volumes.

**Expected result:**
BSL `Available`. `velero backup get` lists backups from production.

**If result is different:**

```bash
sudo k3s kubectl -n velero logs deploy/velero --tail=80
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
```

**Verification before continuing:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
sudo k3s kubectl -n velero get backupstoragelocation
```

Do **not** `kubectl apply` the daily/weekly schedules until this restore is verified. A practice cluster that starts writing backups can confuse which copy is good.

---

### Step 81 — Restore PVC data with Velero

**Run on:** throwaway restore host

**Risk:** ⚠️ RESTORE ONLY / DESTRUCTIVE (writes volume data; updates existing objects if you pass update policy)

**Command:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
# pick the Velero backup closest in time to your Job 1 DATE
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore create restore-full-$(date +%s) \
  --from-backup <backup-name> \
  --existing-resource-policy=update \
  --wait
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore describe <restore-name> --details
```

**What this command does:**
Restores Kubernetes objects as needed and refills PVCs through the node-agent. Workloads already exist from `state.db`; the important part is volume files.

**Why we need it:**
Monitoring history lives only in Job 2.

**Expected result:**
Restore `Completed`. PVCs Bound. `du` on local-path storage grows toward the original ~7.8 GB. Prometheus/Loki pods become ready after files land.

**If result is different:**
If restore Completes but volumes are empty, node-agent hostPath is wrong on the **new** host. Repeat Step 54–56, then restore again.

```bash
sudo k3s kubectl get pvc -A
sudo du -sh /var/lib/rancher/k3s/storage/
sudo k3s kubectl -n velero get pods
```

**Verification before continuing:**

```bash
sudo k3s kubectl get pvc -A
sudo k3s kubectl -n monitoring get pods
```

---

### Step 82 — Verify application health after full restore

**Run on:** throwaway restore host

**Risk:** Read-only

**Command:**

```bash
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A | grep -vE 'Running|Completed' | head
sudo k3s kubectl -n kube-system get pods | grep -i traefik
sudo k3s kubectl -n argocd get pods
sudo k3s kubectl -n monitoring get pods
sudo k3s kubectl get pvc -A
```

**What this command does:**
Checks control plane, Traefik, ArgoCD, monitoring, and PVCs.

**Why we need it:**
Pods Running is not the full proof for monitoring: Prometheus should answer a query for a **pre-incident** time range, and Loki should return old lines, if those volumes restored.

**Expected result:**
Node Ready. Traefik running. ArgoCD pods running. All six monitoring PVCs Bound. Real apps that were healthy before the test are healthy; ignore the already-broken demo apps if they were broken before backup work started.

**If result is different:**
HTTPS: if Day 1 found `acme.json` on `emptyDir`, certificates will **not** come back from backup. That is the gap recorded on Day 1, not a surprise.

```bash
sudo k3s kubectl get ingress,ingressroute -A
sudo k3s kubectl get secrets -A --field-selector type=kubernetes.io/tls --no-headers | awk '{print $1,$2}'
```

**Verification before continuing:**

Write down **start time** and **end time** of this restore. That duration is the measured restore time for the acceptance checklist.

```bash
date -u
```

After a successful throwaway test, do not enable production schedules on the throwaway host. Tear it down. On a **real** cutover only, re-enable Job 1 timer and Velero schedules after DNS/health checks.

---

## Individual restore commands (not the first test)

Use these after scratch tests have passed. Prefer a **scratch namespace** first whenever you are unsure.

When to restore into a scratch namespace first:

- You have never restored this resource type before.
- You need to inspect data before touching production.
- The object still exists in production and a restore with `--existing-resource-policy=update` would overwrite it.

⚠️ RESTORE ONLY / DESTRUCTIVE applies to any restore that updates or replaces live objects or PVC data.

### Step 83 — Restore one Kubernetes resource (example: Secret in one namespace)

**Run on:** k3-master (or restored host)

**Risk:** ⚠️ RESTORE ONLY / DESTRUCTIVE if the object exists and you add `--existing-resource-policy=update`

**Command:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero backup get
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore create restore-obj-$(date +%s) \
  --from-backup <backup-name> \
  --include-namespaces monitoring \
  --include-resources secrets \
  --selector app=grafana
```

Velero **skips objects that already exist** unless you pass `--existing-resource-policy=update`.

**What this command does:**
Restores matching Secrets from one backup. It does not print Secret values.

**Why we need it:**
Job 1 cannot put back a single deleted Secret. Job 2 can.

**Expected result:**
Restore created. The missing object reappears. `kubectl get secret` shows the name only.

**If result is different:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore describe <restore-name> --details
sudo k3s kubectl -n monitoring get secrets | grep grafana
```

**Verification before continuing:**

```bash
sudo k3s kubectl -n monitoring get secrets --no-headers | awk '{print $1}'
```

---

### Step 84 — Restore one namespace (example)

**Run on:** k3-master

**Risk:** ⚠️ RESTORE ONLY / DESTRUCTIVE if restoring onto the live namespace with update policy

**Command:**

Scratch mapping first (safe inspection):

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore create ns-scratch-$(date +%s) \
  --from-backup <backup-name> \
  --include-namespaces argocd \
  --namespace-mappings argocd:argocd-restore-scratch \
  --wait
sudo k3s kubectl get ns argocd-restore-scratch
sudo k3s kubectl -n argocd-restore-scratch get pods
```

Live namespace (only when you intend to restore that namespace):

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore create ns-live-$(date +%s) \
  --from-backup <backup-name> \
  --include-namespaces argocd \
  --wait
```

**What this command does:**
The first form restores `argocd` objects into `argocd-restore-scratch`. The second restores into the real `argocd` namespace.

**Why we need it:**
Namespace-scoped accidents are common. Scratch mapping lets you look before you overwrite.

**Expected result:**
Scratch namespace contains restored pods/objects. Delete the scratch namespace when finished:

```bash
sudo k3s kubectl delete ns argocd-restore-scratch
```

**If result is different:**

```bash
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore describe <restore-name> --details
```

**Verification before continuing:**

```bash
sudo k3s kubectl get ns
```

---

### Step 85 — Restore one PVC (production procedure)

**Run on:** k3-master

**Risk:** ⚠️ RESTORE ONLY / DESTRUCTIVE (can destroy current volume files because `local-path` reclaim policy is Delete)

**Command:**

Do **not** use this as the first PVC test. First test is Step 64.

```bash
# 1. Stop writers so the volume is unused
sudo k3s kubectl -n monitoring scale deploy/<name> --replicas=0

# 2. Only if the live data is unusable: deleting the PVC destroys the directory
sudo k3s kubectl -n monitoring delete pvc <pvc-name>

# 3. Restore that PVC from Velero
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore create pvc-restore-$(date +%s) \
  --from-backup <backup-name> \
  --include-namespaces monitoring \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --selector app.kubernetes.io/name=prometheus \
  --wait

# 4. Start the workload again
sudo k3s kubectl -n monitoring scale deploy/<name> --replicas=1
```

**What this command does:**
Unmounts the volume, optionally deletes the PVC (which **deletes files on disk** with `local-path`), restores PVC/PV from backup, then scales the app back.

**Why we need it:**
An accidental `kubectl delete pvc` is permanent without Velero.

**Expected result:**
New PVC Bound. Pod Ready. **Contents** must be checked inside the app (Prometheus query over a time range from before the incident), not only `Bound` status.

**If result is different:**

```bash
sudo k3s kubectl -n monitoring get pvc,pod -o wide
sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml velero restore describe <restore-name> --details
sudo k3s kubectl -n velero get pods -l name=node-agent
```

**Verification before continuing:**

```bash
sudo k3s kubectl get pvc -A
```

A bad application deploy is **not** a backup problem: revert Git and let ArgoCD roll back.

---

## What could go wrong

| Problem | Next command |
|---------|----------------|
| Not sure what is missing | `sudo /usr/local/sbin/k3s-backup-preflight.sh` (or `--no-aws` on Day 1) |
| Small uploads work, `state.db` upload fails | Confirm `kms:Decrypt` on the writer policy; re-run the 64 MB test (Step 30 / preflight) |
| `AccessDenied` on every upload | `sudo grep '^KMS_KEY_ID=' /etc/k3s-backup/backup.env` — must be a full ARN |
| Velero backups never expire | Writer policy must allow `s3:DeleteObject` on `arn:aws:s3:::k3-master-dr/velero/*` only |
| `Pod Volume Backups` empty | Step 54–56: kubelet root vs node-agent hostPath. Treat backup as failed for PVCs |
| Low disk | `df -h /` then `sudo du -sh /var/backups/k3s` — script prunes staging older than 3 days |
| Server is gone | Full-server restore section above |
| One PVC or Secret deleted | Steps 83–85; first restore tests stay on scratch resources |

---

## Final acceptance checklist

The runbook is complete only when **all** of the following are proven. Tick them in order.

- [ ] Day 1 preflight `--no-aws` passed (`READY` or `READY, with warnings`)
- [ ] TLS certificate source identified, and you wrote down whether Job 1, Job 2, both, or neither covers it
- [ ] 64 MB S3/KMS upload test passed (`Size=67108864`, `SSE=aws:kms`)
- [ ] Job 1 dry-run passed (exit 0, artifacts + checksums + SQLite `ok` + real `k3s_version`)
- [ ] Job 1 real backup passed (exit 0)
- [ ] S3 objects verified under `k3s/daily/YYYY-MM-DD/` (and `k3s/weekly/` if Sunday)
- [ ] Encryption on `state.db` is SSE-KMS with the DR key
- [ ] Timer enabled, **next run visible** in `systemctl list-timers 'k3s-backup*'`
- [ ] Velero installed; node-agent running; kubelet path matches hostPath
- [ ] BackupStorageLocation `Available`
- [ ] Manual Velero backup `Completed`
- [ ] All **six** real monitoring PVCs confirmed in Pod Volume Backups (empty PVB = **failed** PVC protection)
- [ ] Scratch ConfigMap restore passed (`k3-backup-cm-ok`)
- [ ] Scratch PVC restore passed with **matching SHA256** (not Prometheus/Loki/Grafana/MinIO/Alertmanager)
- [ ] Full server restore tested on a **throwaway** server
- [ ] Restore time recorded: start `________` UTC, end `________` UTC, duration `________`

If any box is unchecked, the system is not accepted. Do not skip PVC Pod Volume Backup proof. Do not skip the throwaway full restore.

---

## What to do next (first command today)

If you have not started Day 1:

```bash
scp scripts/k3s-backup-preflight.sh root@45.90.98.51:/tmp/
```

Then continue at Step 2.
