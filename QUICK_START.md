# K3s Backup — Quick Start

**Goal:** two backup jobs running daily to S3, and a restore we've actually tested.

**Total time:** 1–2 weeks, most of it waiting for scheduled runs.

| Day | Where | Time | What happens |
|-----|-------|------|--------------|
| 1 | k3-master | 30 min | Run the preflight checker (`--no-aws`) |
| 2–3 | AWS account | 1–2 hrs | Bucket, KMS key, the two logins |
| 4 | k3-master | 30 min | Install job 1, re-run preflight **with** AWS |
| 5 | k3-master | 30 min | First real backup, then turn the timer on |
| 6–7 | laptop + cluster | 1 hr | Install job 2 (Velero) and verify it really reads the volumes |
| 8+ | k3-master | daily | Watch both jobs, then test a restore |

---

## DAY 1 — Just look (run on k3-master)

**Risk: zero.** Read-only, changes nothing.

```bash
scp scripts/k3s-backup-preflight.sh root@45.90.98.51:/tmp/
sudo install -m 0750 -o root -g root /tmp/k3s-backup-preflight.sh /usr/local/sbin/

# AWS doesn't exist yet, so skip those checks
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws
```

It prints PASS/WARN/FAIL for every check, an inventory of what's running, and **a list of anything
missing with the exact command to fix it**. AWS failures on Day 1 are expected.

