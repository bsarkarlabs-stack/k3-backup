# 07 — Phase 0 & 1 Execution Runbook (manual, production-safe)

Executable companion to [04 — Implementation TODO](04-implementation-todo.md), phases
[#9](../../issues/9) and [#10](../../issues/10). Every command below is meant to be **typed or
pasted one at a time**, with the `verify` block checked before moving on.

**Target:** `k3-master` (`45.90.98.51`) — single-node K3s, in production, **zero downtime
budget**.

---

## 0. How to use this document

1. Work top to bottom. Stages depend on the ones above them.
2. After every command, run the `verify` block. If it does not match, **stop** — do not
   improvise the next step.
3. Nothing in Phase 0 or Phase 1 restarts, reloads, or reconfigures K3s. If you find yourself
   about to type `systemctl restart k3s`, you have left this runbook.
4. Keep a second SSH session open to `k3-master` for the whole exercise. If the working session
   ever hangs, you diagnose from the second one rather than reconnecting blind.
5. Run this during a low-traffic window anyway — not because a step is risky, but because the
   first execution of anything new deserves an audience.

### Downtime risk register

| Stage | What it touches | Downtime risk | Why |
|-------|-----------------|---------------|-----|
| A — Pre-flight | Nothing. Reads only. | **None** | `df`, `systemctl is-active`, `ls`. |
| B — Gap closure | Nothing. Reads only. | **None** | `find`, `kubectl get`, `dmidecode`. |
| C — AWS foundations | Your AWS account. Not the server. | **None** | Run from your workstation. |
| D — Credential + egress test | Writes `/etc/k3s-backup/`. One throwaway S3 object. | **None** | New directory, unrelated to K3s. |
| E — Deploy script (dry run) | Writes `/usr/local/sbin/`, reads K3s state, stages ~100 MB in `/var/backups`. | **Very low** | Read-only against K3s; disk is pre-checked. |
| F — First real run | As above, plus S3 upload. | **Very low** | ~100 MB egress, niced and idle-I/O. |
| G — Restorability check | Downloads to your workstation. | **None** | Verification happens off the node. |
| H — Enable timers | Two new systemd timers. | **Very low** | New units; existing units untouched. |

The one genuinely load-bearing safety claim, stated plainly so you can check it yourself:
**the SQLite snapshot uses the online backup API on a read-only connection, and `state.db` is in
WAL mode, so the backup reader does not block kine's writers.** A raw `cp` would have been the
dangerous option — that is why the script does not do one.

### Scope — K3s only

This backs up **K3s**, not the whole server. No OS image, no full-disk copy, no `/var/lib/rancher/k3s/agent`
(43 GB of reproducible image cache, deliberately excluded per
[02 §8](02-backup-strategy.md#8-what-is-explicitly-not-backed-up)). The recovery model is: *rebuild
a plain Ubuntu box, reinstall the matching K3s, restore the K3s state on top.*

One exception, and you should make it consciously. The `full` run also captures ~1 MB of node OS
config — netplan, UFW rules, `/etc/ssh`, `authorized_keys`, timezone, `dpkg --get-selections`.
That is not K3s, but it is what turns [restore step 2](03-restore-runbook.md#step-2--restore-node-level-os-configuration)
from *reconstruct the static IP and firewall rules from memory, during an outage* into *unpack a
tarball*. It is [Phase 1 scope](04-implementation-todo.md#phase-1--node--cluster-state-backup-track-a)
and gap [#5](../../issues/5).

Keep it unless you have a reason not to. To go strictly K3s-only, add to `/etc/k3s-backup/backup.env`:

```ini
BACKUP_NODE_CONFIG=0
```

### Conventions

Commands are labelled by where they run:

- `[local]` — your workstation (has AWS admin credentials)
- `[node]` — an SSH session on `k3-master`

Shell variables used throughout `[local]`:

```bash
export AWS_PROFILE=<your-admin-profile>
export REGION=ap-south-1                  # Mumbai. Change freely — see Stage C.0
export BUCKET=k3-master-dr                # see Stage C.2 if the name is taken
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "$REGION / $BUCKET / $ACCOUNT_ID"
```

---

## Stage A — Pre-flight re-verification `[node]`

The whole design rests on [01 — Discovery Baseline](01-discovery-baseline.md). That was a
snapshot in time. Confirm it still holds before building on it.

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

**verify**

- Hostname `k3-master`, K3s `v1.34.5+k3s1`, service `active` + `enabled`.
- Root filesystem has **at least 5 GB** free. The docs recorded 34 GB; anything under 5 GB means
  stop and reclaim space first — Stage E stages ~100 MB but a full disk on a K3s node is its own
  outage.
- `db/` contains `state.db`, `state.db-wal`, `state.db-shm`.
- `etcd-snapshot ls` still says `etcd datastore disabled` — confirming component 1 must be the
  SQLite path, not a k3s snapshot.

> If the K3s version has moved since discovery, record the new version in
> [01](01-discovery-baseline.md) before continuing. A restore needs the *matching* binary version,
> so a stale version number in the docs is a restore-time failure.

---

## Stage B — Close the read-only gaps `[node]`

These commands change nothing. They resolve gaps [#8](../../issues/8), [#4](../../issues/4) and
[#13](../../issues/13) from [05 — Gaps](05-gaps-and-open-questions.md), all of which affect what
Stage E actually needs to archive.

### B.1 — Enumerate `server/tls/` and `server/cred/` (gap 9)

> 🔒 **Filenames and permissions only. Never `cat` these files.** Their contents are the cluster's
> private keys.

```bash
sudo find /var/lib/rancher/k3s/server/tls  -printf '%M %u:%g %10s %p\n' | sort -k4
sudo find /var/lib/rancher/k3s/server/cred -printf '%M %u:%g %10s %p\n' | sort -k4
sudo du -sh /var/lib/rancher/k3s/server/tls /var/lib/rancher/k3s/server/cred
```

**verify** — every path listed is under `tls/`, `cred/`, or their subdirectories. The Stage E
archive covers those two directories wholesale, so anything *outside* them that looks
identity-shaped (a stray `*.key`, `*.crt`, or `*-ca.*` directly under `server/`) is a finding:
record it in [05](05-gaps-and-open-questions.md) and add it to the tar in Stage E.

```bash
# anything identity-shaped sitting loose in server/
sudo find /var/lib/rancher/k3s/server -maxdepth 1 -type f -printf '%M %10s %p\n'
```

Record the certificate expiry dates while you are here ([#19](../../issues/19)). **Dates only —
this reads no key material:**

```bash
for c in /var/lib/rancher/k3s/server/tls/*.crt; do
  printf '%-58s ' "$(basename "$c")"
  sudo openssl x509 -enddate -noout -in "$c" 2>/dev/null || echo "unreadable"
done
```

**verify** — you expect two tiers, and the gap between them is the point:

| Certificate | Expected lifetime |
|-------------|-------------------|
| `*-ca.crt` (server, client, request-header) | ~10 years out |
| everything else (serving, client leaf certs) | ~1 year out |

Write both dates into [01](01-discovery-baseline.md). They matter at restore time: a backup older
than the **leaf** expiry produces x509 errors on first start that K3s **self-heals** by re-issuing
from the still-valid CA. Knowing the real dates is what lets the operator tell that apart from a
genuinely broken identity restore — see
[03, step 6](03-restore-runbook.md#certificate-errors-expected-vs-genuinely-broken).

> If any **CA** is inside ~1 year of expiry, stop and raise it. That is a live cluster problem, not
> a backup problem, and it will not fix itself.

### B.2 — Determine the ingress TLS certificate source (gap 2)

```bash
sudo k3s kubectl get ingress,ingressroute -A
sudo k3s kubectl get secrets -A --field-selector type=kubernetes.io/tls
```

```bash
sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -i -B2 -A4 'acme\|certresolver\|entryPoint'
sudo k3s kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik -o jsonpath='{.items[*].spec.volumes[*].name}{"\n"}'
```

**verify** — you are answering exactly one question: *where does `acme.json` live, if it exists?*

| What you see | Meaning | Action |
|--------------|---------|--------|
| TLS Secrets exist, no ACME config | Certs are Kubernetes Secrets | ✅ Velero (Phase 2) covers them. Note it in [05](05-gaps-and-open-questions.md) and close #4. |
| ACME resolver configured, volume is `emptyDir` | ACME state is **ephemeral** | 🚨 Not backed up by any component. Restore yields an ingress with no valid cert. Raise before Phase 2. |
| ACME resolver configured, volume is a PVC | ACME state is on disk | ✅ Phase 2 node-agent covers it — but confirm that PVC is in the Velero schedule. |
| No ingress TLS at all | Terminated upstream | Document what terminates it. |

### B.3 — Confirm bare metal vs VM (gap 1 — mostly resolved)

The provider is **Datalix**, treated as on-premise, with **no snapshot fallback**. This command
just confirms whether you are on bare metal or a VM, which affects nothing here but is worth
knowing:

```bash
systemd-detect-virt
```

**verify** — `none` means bare metal; anything else names the hypervisor. Either way there is no
provider snapshot to fall back on, which is already recorded in
[01 §17](01-discovery-baseline.md#17-hosting-provider--datalix-treated-as-on-premise). Close #13.

### B.4 — Confirm the SQLite backup API is available (Phase 0 item)

```bash
python3 -c "import sqlite3; print('python sqlite3 module OK, sqlite', sqlite3.sqlite_version)"
```

**verify** — prints a version. If it does, **you do not need to install anything** — the script
uses Python's `sqlite3` module, which exposes the same online backup API as the CLI. That keeps
Phase 0 free of any `apt install` on a production node.

If and only if it fails:

```bash
sudo apt-get update && sudo apt-get install -y sqlite3
```

> `apt-get install sqlite3` does not touch K3s, but it is still the only package operation in this
> runbook. Prefer the Python path.

### B.5 — Dry-run the image manifest (component 8)

```bash
sudo k3s kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' \
  | sed '/^$/d' | sort -u
```

**verify** — a list of unique image references, roughly matching the workloads in
[01 §13](01-discovery-baseline.md#13-argocd). This is exactly what the script captures; running it
by hand first means no surprises later.

---

## Stage C — AWS foundations `[local]`

Run these from your workstation with admin credentials. **Nothing in this stage touches
`k3-master`.**

Order matters: the KMS key is created first because
[gap 5](05-gaps-and-open-questions.md#5-secrets-reach-s3-unencrypted-unless-sse-kms-is-configured)
is explicit that default encryption does **not** apply retroactively. The bucket must be encrypted
from its first object.

### C.0 — Pick a region (one line, any of these work)

A "region" is just **which AWS data centre holds the files**. AWS makes you name one when creating
a bucket — there is no region-less bucket. It **cannot be changed later**; moving means making a
new bucket and copying.

The daily upload is ~320 MB, so latency is not a real factor. Choose on cost and on where your
team and any compliance obligations sit:

| Region | Code | Good when |
|--------|------|-----------|
| Mumbai | `ap-south-1` | Your team is in India. **Current default.** |
| N. Virginia | `us-east-1` | Cheapest AWS region. Note the quirk below. |
| Frankfurt | `eu-central-1` | Nearest to the Datalix server; keeps data in the EU if GDPR applies to any workload. |

Set it once in the conventions block above. **Nothing else in this runbook changes** — every
command reads `$REGION`:

```bash
export REGION=ap-south-1     # or us-east-1, or eu-central-1
```

> **Why this data leaves your building at all:** the server is on-premise with no hypervisor
> snapshot ([gap 1](05-gaps-and-open-questions.md#1-hosting-provider--resolved-datalix-treated-as-on-premise)).
> A backup stored on `k3-master` dies with `k3-master`. The bucket is the only copy that survives
> disk failure, fire, or theft — that is the entire reason it is remote, not a preference for AWS.
>
> S3 is simply the destination [02 §5](02-backup-strategy.md#5-s3-storage-design) selected. Any
> off-server target satisfies the requirement; only the upload step in
> [`k3s-track-a-backup.sh`](../scripts/k3s-track-a-backup.sh) would change. What is **not**
> acceptable is a target on the same machine — including the in-cluster MinIO, which lives on the
> very disk you are protecting against.

### C.1 — Create the customer-managed KMS key

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

**verify**

```bash
aws kms describe-key --region "$REGION" --key-id alias/k3-master-dr \
  --query 'KeyMetadata.{State:KeyState,Manager:KeyManager,Spec:KeySpec}'
aws kms get-key-rotation-status --region "$REGION" --key-id "$KEY_ID"
```

Expect `State: Enabled`, `Manager: CUSTOMER`, rotation `true`.

> Write `$KEY_ARN` down somewhere outside AWS. **If this key is deleted, every backup encrypted
> with it is permanently unreadable** — including the ones you would be restoring from.

### C.2 — Create the bucket

```bash
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION"
fi
```

> Written as an `if` on purpose: `us-east-1` is the one region that **rejects** the
> `--create-bucket-configuration` flag, while every other region **requires** it. Pasting this
> block works whichever region you chose.

> Bucket names are **globally unique across all of AWS**, so if `k3-master-dr` is already taken the
> call fails with `BucketAlreadyExists`. Use `k3-master-dr-<yourorg>` and update `$BUCKET` — every
> later command reads the variable, so that is the only change needed.

### C.3 — Block public access, before anything is written

```bash
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### C.4 — Versioning

```bash
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled
```

### C.5 — Default SSE-KMS encryption

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

### C.6 — Bucket policy: refuse plaintext and refuse the wrong key

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

**verify Stage C.2–C.6 as a block**

```bash
aws s3api get-public-access-block --bucket "$BUCKET"
aws s3api get-bucket-versioning  --bucket "$BUCKET"
aws s3api get-bucket-encryption  --bucket "$BUCKET"
aws s3api get-bucket-policy      --bucket "$BUCKET" --query Policy --output text | head -c 400; echo
```

All four blocks `true`; versioning `Enabled`; encryption `aws:kms` with your key ARN; policy
present.

### C.7 — Least-privilege writer (the credential that lives on the node)

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

> Deliberately **no `s3:DeleteObject` and no `kms:Decrypt`**. A credential that sits on a
> production server and can only ever add encrypted objects is one that a compromise of that
> server cannot use to destroy or read your backups. Retention deletions are done by S3 lifecycle
> rules in Phase 4, not by this key.

Capture the access key ID and secret now — the secret is shown once. They go into
`/etc/k3s-backup/backup.env` in Stage D and nowhere else. **Never into this repository.**

### C.8 — Separate restore-only credential, stored offline

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

**verify**

```bash
aws iam list-user-policies --user-name k3-master-backup-writer
aws iam list-user-policies --user-name k3-master-restore-reader
```

Store the **reader** credentials in your password manager / offline vault. Per
[02 §5](02-backup-strategy.md#5-s3-storage-design) they must **not** be placed on `k3-master`.
Assign the named rotation owner now ([gap 8](05-gaps-and-open-questions.md#8-no-named-owner-for-credential-rotation), 90 days) rather than deferring it to Phase 6 — it takes ten seconds while the
users are in front of you.

```bash
rm -f /tmp/k3-dr-*.json
```

---

## Stage D — Install the credential on the node and prove egress `[node]`

### D.1 — Create the config directory

```bash
sudo install -d -m 0700 -o root -g root /etc/k3s-backup
```

### D.2 — Write `backup.env`

```bash
sudo install -m 0600 -o root -g root /dev/null /etc/k3s-backup/backup.env
sudo nano /etc/k3s-backup/backup.env
```

Contents — substitute your real values:

```ini
S3_BUCKET=k3-master-dr
AWS_REGION=<your-region>
KMS_KEY_ID=<the KEY_ARN from C.1>
AWS_ACCESS_KEY_ID=<from C.7>
AWS_SECRET_ACCESS_KEY=<from C.7>
```

**verify**

```bash
sudo stat -c '%a %U:%G %n' /etc/k3s-backup /etc/k3s-backup/backup.env
```

Expect `700 root:root` and `600 root:root`. Anything group- or world-readable here is a finding —
this file grants write access to the bucket holding your cluster CA.

### D.3 — Prove connectivity and egress with a throwaway object

```bash
set -a; . /etc/k3s-backup/backup.env; set +a
export AWS_DEFAULT_REGION="$AWS_REGION"

echo "k3-master egress test $(date -u +%FT%TZ)" > /tmp/k3-egress-test.txt

sudo -E aws s3 cp /tmp/k3-egress-test.txt "s3://$S3_BUCKET/_egress-test/" \
  --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID"
```

**verify** — this is the step that proves the whole Stage C configuration actually holds:

```bash
sudo -E aws s3api head-object --bucket "$S3_BUCKET" --key "_egress-test/k3-egress-test.txt" \
  --query '{SSE:ServerSideEncryption,Key:SSEKMSKeyId,Size:ContentLength}'
```

Expect `SSE: aws:kms` and your key ARN. If `SSE` is `AES256` or absent, the bucket policy or
default encryption did not apply — go back to C.5/C.6 before writing anything real.

Now prove the guardrails work — **both of these must fail:**

```bash
# must be denied: no DeleteObject on the writer
sudo -E aws s3api delete-object --bucket "$S3_BUCKET" --key "_egress-test/k3-egress-test.txt"
```

```bash
# must be denied: unencrypted put
sudo -E aws s3api put-object --bucket "$S3_BUCKET" --key "_egress-test/plaintext.txt" \
  --body /tmp/k3-egress-test.txt
```

Both should return `AccessDenied`. A success here means the least-privilege model is not actually
in place. Clean up from `[local]` with your admin profile:

```bash
aws s3 rm "s3://$BUCKET/_egress-test/" --recursive
rm -f /tmp/k3-egress-test.txt   # on the node
```

> Versioning is on, so that `rm` leaves a delete marker rather than erasing history. That is
> intended.

---

## Stage E — Deploy the Track A script and dry-run it `[node]`

The script is [`scripts/k3s-track-a-backup.sh`](../scripts/k3s-track-a-backup.sh) in this
repository. Deploy **from the repo**, not by pasting into an editor on the server — the repo is
the canonical copy per the working agreement.

### E.1 — Copy it onto the node

From `[local]`, in your clone of this repo:

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

**verify**

```bash
bash -n /usr/local/sbin/k3s-track-a-backup.sh && echo "syntax OK"
sudo /usr/local/sbin/k3s-track-a-backup.sh 2>&1 | head -2   # expect the usage error
```

### E.2 — Record the control-plane state you are about to prove untouched

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
sudo ls -la /var/lib/rancher/k3s/server/db/
```

Keep this output. Stage F compares against it.

### E.3 — Dry run: build every artifact, upload nothing

```bash
sudo DRY_RUN=1 /usr/local/sbin/k3s-track-a-backup.sh full
```

**verify**

```bash
sudo ls -lah /var/backups/k3s/*/
```

You should see, for a `full` run:

| Artifact | Expected size |
|----------|---------------|
| `state-*.db` | ~60–90 MB |
| `server-identity-*.tar.gz` | small — a few hundred KB |
| `config-*.tar.gz` | ~4 KB |
| `manifests-*.tar.gz` | ~20 KB |
| `node-config-*.tar.gz` | small |
| `images-*.txt`, `image-digests-*.txt` | a few KB |
| `manifest-*.json` | a few KB |
| a `.sha256` beside each | 100 bytes |

And in the run output: `snapshot ok (read-only), integrity_check=ok`, followed by
`manifest: k3s=v1.34.5+k3s1 os=... artifacts=N`.

Check the manifest recorded a real version — this is what step 0 of a restore reads:

```bash
sudo python3 -m json.tool /var/backups/k3s/*/manifest-*.json | head -20
```

> If `k3s_version` says `unknown`, the script could not read `/usr/local/bin/k3s`. Fix that before
> going further — a manifest without a version defeats the point of having one ([#17](../../issues/17)).

> If the log says `WARNING: read-only open failed ... using query_only fallback`, the backup is
> still safe — the connection is pinned read-only at the SQLite level — but note it, because it
> means the WAL `-shm` handling differs from expectation on this host.

Confirm K3s is exactly where you left it:

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
```

`ActiveEnterTimestamp` and `NRestarts` **must be identical to E.2**. This is the zero-downtime
proof for the whole phase.

### E.4 — Clean up the dry-run staging

```bash
sudo rm -rf /var/backups/k3s/*/
df -h /
```

---

## Stage F — First real run `[node]`

Run the small mode first. If anything about the upload path is wrong, you find out with one 64 MB
object rather than six.

```bash
sudo /usr/local/sbin/k3s-track-a-backup.sh db
```

**verify**

```bash
set -a; . /etc/k3s-backup/backup.env; set +a
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/cluster-state/db/"
```

Then the full run:

```bash
sudo /usr/local/sbin/k3s-track-a-backup.sh full
```

**verify — every prefix from [02 §5](02-backup-strategy.md#5-s3-storage-design) is populated**

```bash
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/" --recursive --human-readable
```

Expect objects under `cluster-state/db/`, `cluster-state/server-identity/`, `config/`,
`manifests/`, `node-config/`, `image-manifest/` and `run-manifests/` — each with its `.sha256`
sibling.

Missing prefixes: `velero/` (Phase 2) and `argocd-export/` (Phase 3). That is correct at this
stage.

And once more, the thing that actually matters:

```bash
sudo systemctl show k3s -p ActiveEnterTimestamp -p NRestarts
sudo k3s kubectl get nodes
sudo k3s kubectl get pods -A | grep -v Running | head
```

Unchanged restart count, node `Ready`, and only the four pre-existing unhealthy demo apps from
[01 §13](01-discovery-baseline.md#13-argocd) — `demo-app`, `nginx-app`, `nginx-app-dev`,
`nginx-app11`. **Those were broken before you started. Do not chase them.**

---

## Stage G — Prove the artifacts are restorable `[local]`

Phase 1's final item is *"verify a full cycle produces the expected objects"*. A green exit code
is not that. Do this from your workstation using the **restore-reader** credential from C.8 — which
also proves that credential works before you need it in an emergency.

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

**verify — the run manifest is present and usable ([#17](../../issues/17))**

This is what a real restore reads first, so prove it round-trips before you need it:

```bash
MAN=$(aws s3 ls "s3://$BUCKET/run-manifests/" | grep '\.json$' | sort | tail -1 | awk '{print $4}')
aws s3 cp "s3://$BUCKET/run-manifests/$MAN" .
python3 -m json.tool "$MAN"
```

Confirm it names a real `k3s_version` (not `unknown`), and that the digests it lists match the
objects actually in the bucket:

```bash
python3 - "$MAN" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print("k3s_version :", d["k3s_version"])
print("os_release  :", d["os_release"])
print("mode        :", d["mode"], "  artifacts:", d["artifact_count"])
assert d["k3s_version"] != "unknown", "manifest has no k3s version - fix before relying on this"
for a in d["artifacts"]:
    print(f"  {a['s3_prefix']:32} {a['filename']:40} {a['bytes']:>12,}")
PY
```

Cross-check one digest end to end — the manifest's value must equal the downloaded file's:

```bash
grep -o '"sha256": "[a-f0-9]*"' "$MAN" | head -3
sha256sum "$LATEST"
```

**verify — checksum survived the round trip**

```bash
sha256sum -c "$LATEST.sha256"
```

**verify — the snapshot is a valid, complete SQLite database**

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

Expect `integrity_check: ok`, a `kine` table, and a non-trivial row count. That row count is your
evidence that this is the live cluster's state and not an empty shell.

**verify — the identity archive contains what a restore needs**

```bash
aws s3 cp "s3://$BUCKET/cluster-state/server-identity/$(aws s3 ls "s3://$BUCKET/cluster-state/server-identity/" | grep 'tar.gz$' | sort | tail -1 | awk '{print $4}')" .
tar -tzf server-identity-*.tar.gz | head -40
tar -tzf server-identity-*.tar.gz | wc -l
```

Cross-check that listing against what you enumerated in B.1. Same file set, or the tar is
incomplete.

```bash
cd ~ && rm -rf ~/k3-restore-check
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

> **Restore-time footgun, record it now:** the snapshot is a single consolidated `state.db`. When
> restoring, place it as `/var/lib/rancher/k3s/server/db/state.db` with **no `-wal` and no `-shm`
> file beside it**, while K3s is stopped. Leaving a stale WAL from the old machine next to a fresh
> snapshot is how a restore silently loads the wrong state. This belongs in
> [03 — Restore Runbook](03-restore-runbook.md).

---

## Stage H — Schedule via systemd timers `[node]`

Per [04, Phase 1](04-implementation-todo.md#phase-1--node--cluster-state-backup-track-a): systemd
timers, matching the existing `dpkg-db-backup.timer` convention. **No cron** — the server has no
root crontab today and it stays that way.

```bash
sudo install -m 0644 -o root -g root /tmp/k3s-backup@.service        /etc/systemd/system/
sudo install -m 0644 -o root -g root /tmp/k3s-backup-db.timer        /etc/systemd/system/
sudo install -m 0644 -o root -g root /tmp/k3s-backup-full.timer      /etc/systemd/system/
sudo systemctl daemon-reload
```

**verify the units parse before enabling anything**

```bash
sudo systemd-analyze verify /etc/systemd/system/k3s-backup@.service
sudo systemctl cat k3s-backup@db.service | head -20
```

Test the templated service by hand once — this is the exact path the timer will take:

```bash
sudo systemctl start k3s-backup@db.service
sudo systemctl status k3s-backup@db.service --no-pager
sudo journalctl -u k3s-backup@db.service -n 40 --no-pager
```

**verify** — `Main PID: ... (code=exited, status=0/SUCCESS)` and the log ends with
`completed successfully`.

Only now enable the timers:

```bash
sudo systemctl enable --now k3s-backup-db.timer
sudo systemctl enable --now k3s-backup-full.timer
```

**verify**

```bash
systemctl list-timers 'k3s-backup*' --all --no-pager
```

Expect `k3s-backup-db.timer` next at the coming 00/06/12/18:20 UTC slot, and
`k3s-backup-full.timer` at 02:15 UTC. The two never collide, and the script holds a `flock` if they
ever would.

---

## Stage I — Soak `[node]`, then close the issues

Per [04, Phase 4](04-implementation-todo.md#phase-4--automation--retention): **let this run
unattended for one full week before relying on it.**

Daily check, ~30 seconds:

```bash
systemctl list-timers 'k3s-backup*' --no-pager
journalctl -u 'k3s-backup@*' --since '24 hours ago' --no-pager | tail -30
df -h /
```

```bash
sudo -E AWS_DEFAULT_REGION="$AWS_REGION" aws s3 ls "s3://$S3_BUCKET/cluster-state/db/" | tail -5
```

You expect **4 new `state-*.db` objects per day** and one of everything else.

Also watch, specifically:

- **Root filesystem free space** — the script prunes staging older than 3 days and refuses to run
  under 2 GB free, but a 6-hourly job on a 64 %-full disk deserves a week of eyes.
- **S3 object count growth** — no lifecycle rules exist yet (Phase 4), so nothing is ever deleted,
  and versioning means even overwrites accumulate. At ~80 MB per snapshot × 4/day that is
  **~320 MB/day, ~9–10 GB/month**, growing without bound. Apply the
  [retention matrix](02-backup-strategy.md#retention-matrix) before this becomes a bill — this is
  the single strongest reason not to let Phase 4 slip.

  > **Decided: no compression.** The snapshot is uploaded uncompressed so it can be verified — and
  > restored — directly, with no decompress step in the outage window. Gzip would have cut storage
  > roughly 3–5×; simplicity of restore was chosen over storage cost. Revisit only if the S3 bill
  > becomes a real number.

After a clean week:

- Tick every box in [04, Phase 0 and Phase 1](04-implementation-todo.md)
- Close issues [#9](../../issues/9) and [#10](../../issues/10)
- Update the status table in the [README](../README.md)
- Record the B.1/B.2/B.3 findings in [05](05-gaps-and-open-questions.md) and close
  [#8](../../issues/8), [#4](../../issues/4), [#13](../../issues/13), [#5](../../issues/5),
  [#6](../../issues/6)
- Commit any script changes you made on the node back to `scripts/` here

---

## Abort & rollback

Nothing in phases 0–1 modifies K3s, so rollback is always "remove what was added".

| Stage | To undo |
|-------|---------|
| H | `sudo systemctl disable --now k3s-backup-db.timer k3s-backup-full.timer` then `sudo rm /etc/systemd/system/k3s-backup*` and `daemon-reload` |
| E–F | `sudo rm -f /usr/local/sbin/k3s-track-a-backup.sh; sudo rm -rf /var/backups/k3s` |
| D | `sudo rm -rf /etc/k3s-backup` — then deactivate the writer key: `aws iam delete-access-key --user-name k3-master-backup-writer --access-key-id <id>` |
| C | `aws s3 rm s3://$BUCKET --recursive`, `aws s3api delete-bucket --bucket $BUCKET`, delete both IAM users, then `aws kms schedule-key-deletion --key-id $KEY_ID --pending-window-in-days 30` |
| A–B | Nothing to undo. Read-only. |

**If a backup run ever seems to be affecting the node** (unlikely — it is niced and idle-I/O, and
touches K3s read-only):

```bash
sudo systemctl stop 'k3s-backup@*'
sudo systemctl disable --now k3s-backup-db.timer k3s-backup-full.timer
```

That kills the backup. It does not touch K3s. There is no state to unwind, because the script only
ever reads.

---

## What Phase 0 + 1 deliberately does **not** give you

Be honest about the remaining exposure while these are outstanding:

| Not yet covered | Which phase | Consequence today |
|-----------------|-------------|-------------------|
| Kubernetes object-level backup (Velero) | 2 | You can rebuild **this node**. You cannot yet restore into a fresh cluster or a different K3s version — [02, component 5](02-backup-strategy.md#component-5--kubernetes-resource-state) is explicit that the SQLite file only helps if you rebuild the same node. |
| PVC data (6 monitoring volumes, ~7.8 GB) | 2 | Prometheus/Loki/Grafana history is **not backed up at all**. |
| ArgoCD export | 3 | `argocd-cm`, `argocd-secret`, and any ad-hoc Applications are unrecoverable from Git alone. |
| S3 lifecycle / retention | 4 | Storage grows unbounded. |
| Failure alerting | 4 | The script writes `backup_last_success_timestamp` if node_exporter's textfile collector exists, but **nothing alerts on it yet**. A silently failing backup stays silent. |
| Any tested restore | 5 | *A backup that has never been restored is a hypothesis, not a plan.* |
| Any fallback if a restore goes wrong | — | The server is on-premise with **no hypervisor snapshot** ([gap 1](05-gaps-and-open-questions.md#1-hosting-provider--resolved-datalix-treated-as-on-premise)). There is nothing behind the S3 bucket. |

Phase 1 done means **Track A works**. It does not mean you are recoverable. Go to
[#11](../../issues/11) next.
