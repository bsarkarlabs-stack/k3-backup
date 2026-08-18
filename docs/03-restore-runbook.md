# 03 — Restore Runbook

**How to go from a brand new, empty Ubuntu server to a fully working production system.**

This is the one document where **the order of the steps really matters**. Don't skip ahead or
reorder anything.

> ⚠️ **We have never actually run through this yet.** Until
> [Phase 5](04-implementation-todo.md#phase-5--restore-validation) is complete, treat every step
> below as unproven. We don't yet know exactly how long each step takes or what might go wrong.

---

## Before you start

| Thing you need | Details |
|--------------|--------|
| A read-only backup login | The S3 read-only login, kept **offline** somewhere safe — not the login that was on the broken server |
| A matching new server | 8 CPU cores, 22 GB RAM, at least 97 GB disk, 64-bit |
| Operating system | Ubuntu 24.04 LTS |
| K3s version | **`v1.34.5+k3s1`** — this exact version, nothing newer |
| Which backup to use | Find the most recent set of backups where every piece is from around the same time, and note that timestamp |

> **Check the backup's fingerprint (checksum) before restoring anything.** Every backup file has
> a saved SHA-256 fingerprint. Restoring from a corrupted file would waste precious time during
> an actual outage.

### Things that were already broken before we started — not restore failures

These ArgoCD apps were already unhealthy **before any backup work began**. When checking things
after a restore, don't mistake these for something the restore broke:

| App | Already-broken state |
|-------------|--------------------|
| `demo-app` | Not synced / missing |
| `nginx-app` | Synced, but unhealthy |
| `nginx-app-dev` | Not synced, unhealthy |
| `nginx-app11` | Not synced, unhealthy |

---

## Step 1 — Get a fresh Ubuntu 24.04 server ready

Match the original server's specs: 8 CPU cores, 22 GB RAM, similar disk size. Double check it's
64-bit.

**Check with:** `lsb_release -a`, `uname -m`, `nproc`, `free -h`, `df -h`

---

## Step 2 — Restore the server's basic settings

Hostname, static network address, firewall rules, SSH login keys, timezone/clock settings — all
of this comes from the `node-config/` backup folder.

> ⚠️ **Known gap:** this isn't actually being backed up automatically yet. See
> [Gaps §3](05-gaps-and-open-questions.md#3-node-level-os-configuration-not-captured) — until
> that's fixed, this step means manually setting everything up from memory/notes.

**Check with:** `hostname` should say `k3-master`; the network address should match what we
expect.

---

## Step 3 — Install K3s (matching version), but don't start it yet

Install exactly version **`v1.34.5+k3s1`** — nothing newer, nothing older.

> Using a different K3s version than what made the backup is the fastest way to turn a simple
> restore into a confusing debugging session. Don't let the installer just grab "whatever's
> latest" — pin the exact version.

Install it, then **immediately stop the service** — we need to put our backed-up database in
place before K3s ever gets a chance to write anything new to it.

**Check with:** `k3s --version` should say `v1.34.5+k3s1`; the service should be installed but
not running.

---

## Step 4 — With K3s stopped, restore `/var/lib/rancher/k3s/server/`

Restore this **as one complete unit** — this is the important correction explained in
[Backup Strategy §2](02-backup-strategy.md#2-the-correction-that-changes-the-whole-plan):

```text
/var/lib/rancher/k3s/server/
├── db/          state.db, state.db-wal, state.db-shm
├── tls/         master certificate + connection certificates
├── cred/        the join password/key
├── token        (make sure permissions end up as root-only, 0600)
└── manifests/   K3s's built-in setup files
```

**Check with:** run `stat -c '%a %U:%G' /var/lib/rancher/k3s/server/token` — it should say
`600 root:root`. Also confirm all three `state.db*` files are there, not just `state.db` on its
own.

> Before overwriting `manifests/`, compare `traefik-helmchartconfig.yaml` against what's already
> there — remember, someone edited this one by hand on the original server.

---

## Step 5 — Restore `/etc/rancher/k3s/`

```text
/etc/rancher/k3s/
├── k3s.yaml
└── registries.yaml
/etc/systemd/system/k3s.service     (only if it was customized)
```

If we restored the systemd service file, run `systemctl daemon-reload` afterward.

> `k3s.yaml` has the server's address written inside it. If we're moving to a **different IP
> address** (not the same machine), we'll need to update this file so `kubectl` on our own laptop
> still works.

---

## Step 6 — Start K3s, and check that the server itself is healthy

**Check with:**
- `systemctl status k3s` should say `active (running)`
- `kubectl get nodes` should show `k3-master   Ready   control-plane   v1.34.5+k3s1`
- `journalctl -u k3s` should show no certificate errors or database errors

> If the server shows as `NotReady`, or you see certificate errors, **stop here.** Don't move on
> to the next steps — fixing app-level problems on top of a broken control plane just makes
> everything harder to diagnose.

---

## Step 7 — Confirm the basics are working before touching any data

Run `kubectl get pods -A` and check things look reasonable **before** touching any actual data.

You should see these sections (namespaces): `kube-system`, `monitoring`, `argocd`, and our SBE /
COW app sections.

---

## Step 8 — Restore app data using Velero

**This is not a plain file copy** — see
[Backup Strategy §6](02-backup-strategy.md#6-the-persistent-volume-gotcha) for why.

1. Install Velero, pointed at the same S3 bucket
2. Let the data volumes get created first (they only get created once something actually needs
   to use them — a pod has to be scheduled first)
3. Let Velero's node-agent fill in the actual files afterward

**Check with:** all six monitoring data volumes should show as `Bound`; the total space used
under `/var/lib/rancher/k3s/storage/` should roughly match the original ~7.8 GB.

*Steps 8 and 10 don't depend on each other and can be done at the same time.*

---

## Step 9 — Reinstall ArgoCD, then import its settings

This brings back ArgoCD's Apps, Projects, Git login credentials, and any single-sign-on/permission
settings. ArgoCD then reconnects to Git on its own and starts syncing.

**Check with:** all seven of ArgoCD's core components should show as `Running`; running
`argocd repo list` should show our Git repos as connected.

---

## Step 10 — Let ArgoCD redeploy our apps from Git

Remember: our SBE and COW apps **don't store any data on disk** — they come back purely by
ArgoCD syncing them from Git. Nothing special needed here.

**Check with:** run `argocd app list` — our SBE and COW apps should reach `Synced` / `Healthy`.

---

## Step 11 — Double-check everything

| Check | What we expect to see |
|-------|-------|
| `argocd app list` | All our **real** apps Synced/Healthy (remember the already-broken ones listed above) |
| Website/traffic routing | Reachable, and traffic routing correctly |
| Grafana | Loads properly, dashboards are there, connected to its data sources |
| Prometheus | Can run queries; **historical data is there** — this proves step 8 actually worked |
| Loki | Log searches return results |
| Alertmanager | Running, with its alert routes configured |
| HTTPS certificates | Valid, no browser warnings on any of our websites |
| `kubectl get pv,pvc -A` | All six data volumes show as `Bound` |

---

## Step 12 — Switch traffic over

If this is a full move to a new server (not just fixing the same machine), point DNS/traffic at
the new server now.

**After switching over:**
- Update the backup schedule to point at the new server, and confirm the next scheduled backup
  actually succeeds
- **Change the S3 login credentials** if there's any chance the old server was compromised or is
  unaccounted for
- Write down exactly how long the whole recovery took — this is our real recovery-time number

---

## Shortcuts for smaller problems

Not every incident needs all twelve steps.

| What happened | Which steps you actually need |
|----------|--------------|
| Someone accidentally deleted a Kubernetes resource | Just restore that one object from Velero — no server-level work needed |
| A bad app deployment went out | Revert it in Git + roll back in ArgoCD (this is step 10 territory) |
| One data volume's data got lost | Just step 8, focused on that one volume |
| The database got corrupted, but the server itself is fine | Steps 4 through 7 |
| Certificates got lost, but the server itself is fine | Step 4 (just `tls/` and `cred/`) through step 6 |
| ArgoCD got wiped out | Just step 9 |
| **Complete server loss / moving to a new machine / full disaster** | **All twelve steps** |
