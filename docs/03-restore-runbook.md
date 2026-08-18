# 03 — Restore Runbook

**Fresh Ubuntu server → validated production.**

This is the one document where **step order carries real information**. Do not reorder.

> ⚠️ **This runbook has never been executed.** Until [Phase 5](04-implementation-todo.md#phase-5--restore-validation)
> is complete, treat every step below as untested. Timings and failure modes are unknown.

---

## What this runbook can actually deliver today

Only Track A is built. Read this before relying on the twelve steps below — several of them depend
on capability that does not exist yet, and discovering that at step 8 during an outage is exactly
the failure this section exists to prevent. Tracked as [#18](../../issues/18).

**✅ Works today — everything Track A backs up:**

| Recovered | From |
|-----------|------|
| K3s datastore (cluster state) | `cluster-state/db/` |
| Cluster identity — CA, certs, node credential, token | `cluster-state/server-identity/` |
| K3s configuration + systemd unit | `config/` |
| Static manifests (CoreDNS, Traefik, metrics-server) | `manifests/` |
| Node OS config — netplan, UFW, `/etc/ssh`, packages | `node-config/` |
| Which images to pull | `image-manifest/` |
| Which K3s version to install, and the object set | `run-manifests/` |

**❌ Does not work today:**

| Missing | Consequence | Blocked on |
|---------|-------------|------------|
| **PVC data** — Prometheus, Loki, Grafana, Alertmanager | **~7.8 GB of monitoring history is backed up by nothing.** A restore brings the stack back empty. | [#11](../../issues/11) |
| Object-level restore | Cannot restore one deleted Deployment or Secret without rolling back the whole datastore | [#11](../../issues/11) |
| Restore into a fresh cluster or a different K3s version | The datastore snapshot only helps when rebuilding **this** node at **this** version | [#11](../../issues/11) |
| ArgoCD config export | ArgoCD comes back only via the restored datastore | [#1](../../issues/1), [#20](../../issues/20) |

> **In one line:** today you can rebuild **this node**. You cannot yet restore *into* a fresh
> cluster, and you will not get monitoring history back. Steps 8 and 9 are marked blocked below.

Remove this section when [#11](../../issues/11) closes.

---

## Before you start

| Prerequisite | Detail |
|--------------|--------|
| Read credential | S3 read-only credential, held **offline** — not the one on the failed server |
| Target spec | 8 vCPU, 22 GiB RAM, ≥97 GB disk, `x86_64` |
| Target OS | Ubuntu 24.04 LTS |
| K3s version | **Read it from the run manifest** — see below. Was `v1.34.5+k3s1` at documentation time |
| Backup set | The manifest names the object set; do not assemble one by eye |

### Step 0 — Read the run manifest first

Every backup run writes `run-manifests/manifest-<TS>.json`, recording the K3s version that
produced the snapshot and the SHA-256 of every artifact in that run ([#17](../../issues/17)).
**Start here** — it removes the two guesses that would otherwise open the restore.

```bash
aws s3 ls "s3://$BUCKET/run-manifests/" | sort | tail -5

LATEST=$(aws s3 ls "s3://$BUCKET/run-manifests/" | grep '\.json$' | sort | tail -1 | awk '{print $4}')
aws s3 cp "s3://$BUCKET/run-manifests/$LATEST" .
python3 -m json.tool "$LATEST"
```

Take from it:

- **`k3s_version`** — the exact binary to install in step 3. Do **not** take the version from this
  document; markdown goes stale, the manifest does not.
- **`os_release`** and **`arch`** — what to provision in step 1.
- **`artifacts[]`** — the precise filenames, prefixes and digests belonging to this run.
- **`mode`** — `full` carries every component; `db` is datastore-only. For a full rebuild you want
  the newest `full`, plus optionally a newer `db` snapshot if one exists.

> If `k3s_version` reads `unknown`, the backup ran with the K3s binary unreadable. Fall back to
> [01 — Discovery Baseline](01-discovery-baseline.md) and treat the version as unverified.

> **Verify checksums before restoring anything.** Compare each downloaded object against the digest
> in the manifest, not just against its own `.sha256` sibling — the manifest is what proves the
> objects belong to the *same run*. A restore that starts on a corrupt or mismatched archive wastes
> the outage window.

### Known pre-existing conditions

These ArgoCD applications were **already unhealthy before any backup work began**. During
validation they must not be mistaken for restore failures:

| Application | Pre-existing state |
|-------------|--------------------|
| `demo-app` | OutOfSync / Missing |
| `nginx-app` | Synced / Degraded |
| `nginx-app-dev` | OutOfSync / Degraded |
| `nginx-app11` | OutOfSync / Degraded |

---

## Step 1 — Provision a fresh Ubuntu 24.04 host

Match the original specification: 8 vCPU, 22 GiB RAM, comparable disk. Confirm architecture is
`x86_64`.

**Verify:** `lsb_release -a`, `uname -m`, `nproc`, `free -h`, `df -h`

---

## Step 2 — Restore node-level OS configuration

Hostname, network (static IP), UFW rules, SSH host keys, timezone / NTP — from the
`node-config/` prefix.

> ✅ **Covered once Phase 1 is live.** The `node-config/` prefix now carries netplan, UFW rules and
> config, `/etc/ssh` (including host keys), `authorized_keys`, timezone/NTP, `dpkg
> --get-selections`, and the interface/route dump. See
> [07 — Phase 0 & 1 Execution](07-phase-0-1-execution.md) and
> [Gaps §3](05-gaps-and-open-questions.md#3-node-level-os-configuration-not-captured).
>
> Until the first `full` run has actually completed, this step is still manual reconstruction.

**Verify:** `hostname` returns `k3-master`; expected IPs present on the interface.

---

## Step 3 — Install K3s, matching version, service not yet started

Pin to the **`k3s_version` value from the manifest you read in step 0** — `v1.34.5+k3s1` at the
time this document was written, but the manifest is authoritative.

> Version drift between backup and restore is the fastest way to turn a routine restore into a
> debugging session. Do not accept the installer's default "latest", and do not trust a version
> number written in markdown over the one recorded by the run that produced your snapshot.

Install, then **stop the service immediately** — the datastore must be restored before K3s ever
writes to it.

**Verify:** `k3s --version` reports `v1.34.5+k3s1`; the service is installed but inactive.

---

## Step 4 — Stop K3s, restore `/var/lib/rancher/k3s/server/`

Restore as **one unit** — this is the correction from
[Backup Strategy §2](02-backup-strategy.md#2-the-correction-that-changes-the-whole-plan):

```text
/var/lib/rancher/k3s/server/
├── db/          state.db, state.db-wal, state.db-shm
├── tls/         cluster CA + serving certificates
├── cred/        node password / IPSec key
├── token        (must land as 0600 root:root)
└── manifests/   static manifests
```

**Verify:** `stat -c '%a %U:%G' /var/lib/rancher/k3s/server/token` → `600 root:root`.

> ⚠️ **The backup format is a single consolidated `state.db`.** The diagram above describes the
> *live* datastore. What Phase 1 uploads to `cluster-state/db/` is one file produced by the SQLite
> online backup API, with the WAL already folded in — there is no `-wal` or `-shm` to restore.
>
> Place it as `/var/lib/rancher/k3s/server/db/state.db` with **no `-wal` and no `-shm` file beside
> it**, while K3s is stopped. K3s creates fresh ones on start. Leaving a stale `-wal` from the old
> machine next to a fresh snapshot is how a restore silently loads the wrong state.
>
> Verify the snapshot before you trust it:
> `python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute('PRAGMA integrity_check').fetchone()[0])" state.db`

> Before overwriting `manifests/`, diff `traefik-helmchartconfig.yaml` — it was hand-modified on
> the original server.

---

## Step 5 — Restore `/etc/rancher/k3s/`

```text
/etc/rancher/k3s/
├── k3s.yaml
└── registries.yaml
/etc/systemd/system/k3s.service     (if customized)
```

If the systemd unit was restored, run `systemctl daemon-reload`.

> `k3s.yaml` embeds the API server address. On a **migration** to a different IP, this must be
> updated for local `kubectl` use.

---

## Step 5a — Only if the new host has a different IP or hostname

Skip this entire step if the replacement machine keeps `45.90.98.51` and the hostname
`k3-master`. If either changes, handle it **before** starting K3s in step 6.

### Hostname

Keep the hostname `k3-master` if you possibly can. The node's identity in the datastore is keyed
on its name — boot with a different hostname and K3s registers a **second** Node object while the
original sits there `NotReady`, with workloads pinned to a node that no longer exists.

```bash
sudo hostnamectl set-hostname k3-master
```

If the name genuinely must change, expect to delete the stale node afterwards:

```bash
kubectl get nodes                      # old name will show NotReady
kubectl delete node <old-node-name>
```

### IP address

The restored `tls/` directory contains the cluster **CA and its private key**, so K3s can and does
mint fresh serving certificates for the new IP on startup. You do **not** need to regenerate the
CA. What you do need to check:

| Item | Action |
|------|--------|
| `/etc/rancher/k3s/k3s.yaml` | Points at `127.0.0.1:6443` by default — fine locally. Any copy used from a workstation needs the `server:` URL changed to the new IP. |
| `--tls-san` flags | If `k3s.service` or a config file pins SANs to the old IP, update them before first start. |
| DNS / ingress records | Repoint anything resolving to `45.90.98.51`. |
| Services with `externalIPs` | `kubectl get svc -A -o wide \| grep 45.90.98.51` — these are hardcoded and will not self-heal. |
| ArgoCD / monitoring URLs | Any ConfigMap or Application referencing the old IP rather than a DNS name. |
| Firewall rules | Restored UFW rules from `node-config/` may reference the old subnet. |

**Verify after step 6:**

```bash
kubectl get nodes -o wide              # exactly one node, Ready, correct IP
kubectl get svc -A -o wide | grep -i 45.90.98.51    # expect no results
sudo journalctl -u k3s | grep -i 'certificate\|x509' | tail
```

> ⚠️ If old kubeconfigs on other machines fail with an x509 error after the move, that is expected
> — the *address* changed, not the CA. Update the `server:` URL in those kubeconfigs. Do **not**
> "fix" it by regenerating certificates; that discards the identity you just restored.

---

## Step 6 — Start K3s, verify node health

**Verify:**
- `systemctl status k3s` → `active (running)`
- `kubectl get nodes` → `k3-master   Ready   control-plane   v1.34.5+k3s1`
- `journalctl -u k3s` shows no certificate or datastore errors

> If the node reports `NotReady` or certificate errors appear, **stop here.** Continuing will
> layer application failures on top of a control-plane problem and make diagnosis much harder.

### Certificate errors: expected vs. genuinely broken

Before treating an x509 error as a failed restore, work out which of these you are looking at
([#19](../../issues/19)). K3s issues leaf certificates with roughly a **one-year** lifetime while
the cluster CA is good for about **ten years**, and it re-issues leaves from that CA on startup
when they are near or past expiry.

| Symptom | Which case | What to do |
|---------|-----------|------------|
| x509 / expiry errors on first start, from a backup roughly a year old or older | **Expected.** The restored CA is still valid and K3s is re-issuing leaf certs. | Let it finish, then restart K3s once and re-check. It self-heals. |
| Errors persist after a clean restart | Real problem | Check `tls/` and `cred/` actually restored — see step 4 |
| `cred/` missing or empty | Real problem | The identity archive is incomplete; use an older backup set |
| Old kubeconfigs on other machines fail after a move | **Expected** — the *address* changed, not the CA | Update the `server:` URL in those kubeconfigs |

> 🚨 **Never regenerate the CA to make a certificate error go away.** It discards the cluster
> identity you just restored, invalidates every existing kubeconfig and node registration, and
> converts a recoverable situation into a rebuild. The same warning applies in
> [step 5a](#step-5a--only-if-the-new-host-has-a-different-ip-or-hostname).

Useful check — reads dates only, never key material:

```bash
for c in /var/lib/rancher/k3s/server/tls/server-ca.crt \
         /var/lib/rancher/k3s/server/tls/client-ca.crt \
         /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt; do
  printf '%s\n  ' "$c"; sudo openssl x509 -enddate -noout -in "$c" 2>/dev/null || echo "absent"
done
```

---

## Step 7 — Confirm the API surface is intact

`kubectl get pods -A` — spot-check namespaces **before touching data**.

Expect to see: `kube-system`, `monitoring`, `argocd`, and the SBE / COW namespaces.

---

## Step 8 — Restore PVC data via Velero

> 🚫 **BLOCKED — not possible today.** Velero is not installed and no Velero backup exists in S3
> ([#11](../../issues/11)). There is **no backup of PVC data of any kind**, so there is nothing to
> restore here. Skip to step 10; the monitoring stack will come back with empty storage.
>
> Prometheus, Loki, Grafana and Alertmanager history from before the incident is **lost**. Nothing
> in this runbook recovers it until #11 is built. The steps below are the intended procedure once
> it is.

**Not a raw file copy** — see [Backup Strategy §6](02-backup-strategy.md#6-the-persistent-volume-gotcha).

1. Install Velero pointed at the same S3 bucket
2. Let PVCs bind first (`WaitForFirstConsumer` means a consumer pod must be scheduled)
3. Let the node-agent populate the volumes

**Verify:** all six monitoring PVCs `Bound`; `du -sh` under `/var/lib/rancher/k3s/storage/`
roughly matches the ~7.8 GB baseline.

*Steps 8 and 10 are independent and can run in parallel.*

---

## Step 9 — Reinstall ArgoCD, then `argocd admin import`

> 🚫 **BLOCKED as written — no export exists.** No scheduled `argocd admin export` runs today
> ([#1](../../issues/1)), so there is no file to import.
>
> **What happens instead on a same-node restore:** ArgoCD's state lives in the datastore you
> restored in step 4, so it should come back on its own — no reinstall, no import. Verify it
> rather than rebuilding it.
>
> **On a genuinely fresh cluster** this step has no source to restore from, which is part of why
> [#20](../../issues/20) is open.

Once the export exists, importing restores Applications, Projects, repository credentials and
SSO / RBAC configuration, after which ArgoCD reconnects to Git and reconciles on its own.

**Verify:** all seven ArgoCD core pods `Running`; `argocd repo list` shows the expected remotes as
connected.

---

## Step 10 — Let GitOps redeploy SBE / COW

These workloads carry **no PVC dependency** — they come back purely from Git + ArgoCD sync.

**Verify:** `argocd app list` — SBE and COW applications reach `Synced` / `Healthy`.

---

## Step 11 — Validate

| Check | Expected | Valid today? |
|-------|----------|--------------|
| `argocd app list` | All **primary** apps Synced/Healthy (see pre-existing conditions above) | ✅ |
| Ingress | Reachable; Traefik routing correctly | ✅ |
| Certificates | Valid; no TLS warnings on ingress endpoints | ✅ |
| `kubectl get pv,pvc -A` | All six Bound | ✅ — bound, but **empty** until [#11](../../issues/11) |
| Grafana | Loads, datasources connected | ⚠️ Dashboards return only if stored as ConfigMaps; anything in its PVC is gone |
| Prometheus | Querying | ⚠️ **Historical data will be absent.** Expected today — not a restore failure |
| Loki | Service healthy | ⚠️ Log queries return nothing from before the incident |
| Alertmanager | Running, routes configured | ⚠️ Silences and notification state lost |

> The ⚠️ rows become ✅ only when [#11](../../issues/11) is built. Until then, an empty Prometheus
> after a restore is the **expected** outcome — do not spend outage time debugging it.

---

## Step 12 — Cut over

DNS / traffic to the new host, if this is a migration or DR rather than a same-box recovery.

**Post-cutover:**
- Re-point the backup jobs at the new host and confirm the next scheduled run succeeds
- **Rotate the S3 credentials** if the original server was compromised or is unaccounted for
- Record the actual end-to-end RTO in the drill log

---

## Scenario shortcuts

Not every incident needs all twelve steps.

| Incident | Steps needed | Possible today? |
|----------|--------------|-----------------|
| Datastore corruption, host intact | Steps 4 → 7 | ✅ |
| Certificate loss, host intact | Steps 4 (`tls/`, `cred/`) → 6 | ✅ |
| Bad application deployment | Git revert + ArgoCD rollback (step 10 territory) | ✅ — Git is the source of truth |
| Migration / DR to a new box | Steps 0 → 12 | ⚠️ Partial — node rebuilds, **PVC data does not** |
| Accidental resource deletion | Velero object-level restore only — no node work | 🚫 [#11](../../issues/11). Only fallback is rolling the whole datastore back to an earlier snapshot, which reverts *everything* |
| Single PVC data loss | Step 8, scoped to the affected PVC | 🚫 [#11](../../issues/11) — **unrecoverable today** |
| ArgoCD wiped | Step 9 | ⚠️ Recovers via the datastore on the same node; no source on a fresh cluster |
| **Full loss** | **Steps 0 → 12** | ⚠️ Partial — see the capability table at the top |

> The 🚫 rows are the sharpest argument for prioritising [#11](../../issues/11): accidental
> deletion of a single Secret or Deployment is a far more common incident than total host loss, and
> it is the one this runbook currently handles worst.