Then the one check the preflight can't judge for you — **where our HTTPS certificates come from**.
This is the single most important unknown in the whole project
([#4](../../issues/4)):

```bash
sudo k3s kubectl get ingressroute -A
sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -iA3 'acme\|certresolver'
```

If Traefik keeps `acme.json` in an `emptyDir`, nothing in this plan backs it up and every restore
comes back with broken HTTPS. Find out now, not during an outage.

**→ Send me the output and I'll give you the Day 2 commands.**

---

## DAY 2–3 — Set up AWS (from your laptop)

Full commands are in [07 — Phase 0 & 1 Execution](docs/07-phase-0-1-execution.md). In short:

```
1. Create a KMS key
2. Create the bucket k3-master-dr — encryption ON AT CREATION, versioning on, public access blocked
3. Create the BACKUP WRITER login   (Put/Get/List/AbortMultipartUpload bucket-wide;
                                     DELETE ONLY on velero/*; kms:GenerateDataKey + kms:Decrypt)
4. Create the RESTORE READER login  (Get/List/kms:Decrypt) — store it offline, never on the server
5. Add exactly two lifecycle rules: k3s/daily/ expire 8 days, k3s/weekly/ expire 31 days
```

**Region:** `ap-south-1` (Mumbai).

> ⚠️ **No lifecycle rule on `velero/`.** Velero expires its own backups by TTL, and an S3 rule
> would delete chunks that valid backups still depend on.

---

## DAY 4 — Install job 1 (run on k3-master)

```bash
# 1. credentials
sudo mkdir -p /etc/k3s-backup && sudo chmod 0700 /etc/k3s-backup
sudo nano /etc/k3s-backup/backup.env       # S3_BUCKET, AWS_REGION, KMS_KEY_ID (full ARN), keys
sudo chmod 0600 /etc/k3s-backup/backup.env

# 2. from your laptop — copy to /tmp, never straight into a system directory
scp scripts/k3s-server-backup.sh <user>@45.90.98.51:/tmp/
scp scripts/systemd/k3s-backup.service scripts/systemd/k3s-backup.timer <user>@45.90.98.51:/tmp/

# 3. on the server — install with explicit ownership and modes
sudo install -m 0750 -o root -g root /tmp/k3s-server-backup.sh /usr/local/sbin/
sudo install -m 0644 -o root -g root /tmp/k3s-backup.service /tmp/k3s-backup.timer \
     /etc/systemd/system/
sudo install -d -m 0700 -o root -g root /var/backups/k3s

# 4. preflight WITH AWS — must come back READY before going further
sudo /usr/local/sbin/k3s-backup-preflight.sh

# 5. dry run: builds everything, uploads nothing
sudo DRY_RUN=1 /usr/local/sbin/k3s-server-backup.sh
ls -la /var/backups/k3s/*/
```

You should see exactly four artifacts plus their `.sha256` files:

```text
state.db   k3s-identity.tar.gz   node-config.tar.gz   MANIFEST.json
```

Check the manifest recorded the right version:

```bash
sudo python3 -m json.tool /var/backups/k3s/*/MANIFEST.json | grep k3s_version
```

> **Step 4 matters.** The preflight does a real 64 MB upload. A small test file passes even when
> the login is missing `kms:Decrypt` — and then every real backup fails, because anything over
> 8 MB goes up as a multipart upload ([#21](../../issues/21)).

---

## DAY 5 — First real backup, then turn it on

```bash
sudo /usr/local/sbin/k3s-server-backup.sh

# confirm it arrived
sudo -E aws s3 ls "s3://k3-master-dr/k3s/daily/" --recursive

# turn on the daily schedule
sudo systemctl daemon-reload
sudo systemctl enable --now k3s-backup.timer
systemctl list-timers 'k3s-backup*'
```

From now on: **02:15 UTC every day**, and on Sundays it writes a second copy under `k3s/weekly/`.

---

## DAY 6–7 — Install job 2 (Velero)

Job 1 cannot restore a deleted PVC or a single deleted Secret. Velero is the only thing that can.

Run this from your laptop, from your clone of this repo, with a kubeconfig that has cluster-admin.
Velero needs the **same** backup-writer credentials job 1 uses, in AWS's own file format:

```bash
cat > ./velero-credentials <<'EOF'
[default]
aws_access_key_id=<the backup writer key>
aws_secret_access_key=<the backup writer secret>
EOF
chmod 600 ./velero-credentials
```

```bash
export S3_BUCKET=k3-master-dr AWS_REGION=ap-south-1 KMS_KEY_ID=arn:aws:kms:...
export CREDS_FILE=./velero-credentials
./scripts/velero/install-velero.sh

kubectl apply -f scripts/velero/schedule-daily.yaml
kubectl apply -f scripts/velero/schedule-weekly.yaml

shred -u ./velero-credentials    # it is now a Secret in the cluster; don't leave a copy around
```

**Then verify it properly — a green checkmark is not evidence:**

```bash
velero backup create verify-$(date +%s) --wait
velero backup describe <name> --details
```

All **six** monitoring PVCs must appear under *Pod Volume Backups*. If that section is empty, the
node-agent isn't reading the volumes and you have a backup of nothing that reports success. See
[02 §9 gap 2](docs/02-backup-strategy.md#9-gaps-that-still-need-validating).

Finish by restoring one thing into a scratch namespace. That's the proof.

---

## DAY 8+ — Watch it

```bash
journalctl -u k3s-backup.service --since '48 hours ago' | tail -30
velero backup get
sudo -E aws s3 ls s3://k3-master-dr/ --recursive --human-readable | tail
df -h /
```

**What you should see:** a new folder under `k3s/daily/` and a new Velero backup every day, without
anyone doing anything. Then set up the alerts (Phase 3) so you don't have to keep looking.

---

## What could go wrong

| Problem | Fix |
|---------|-----|
| Not sure what's missing | **Run the preflight** — it lists every problem with the exact fix command |
| Small uploads work, the database upload fails | Missing `kms:Decrypt` on the backup login — [#21](../../issues/21) |
| `AccessDenied` on *every* upload | `KMS_KEY_ID` is a bare key id instead of the full ARN — [#24](../../issues/24) |
| Velero backups never expire | The login is missing `s3:DeleteObject` on `velero/*` — TTL expiry *is* Velero deleting its own objects |
| `Pod Volume Backups` is empty | node-agent hostPath doesn't match K3s's kubelet root. **Fix this before trusting any backup** |
| Running low on disk | Clean up `/var/backups/k3s` — the script already prunes anything older than 3 days |
| The server dies | [Restore runbook §A](docs/03-restore-runbook.md#a--full-server-rebuild) |
| Someone deleted a PVC or a Secret | [Restore runbook §B](docs/03-restore-runbook.md#b--restoring-one-pvc-or-one-object) — minutes, not hours |

---

## What to do next

```bash
sudo /usr/local/sbin/k3s-backup-preflight.sh --no-aws
```

Send me that output plus the two Traefik commands from Day 1, and I'll give you the exact AWS
commands to paste.
