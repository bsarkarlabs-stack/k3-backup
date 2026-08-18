# 03 — Restore Runbook

**Fresh Ubuntu server → validated production.**

This is the one document where **step order carries real information**. Do not reorder.

> ⚠️ **This runbook has never been executed.** Until [Phase 5](04-implementation-todo.md#phase-5--restore-validation)
> is complete, treat every step below as untested. Timings and failure modes are unknown.

---

## Before you start

| Prerequisite | Detail |
|--------------|--------|
| Read credential | S3 read-only credential, held **offline** — not the one on the failed server |
| Target spec | 8 vCPU, 22 GiB RAM, ≥97 GB disk, `x86_64` |
| Target OS | Ubuntu 24.04 LTS |
| K3s version | **`v1.34.5+k3s1`** — pinned, exact |
| Backup set | Identify the latest *consistent* set across all prefixes and note the timestamp |

> **Verify checksums before restoring anything.** Every archive has a stored SHA-256. A restore
> that starts on a corrupt archive wastes the outage window.

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

Pin to **`v1.34.5+k3s1`** exactly.

> Version drift between backup and restore is the fastest way to turn a routine restore into a
> debugging session. Do not accept the installer's default "latest".

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

---

## Step 7 — Confirm the API surface is intact

`kubectl get pods -A` — spot-check namespaces **before touching data**.

Expect to see: `kube-system`, `monitoring`, `argocd`, and the SBE / COW namespaces.

---

## Step 8 — Restore PVC data via Velero

**Not a raw file copy** — see [Backup Strategy §6](02-backup-strategy.md#6-the-persistent-volume-gotcha).

1. Install Velero pointed at the same S3 bucket
2. Let PVCs bind first (`WaitForFirstConsumer` means a consumer pod must be scheduled)
3. Let the node-agent populate the volumes

**Verify:** all six monitoring PVCs `Bound`; `du -sh` under `/var/lib/rancher/k3s/storage/`
roughly matches the ~7.8 GB baseline.

*Steps 8 and 10 are independent and can run in parallel.*

---

## Step 9 — Reinstall ArgoCD, then `argocd admin import`

Restores Applications, Projects, repository credentials, SSO / RBAC configuration. ArgoCD then
reconnects to Git and begins reconciling on its own.

**Verify:** all seven ArgoCD core pods `Running`; `argocd repo list` shows the expected remotes as
connected.

---

## Step 10 — Let GitOps redeploy SBE / COW

These workloads carry **no PVC dependency** — they come back purely from Git + ArgoCD sync.

**Verify:** `argocd app list` — SBE and COW applications reach `Synced` / `Healthy`.

---

## Step 11 — Validate

| Check | Expected |
|-------|----------|
| `argocd app list` | All **primary** apps Synced/Healthy (see pre-existing conditions above) |
| Ingress | Reachable; Traefik routing correctly |
| Grafana | Loads, dashboards present, datasources connected |
| Prometheus | Querying; **historical data present** — confirms step 8 worked |
| Loki | Log queries return results |
| Alertmanager | Running, routes configured |
| Certificates | Valid; no TLS warnings on ingress endpoints |
| `kubectl get pv,pvc -A` | All six Bound |

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

| Incident | Steps needed |
|----------|--------------|
| Accidental resource deletion | Velero object-level restore only — no node work |
| Bad application deployment | Git revert + ArgoCD rollback (step 10 territory) |
| Single PVC data loss | Step 8, scoped to the affected PVC |
| Datastore corruption, host intact | Steps 4 → 7 |
| Certificate loss, host intact | Steps 4 (`tls/`, `cred/`) → 6 |
| ArgoCD wiped | Step 9 |
| **Full loss / migration / DR** | **All twelve** |
