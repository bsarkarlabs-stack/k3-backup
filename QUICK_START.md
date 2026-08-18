# K3s Backup — Quick Start

**Goal:** Backup K3s to AWS every day. If server dies, restore from backup.

**Total time:** 1-2 weeks (most is automatic)

---

## DAY 1 — Verify (run on k3-master)

**Time:** 30 minutes  
**Risk:** Zero — nothing changes, read-only  
**Action:** Run these commands, send me the output

```bash
# Check K3s version
k3s --version

# Check disk space
df -h /

# Check certificate files
sudo find /var/lib/rancher/k3s/server/tls -printf '%M %u:%g %10s %p\n' | sort -k4

sudo find /var/lib/rancher/k3s/server/cred -printf '%M %u:%g %10s %p\n' | sort -k4

# Check Traefik ingress (important!)
sudo k3s kubectl get ingressroute -A

sudo k3s kubectl -n kube-system get deploy traefik -o yaml | grep -i acme
```

**Why?** Verify that:
- K3s version is still the same
- Disk has enough space
- Certificate files exist
- Ingress configuration is safe

**→ Send output, then I give you next step**

---

## DAY 2-3 — AWS Setup (on your laptop)

**Time:** 1-2 hours  
**Where:** Your AWS account (need admin access)  
**Action:** Create S3 bucket, encryption key, IAM user

After you send Day 1 output, I'll give exact commands. Basically:

```
1. Log into AWS
2. Create KMS key (for encryption)
3. Create S3 bucket (k3-master-dr)
4. Create IAM user (for backups)
5. Copy credentials (will paste on k3-master later)
```

**Region:** `ap-south-1` (Mumbai) — default, can change one line if needed

---

## DAY 4 — Deploy Script (run on k3-master)

**Time:** 30 minutes  
**Risk:** Very Low — creates new directory, nothing else changes

```bash
# 1. Create credential file
sudo nano /etc/k3s-backup/backup.env
# Paste AWS keys here

# 2. Upload script (from your laptop)
scp scripts/k3s-track-a-backup.sh root@45.90.98.51:/usr/local/sbin/
scp scripts/systemd/* root@45.90.98.51:/etc/systemd/system/

# 3. Test run (builds backup, does NOT upload)
#    DRY_RUN=1 is what makes it skip the upload — without it, this uploads for real.
sudo DRY_RUN=1 /usr/local/sbin/k3s-track-a-backup.sh full

# 4. Check output
ls -la /var/backups/k3s/*/
```

---

## DAY 5-7 — First Real Backup (run on k3-master)

**Time:** 30 minutes  
**Action:** Upload backup to AWS for real

```bash
# Upload database only (small test first)
sudo /usr/local/sbin/k3s-track-a-backup.sh db

# Verify it reached AWS
sudo -E aws s3 ls s3://k3-master-dr/cluster-state/db/

# Upload everything
sudo /usr/local/sbin/k3s-track-a-backup.sh full

# Verify all prefixes
sudo -E aws s3 ls s3://k3-master-dr/ --recursive
```

---

## DAY 8 — Enable Automatic Schedule (run on k3-master)

**Time:** 5 minutes  
**Action:** Turn on the timers

```bash
# Install systemd timers
sudo systemctl daemon-reload
sudo systemctl enable --now k3s-backup-db.timer
sudo systemctl enable --now k3s-backup-full.timer

# Verify
systemctl list-timers 'k3s-backup*'

# Now it runs automatically:
# - Database backup every 6 hours (at 00:20, 06:20, 12:20, 18:20 UTC)
# - Full backup every day at 02:15 UTC
```

---

## WEEK 2+ — Monitor (check daily)

```bash
# Check logs
journalctl -u 'k3s-backup@*' --since '24 hours ago' | tail -30

# Check disk space
df -h /

# Check how much data in S3
sudo -E aws s3 ls s3://k3-master-dr/ --recursive --human-readable | tail
```

**Expected:** New backups should appear every day

---

## Summary

| Day | Location | Time | What |
|-----|----------|------|------|
| 1 | k3-master | 30m | Run verify commands |
| 2-3 | AWS account | 1-2h | Create bucket + keys |
| 4 | k3-master | 30m | Deploy script |
| 5-7 | k3-master | 30m | First real backup |
| 8 | k3-master | 5m | Enable timers |
| 9+ | k3-master | daily | Monitor logs |

---

## What Can Go Wrong

| Problem | Fix |
|---------|-----|
| AWS credentials wrong | Day 2-3: re-check in AWS console |
| Low disk space | Clean up `/var/backups` |
| Backup upload fails | Check network, firewall rules |
| Server dies | Restore from AWS backup |

---

## Next Step

**Run Day 1 commands on k3-master, send output.**

I will then give you the exact AWS commands to copy-paste (Day 2-3).

