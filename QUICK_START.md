# K3s Backup — Quick Start

**Goal:** Back up K3s to AWS every day. If the server ever dies, restore from that backup.

**Total time needed:** 1–2 weeks (most of it happens automatically, in the background)

---

## DAY 1 — Just check things (run on k3-master)

**Time needed:** 30 minutes
**Risk:** Zero — this only reads information, nothing gets changed
**What to do:** Run these commands, and send me the output

```bash
# Check K3s version
k3s --version

# Check how much disk space is free
df -h /

# Check the certificate files
sudo find /var/lib/rancher/k3s/server/tls -printf '%M %u:%g %10s %p\n' | sort -k4

sudo find /var/lib/rancher/k3s/server/cred -printf '%M %u:%g %10s %p\n' | sort -k4

# Check the Traefik ingress setup (this one matters!)
sudo k3s kubectl get ingressroute -A

sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -i acme
```

**Why we're doing this:** to confirm that:
- The K3s version hasn't changed since we last checked
- There's still enough free disk space
- The certificate files are actually there
- Nothing about the ingress setup is unusual or risky

**→ Send me the output, and I'll give you the next step**

---

## DAY 2–3 — Set up AWS (on your own laptop)

**Time needed:** 1–2 hours
**Where:** Your AWS account (you'll need admin access)
**What to do:** Create the S3 bucket, an encryption key, and a login for backups

Once you send me the Day 1 output, I'll give you the exact commands to copy and paste. In short,
here's what we're doing:

```
1. Log into AWS
2. Create an encryption key (KMS)
3. Create the S3 bucket (k3-master-dr)
4. Create a dedicated login (for backups only)
5. Copy the login credentials (you'll paste these onto k3-master later)
```

**Region:** `ap-south-1` (Mumbai) — this is our default, and it's easy to change later if needed

---

## DAY 4 — Install the backup script (run on k3-master)

**Time needed:** 30 minutes
**Risk:** Very low — this only creates a new folder, nothing else changes

```bash
# 1. Create the credentials file
sudo nano /etc/k3s-backup/backup.env
# Paste the AWS login details here

# 2. Copy the script onto the server (run this from your own laptop)
scp scripts/k3s-track-a-backup.sh root@45.90.98.51:/usr/local/sbin/
scp scripts/systemd/* root@45.90.98.51:/etc/systemd/system/

# 3. Do a test run (this builds the backup, but does NOT upload it anywhere)
#    DRY_RUN=1 is what skips the upload — without it, this really uploads for real.
sudo DRY_RUN=1 /usr/local/sbin/k3s-track-a-backup.sh full

# 4. Check what it created
ls -la /var/backups/k3s/*/
```

---

## DAY 5–7 — Do the first real backup (run on k3-master)

**Time needed:** 30 minutes
**What to do:** Actually upload a backup to AWS for real, for the first time

```bash
# Upload just the database first (small, so it's a quick test)
sudo /usr/local/sbin/k3s-track-a-backup.sh db

# Confirm it actually arrived in AWS
sudo -E aws s3 ls s3://k3-master-dr/cluster-state/db/

# Now upload everything
sudo /usr/local/sbin/k3s-track-a-backup.sh full

# Confirm every folder has something in it
sudo -E aws s3 ls s3://k3-master-dr/ --recursive
```

---

## DAY 8 — Turn on the automatic schedule (run on k3-master)

**Time needed:** 5 minutes
**What to do:** Switch on the automatic timers so backups happen on their own from now on

```bash
# Install the scheduled jobs
sudo systemctl daemon-reload
sudo systemctl enable --now k3s-backup-db.timer
sudo systemctl enable --now k3s-backup-full.timer

# Confirm they're scheduled
systemctl list-timers 'k3s-backup*'

# From now on, this runs automatically:
# - A database-only backup every 6 hours (at 00:20, 06:20, 12:20, 18:20 UTC)
# - A full backup every day at 02:15 UTC
```

---

## WEEK 2+ — Just keep an eye on it (check daily)

```bash
# Check the logs
journalctl -u 'k3s-backup@*' --since '24 hours ago' | tail -30

# Check disk space
df -h /

# Check how much data has built up in S3
sudo -E aws s3 ls s3://k3-master-dr/ --recursive --human-readable | tail
```

**What you should see:** a new backup appearing every single day, without you doing anything.

---

## Summary

| Day | Where | Time needed | What happens |
|-----|----------|------|----------------|
| 1 | k3-master | 30 min | Run the check commands |
| 2–3 | AWS account | 1–2 hrs | Create the bucket + keys |
| 4 | k3-master | 30 min | Install the script |
| 5–7 | k3-master | 30 min | Do the first real backup |
| 8 | k3-master | 5 min | Turn on the automatic schedule |
| 9+ | k3-master | daily | Keep an eye on it |

---

## What could go wrong

| Problem | How to fix it |
|---------|-----|
| AWS login doesn't work | Day 2–3: double-check it in the AWS console |
| Running low on disk space | Clean up old files under `/var/backups` |
| Backup upload keeps failing | Check network connection and firewall rules |
| The server dies | Restore from the AWS backup — see the [restore runbook](docs/03-restore-runbook.md) |

---

## What to do next

**Run the Day 1 commands on k3-master, and send me the output.**

Once I see that, I'll give you the exact AWS commands to copy and paste (Day 2–3).
