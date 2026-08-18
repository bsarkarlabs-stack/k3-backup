# 03 — Restore Runbook

**How to go from a brand new, empty Ubuntu server to a fully working production system.**

This is the one document where **the order of the steps really matters**. Don't skip ahead or
reorder anything.

> ⚠️ **We have never actually run through this yet.** Until
> [Phase 5](04-implementation-todo.md#phase-5--restore-validation) is complete, treat every step
> below as unproven. We don't yet know exactly how long each step takes or what might go wrong.

---

## What this runbook can actually do today

Read this bit first. Only part of our backup system is built so far, and a couple of the steps
below need pieces that **don't exist yet**. Finding that out at step 8 in the middle of a real
outage is exactly what this section is here to prevent. Tracked as [#18](../../issues/18).

**✅ What we can genuinely recover right now:**

| We get back | From which backup folder |
|-------------|--------------------------|
| The K3s database (the whole cluster's state) | `cluster-state/db/` |
| The cluster's identity — certificates, join key, token | `cluster-state/server-identity/` |
| K3s's own settings and service file | `config/` |
| K3s's built-in setup files (DNS, Traefik, metrics) | `manifests/` |
| The server's OS settings — network, firewall, SSH, packages | `node-config/` |
| Which container images to pull | `image-manifest/` |
| Which K3s version to install, and which files belong together | `run-manifests/` |

**❌ What we cannot recover right now:**

| What's missing | What that means in practice | Waiting on |
|----------------|------------------------------|------------|
| **App data volumes** — Prometheus, Loki, Grafana, Alertmanager | **Nothing at all backs up our ~7.8 GB of monitoring history.** A restore brings the monitoring stack back completely empty. | [#11](../../issues/11) |
| Restoring one single object | Can't put back one accidentally deleted Deployment or Secret — the only option is rolling the entire database back, which undoes *everything* | [#11](../../issues/11) |
| Restoring into a fresh/different cluster | Our database backup only helps when rebuilding **this same server** at **this same K3s version** | [#11](../../issues/11) |
| ArgoCD's own settings export | ArgoCD only comes back via the restored database | [#1](../../issues/1), [#20](../../issues/20) |

> **In one sentence:** today we can rebuild **this server**. We cannot yet restore into a fresh
> cluster, and we will not get our monitoring history back. Steps 8 and 9 are marked as blocked
> below so nobody gets stuck on them mid-outage.

Delete this whole section once [#11](../../issues/11) is done.

---

## Before you start

| Thing you need | Details |
|--------------|--------|
| A read-only backup login | The S3 read-only login, kept **offline** somewhere safe — not the login that was on the broken server |
| A matching new server | 8 CPU cores, 22 GB RAM, at least 97 GB disk, 64-bit |
| Operating system | Ubuntu 24.04 LTS |
| K3s version | **Don't guess — read it out of the run manifest.** It was `v1.34.5+k3s1` when this doc was written |
| Which backup to use | The run manifest tells you. Don't try to match up timestamps by eye |

### Step 0 — Open the run manifest first

Every backup run writes a small file called `run-manifests/manifest-<timestamp>.json`. It records
**which K3s version made that backup** and the fingerprint of every file in that run
([#17](../../issues/17)). **Start here** — it removes the two things you'd otherwise have to guess
at while the server is down.

Backups are filed in dated folders (`run-manifests/2026/08/18/...`), so use `--recursive` when
listing — otherwise you'll just see year folders.

```bash
# the five most recent runs
aws s3 ls "s3://$BUCKET/run-manifests/" --recursive | sort | tail -5

# grab the newest manifest
KEY=$(aws s3 ls "s3://$BUCKET/run-manifests/" --recursive \
        | grep '\.json$' | sort | tail -1 | awk '{print $4}')
echo "$KEY"
aws s3 cp "s3://$BUCKET/$KEY" ./manifest.json
python3 -m json.tool manifest.json
```

> The dated folders still sort correctly, because the date is in the path *and* in the filename —
> so `sort | tail -1` reliably gives you the newest run.

What to take from it:

- **`k3s_version`** — the exact version to install in step 3. Use this, **not** the version number
  written in this document. Docs go out of date; the manifest is written by the backup itself.
- **`os_release`** and **`arch`** — what kind of server to set up in step 1.
- **`artifacts`** — the exact file names, folders and fingerprints belonging to this one run.
- **`mode`** — `full` means everything was backed up; `db` means database only.
- **`pairs_with_full_run`** — **this is the one that saves you time.** The database is backed up
  every 6 hours, but the certificates, config and setup files only once a day. This field names
  the `full` run whose files go together with this database snapshot, so you're not comparing
  timestamps across seven folders while the server is down.

**So for a complete rebuild:** take the newest database snapshot, read its `pairs_with_full_run`,
and pull the certificates, config, setup files and OS settings from **that** run.

Each entry under `artifacts` already carries its exact `s3_prefix`, so you don't have to work out
any folder paths yourself — just join the prefix and the filename:

```bash
python3 - manifest.json <<'PY'
import json
d = json.load(open("manifest.json"))
print(f"# k3s version to install: {d['k3s_version']}")
print(f"# pairs with full run   : {d['pairs_with_full_run']}")
for a in d["artifacts"]:
    print(f"aws s3 cp s3://$BUCKET/{a['s3_prefix']}/{a['filename']} .")
PY
```

That prints a ready-to-run download command for every file in the set.

> **Which database tier?** The 6-hourly snapshots live under `cluster-state/db/6hourly/` and the
> daily ones under `cluster-state/db/daily/`. For the freshest possible state take the newest from
> `6hourly/`; to go back more than a week, only `daily/` will still have it.

> Why they have to be paired at all: K3s stores the cluster's identity information *inside* its own
> database, locked with the server token. So the database and the certificate archive are two
> halves of the same thing, and the manifest is what tells you which halves match.

> If `pairs_with_full_run` says `unknown`, that backup ran before any full backup had been taken.
> Fall back to simply using the most recent `full` run available.

> If `k3s_version` says `unknown`, the backup ran at a moment when it couldn't read the K3s
> program. Fall back to [01 — Discovery Baseline](01-discovery-baseline.md) and treat the version
> as unconfirmed.

> **Check every file's fingerprint (checksum) before restoring anything.** Compare each downloaded
> file against the fingerprint listed **in the manifest**, not just its own `.sha256` file — the
> manifest is what proves those files all came from the *same backup run*. Restoring from a
> corrupted or mismatched file would waste precious time during an actual outage.

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

Install exactly the version shown as **`k3s_version` in the manifest you opened in step 0** — it
was `v1.34.5+k3s1` when this document was written, but the manifest is the real answer.

> Using a different K3s version than what made the backup is the fastest way to turn a simple
> restore into a confusing debugging session. Don't let the installer just grab "whatever's
> latest" — pin the exact version. And trust the manifest over any version number written in a
> document, including this one.

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

## Step 5a — Only if the new server has a different IP or hostname

**Skip this entire step** if the replacement machine keeps the same address (`45.90.98.51`) and
the same hostname (`k3-master`). If either one changes, deal with it **now**, before starting K3s
in step 6.

### Hostname

Keep the hostname as `k3-master` if there's any way to do so. K3s identifies the server by its
name inside the database — so if it boots up with a different name, K3s registers it as a
**brand new second server**, while the original entry sits there marked `NotReady` with all our
apps still assigned to a machine that no longer exists.

```bash
sudo hostnamectl set-hostname k3-master
```

If the name genuinely has to change, expect to clean up the old entry afterwards:

```bash
kubectl get nodes                      # the old name will show as NotReady
kubectl delete node <old-node-name>
```

### IP address

Good news: the `tls/` folder we restored contains the cluster's **master certificate and its
private key**, so K3s can and does create fresh certificates for the new address automatically on
startup. **We do not need to regenerate anything.** What we *do* need to check:

| Thing to check | What to do about it |
|------|--------|
| `/etc/rancher/k3s/k3s.yaml` | Points at `127.0.0.1:6443` by default, which is fine on the server itself. Any copy used from a laptop needs its `server:` address updated. |
| `--tls-san` settings | If `k3s.service` or a config file lists the **old** IP address here, update it **before** the first start — otherwise K3s issues certificates that don't match the new address. |
| DNS / website records | Repoint anything currently resolving to `45.90.98.51`. |
| Services with a hardcoded IP | Run `kubectl get svc -A -o wide \| grep 45.90.98.51` — anything listed here has the old address **written into it** and will **not** fix itself. |
| ArgoCD / monitoring URLs | Any setting that references the old IP address directly instead of a DNS name. |
| Firewall rules | The restored firewall rules from `node-config/` may still reference the old network. |

**Check after step 6:**

```bash
kubectl get nodes -o wide                            # exactly one server, Ready, correct IP
kubectl get svc -A -o wide | grep -i 45.90.98.51     # expect no results
sudo journalctl -u k3s | grep -i 'certificate\|x509' | tail
```

> ⚠️ If old `kubectl` configs on other laptops start failing with certificate errors after the
> move, **that's expected** — the *address* changed, not the certificate authority. Just update
> the `server:` address in those config files. **Do not "fix" this by regenerating certificates**
> — that throws away the cluster identity we just restored.

---

## Step 6 — Start K3s, and check that the server itself is healthy

**Check with:**
- `systemctl status k3s` should say `active (running)`
- `kubectl get nodes` should show `k3-master   Ready   control-plane   v1.34.5+k3s1`
- `journalctl -u k3s` should show no certificate errors or database errors

> If the server shows as `NotReady`, or you see certificate errors, **stop here.** Don't move on
> to the next steps — fixing app-level problems on top of a broken control plane just makes
> everything harder to diagnose.

### Certificate errors: the normal kind vs. the real problem

Before treating a certificate error as a failed restore, work out which kind you're looking at
([#19](../../issues/19)). Here's the background:

K3s uses two tiers of certificate. The **master certificate** (the "CA") is valid for about **ten
years**. All the everyday certificates it issues are valid for about **one year**. When K3s
starts up and finds those one-year certificates are expired or nearly expired, it quietly issues
fresh ones using the master certificate we restored.

| What you're seeing | Which kind | What to do |
|---------|-----------|------------|
| Certificate/expiry errors on first start, from a backup roughly a year old or older | **Normal.** The master certificate is still valid and K3s is reissuing the short-lived ones. | Let it finish, restart K3s once, check again. It fixes itself. |
| The errors are still there after a clean restart | **Real problem** | Go back to step 4 and confirm `tls/` and `cred/` actually restored properly |
| The `cred/` folder is missing or empty | **Real problem** | The identity backup is incomplete — use an older backup set |
| Old `kubectl` configs on other laptops fail after moving servers | **Normal** — the *address* changed, not the certificate | Update the `server:` address in those config files |

> 🚨 **Never regenerate the master certificate just to make an error go away.** Doing that throws
> away the cluster identity we just restored, breaks every existing `kubectl` config and every
> machine that was registered with the cluster, and turns a recoverable situation into a complete
> rebuild. Same warning as in [step 5a](#step-5a--only-if-the-new-server-has-a-different-ip-or-hostname).

Handy check — this only reads **expiry dates**, never any private key material:

```bash
for c in /var/lib/rancher/k3s/server/tls/server-ca.crt \
         /var/lib/rancher/k3s/server/tls/client-ca.crt \
         /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt; do
  printf '%s\n  ' "$c"; sudo openssl x509 -enddate -noout -in "$c" 2>/dev/null || echo "not found"
done
```

---

## Step 7 — Confirm the basics are working before touching any data

Run `kubectl get pods -A` and check things look reasonable **before** touching any actual data.

You should see these sections (namespaces): `kube-system`, `monitoring`, `argocd`, and our SBE /
COW app sections.

---

## Step 8 — Restore app data using Velero

> 🚫 **BLOCKED — can't be done today.** Velero isn't installed and there is no Velero backup
> sitting in S3 ([#11](../../issues/11)). **Our app data volumes are not backed up by anything at
> all**, so there is genuinely nothing here to restore from. Skip ahead to step 10 — the
> monitoring stack will come back up with empty storage.
>
> All Prometheus, Loki, Grafana and Alertmanager history from before the incident is **gone**.
> Nothing in this runbook brings it back until [#11](../../issues/11) is built. Everything below
> is how this step *will* work once it is.

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

> 🚫 **BLOCKED as written — there's no export file to import.** Nothing currently runs a scheduled
> ArgoCD settings export ([#1](../../issues/1)), so there's no file for this step to use.
>
> **What actually happens when rebuilding the same server:** ArgoCD's settings live inside the
> database we restored back in step 4, so it should come back on its own. Just check it rather
> than reinstalling anything.
>
> **On a genuinely fresh cluster** there's nothing to restore ArgoCD from at all — which is part
> of why [#20](../../issues/20) is still open.

Once the export exists, importing it brings back ArgoCD's Apps, Projects, Git login credentials,
and any single-sign-on/permission settings. ArgoCD then reconnects to Git on its own and starts
syncing.

**Check with:** all seven of ArgoCD's core components should show as `Running`; running
`argocd repo list` should show our Git repos as connected.

---

## Step 10 — Let ArgoCD redeploy our apps from Git

Remember: our SBE and COW apps **don't store any data on disk** — they come back purely by
ArgoCD syncing them from Git. Nothing special needed here.

**Check with:** run `argocd app list` — our SBE and COW apps should reach `Synced` / `Healthy`.

---

## Step 11 — Double-check everything

| Check | What we expect to see | Can this pass today? |
|-------|-------|----------------------|
| `argocd app list` | All our **real** apps Synced/Healthy (remember the already-broken ones listed above) | ✅ |
| Website/traffic routing | Reachable, and traffic routing correctly | ✅ |
| HTTPS certificates | Valid, no browser warnings on any of our websites | ✅ |
| `kubectl get pv,pvc -A` | All six data volumes show as `Bound` | ✅ — they'll be `Bound`, but **empty** until [#11](../../issues/11) |
| Grafana | Loads properly, connected to its data sources | ⚠️ Dashboards only come back if they're stored as config; anything saved inside Grafana's own storage is gone |
| Prometheus | Can run queries | ⚠️ **There will be no historical data.** That's expected right now — it is *not* a failed restore |
| Loki | Service is healthy | ⚠️ Log searches won't return anything from before the incident |
| Alertmanager | Running, with its alert routes configured | ⚠️ Any silences and alert history are lost |

> The ⚠️ rows only become ✅ once [#11](../../issues/11) is built. Until then, an empty Prometheus
> after a restore is the **expected** result — don't burn outage time trying to debug it.

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

| What happened | Which steps you actually need | Possible today? |
|----------|--------------|-----------------|
| The database got corrupted, but the server itself is fine | Steps 4 through 7 | ✅ |
| Certificates got lost, but the server itself is fine | Step 4 (just `tls/` and `cred/`) through step 6 | ✅ |
| A bad app deployment went out | Revert it in Git + roll back in ArgoCD (step 10 territory) | ✅ — Git is the source of truth |
| Moving to a new machine / full disaster | Steps 0 through 12 | ⚠️ Partly — the server rebuilds, **app data does not** |
| Someone accidentally deleted a Kubernetes resource | Restore that one object from Velero — no server-level work | 🚫 [#11](../../issues/11). The only fallback is rolling the whole database back to an earlier snapshot, which undoes **everything else too** |
| One data volume's data got lost | Just step 8, focused on that one volume | 🚫 [#11](../../issues/11) — **not recoverable today** |
| ArgoCD got wiped out | Just step 9 | ⚠️ Comes back via the database on the same server; nothing to restore from on a fresh one |
| **Complete server loss** | **Steps 0 through 12** | ⚠️ Partly — see the table at the top |

> Those 🚫 rows are the strongest argument for doing [#11](../../issues/11) sooner rather than
> later. Someone accidentally deleting a single Secret or Deployment is a **far** more common
> incident than losing the whole server — and it's the one this runbook currently handles worst.
