# 03 — Restore Runbook

Four flows. You almost always want the second one.

| Flow | When | Time | Section |
|------|------|------|---------|
| **Full server rebuild** | The server is gone, corrupted, or moving to a new machine | ~2 hours (estimated — never timed for real) | [§A](#a--full-server-rebuild) |
| **One PVC or one object** | Someone deleted the wrong thing, or one volume's data is bad | ~10 minutes | [§B](#b--restoring-one-pvc-or-one-object) |
| **The restore test** | On a schedule, on a throwaway VM, so the others are known to work | ~2–3 hours | [§C](#c--the-restore-test) |
| **Rebuild from Velero alone** | Every usable datastore backup is suspect, so cluster identity has to be given up | ~1 hour | [§D](#d--rebuilding-from-velero-alone-into-a-fresh-cluster) |

> ### The one rule that governs every flow here
>
> **Velero restores volume data only when it creates the pod.** Restoring a PVC on its own — or into
> a namespace whose workloads are already running — gives you a correctly-named, **empty** volume and
> a restore marked `Completed`. Every flow below is shaped around that fact.

> ⚠️ **None of this has been run end to end yet.** Until it has, treat every step as unproven and
> every duration as a guess. §C is how that changes, and it is part of the design rather than
> optional homework — see [02 §10](02-backup-strategy.md#10-the-restore-test-is-part-of-the-design-not-homework).

---

## Before you start

| You need | Details |
|----------|---------|
| An AWS login that can read the bucket | Your normal admin or SSO login. There is deliberately no separate stored restore key — [02 §3](02-backup-strategy.md#two-workload-credentials-separated-by-failure-domain) |
| The bucket name and region | `k3-master-dr`, `ap-south-1` — written down outside AWS as well |
| A replacement server | 8 cores, 22 GB RAM, ≥97 GB disk, x86_64, Ubuntu 24.04 LTS |
| The K3s version | **Don't guess — read it out of `MANIFEST.json`.** It was `v1.34.5+k3s1` when this was written |
| This repository | Clone it before the outage procedure needs `scripts/velero/` or copy the pinned scripts into the recovery kit |
| Recovery tools | AWS CLI v2, `python3`, `tar`, `sha256sum`, `kubectl`, the Velero CLI version pinned by `install-velero.sh`, and a working kubeconfig |
| ArgoCD access | `argocd` CLI plus admin access, or use the documented `kubectl` checks instead |

### Things that were already broken before any of this started

Don't mistake these for restore failures: `demo-app` (not synced), `nginx-app` (synced, unhealthy),
`nginx-app-dev`, `nginx-app11`.

---

## A — Full server rebuild

### Step 1 — Pick a backup and read its manifest

Each successful run has a unique UTC prefix. `COMPLETE.json` is uploaded last; ignore every prefix
without it, because it may be a partial upload.

```bash
export BUCKET=k3-master-dr AWS_DEFAULT_REGION=ap-south-1

# List only committed restore sets and choose the newest one.
aws s3api list-objects-v2 --bucket "$BUCKET" --prefix k3s/daily/ \
  --query "Contents[?ends_with(Key, 'COMPLETE.json')].Key" --output text

RUN_ID=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix k3s/daily/ \
  --query "Contents[?ends_with(Key, 'COMPLETE.json')].Key" --output text |
  tr '\t' '\n' | awk -F/ '{print $3}' | sort | tail -1)
[ -n "$RUN_ID" ] || { echo "no complete daily restore set found" >&2; exit 1; }
PREFIX="k3s/daily/$RUN_ID"
mkdir -p ~/k3-restore && cd ~/k3-restore

# read the manifest first — it's 2 KB, and it tells you what to install
aws s3 cp "s3://$BUCKET/$PREFIX/COMPLETE.json" .
aws s3 cp "s3://$BUCKET/$PREFIX/MANIFEST.json" .
python3 - <<'PY'
import hashlib, json
expected = json.load(open("COMPLETE.json"))["manifest_sha256"]
actual = hashlib.sha256(open("MANIFEST.json", "rb").read()).hexdigest()
assert actual == expected, f"manifest checksum mismatch: {actual} != {expected}"
PY
python3 -m json.tool MANIFEST.json
```

Read out of it:

- **`k3s_version`** — the exact version to install in step 3. Use this, **not** the version written
  in this document. Docs go stale the moment K3s is upgraded; the manifest is written by the backup
  itself.
- **`k3s_start_command`** — the flags this server actually ran with, including any `--tls-san`.
- **`os_release`** and **`arch`** — what the replacement host has to be.
- **`archive.sha256`** — verify against this after downloading.

Then take the archive and verify it **through the manifest**, not through the sidecar `.sha256`
file. The sidecar is a convenience copy that nothing else vouches for; `MANIFEST.json` is the copy
whose own checksum you just confirmed against `COMPLETE.json`. Verifying against the manifest keeps
one unbroken chain: last-written marker → manifest → archive.

```bash
aws s3 cp "s3://$BUCKET/$PREFIX/" . --recursive

python3 - <<'PY'
import hashlib, json
m = json.load(open("MANIFEST.json"))["archive"]
digest = hashlib.sha256()
with open(m["filename"], "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        digest.update(chunk)
actual = digest.hexdigest()
assert actual == m["sha256"], f"archive checksum mismatch: {actual} != {m['sha256']}"
print(f"{m['filename']} verified against MANIFEST.json")
PY
```

**Verify before you use anything.** Restoring from a truncated download during an outage costs more
time than this check does. If the digests differ, pick the previous committed `RUN_ID` rather than
extracting anyway.

```bash
ARCHIVE=$(python3 -c 'import json;print(json.load(open("MANIFEST.json"))["archive"]["filename"])')
tar -xzf "$ARCHIVE"
ls -la          # MANIFEST.json  state.db  fs-root/  host-facts/
```

### Step 2 — Prepare the host

Ubuntu 24.04, matching specs, **hostname `k3-master`**.

```bash
sudo hostnamectl set-hostname k3-master
cat host-facts/README.txt          # addresses, the k3s start command, OS
ls host-facts/                     # ip-addr, ip-route, ufw-status, netplan/, dpkg-selections…
```

`host-facts/` is **reference material, not config to extract.** Read it and apply what applies —
the addressing from `ip-addr.txt` and `netplan/`, the firewall rules from `ufw-status.txt`, the
packages you actually need from `dpkg-selections.txt`. Deliberately not in there: `/etc/ssh` and
`authorized_keys`. Put your own SSH key on the new host the normal way; restoring the dead host's
SSH identity is not something you want ([02 §4](02-backup-strategy.md#the-host-fact-sheet-is-facts-not-config)).

> **Keep the hostname.** K3s identifies the node by name inside the datastore. Boot with a
> different name and K3s registers a *second* node, while the original sits `NotReady` still
> holding every workload. If the name genuinely must change, expect to
> `kubectl delete node <old-name>` afterwards.

### Step 3 — Install the exact K3s version, without starting it

```bash
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_VERSION="v1.34.5+k3s1" \
  INSTALL_K3S_SKIP_START=true sh -        # ← version from MANIFEST.json
```

`INSTALL_K3S_SKIP_START=true` is the whole point of this step. It writes the binary and the systemd
units and **never starts the service**, so K3s cannot generate a throwaway CA, a throwaway token and
a live WAL in the datastore directory you are about to overwrite. Starting it and stopping it a
second later mostly works — but "mostly" is not a property you want in the step immediately before
restoring cluster identity.

**Check:**

```bash
k3s --version                                # matches MANIFEST.json
systemctl is-active k3s || echo "not running — correct"
ls /var/lib/rancher/k3s/server/db/ 2>/dev/null || echo "no datastore yet — correct"
```

> Installing a different version than the one that made the backup is the fastest way to turn a
> simple restore into a debugging session. Pin it. Trust the manifest over this document.
>
> If you inherit a host where K3s is already running, stop it and clear the datastore directory
> before step 4: `sudo systemctl stop k3s && sudo rm -f /var/lib/rancher/k3s/server/db/state.db*`

**If `get.k3s.io` no longer serves that version** — the reason
[02 §8](02-backup-strategy.md#8-future-proofing-a-restore) exists — the binary is in the bucket:

```bash
VER=$(python3 -c 'import json;print(json.load(open("MANIFEST.json"))["k3s_version"])')
aws s3 cp "s3://$BUCKET/k3s-release/$VER/k3s" ./k3s

# Verify against the manifest you already authenticated, not against the
# sidecar next to the binary: the manifest records the digest of the binary
# that actually produced this backup.
python3 - <<'PY'
import hashlib, json
expected = json.load(open("MANIFEST.json"))["k3s_binary_sha256"].split()[0]
if expected == "unknown":
    raise SystemExit("this manifest predates binary checksums - fall back to k3s.sha256 and "
                     "confirm `k3s --version` matches the manifest before proceeding")
digest = hashlib.sha256()
with open("k3s", "rb") as fh:
    for chunk in iter(lambda: fh.read(1 << 20), b""):
        digest.update(chunk)
actual = digest.hexdigest()
assert actual == expected, f"k3s binary mismatch: {actual} != {expected}"
print("vaulted k3s binary verified against MANIFEST.json")
PY

sudo install -m 0755 -o root -g root ./k3s /usr/local/bin/k3s
for c in kubectl crictl ctr; do sudo ln -sf /usr/local/bin/k3s /usr/local/bin/$c; done
k3s --version        # must print $VER
```

If the digests differ, stop. Either the vaulted object was overwritten or it belongs to a different
build; use S3 version history to retrieve the version whose digest matches the manifest. Never
install an unverified release artifact during recovery. The `k3s.sha256` object sitting beside the
binary is a convenience for anyone reading the bucket without a manifest in hand — it is not the
authority, because whoever could overwrite the binary could overwrite that file too.

The systemd unit comes from the archive in step 4, which is the only other thing `install.sh` would
have given you. Skip straight to step 4 and run `daemon-reload` there.

### Step 4 — Restore the identity and the datastore

With K3s stopped:

```bash
# identity + config, all of it, in place. Preserves modes and ownership.
sudo cp -a fs-root/. /

# the datastore
sudo install -m 0600 -o root -g root state.db /var/lib/rancher/k3s/server/db/state.db

# CRITICAL: remove the WAL files the fresh install left behind
sudo rm -f /var/lib/rancher/k3s/server/db/state.db-wal \
           /var/lib/rancher/k3s/server/db/state.db-shm

sudo systemctl daemon-reload
sudo systemctl enable k3s
```

`fs-root/` carries `server/tls/`, `server/cred/`, `server/token`, `server/manifests/`,
`/etc/rancher/k3s/` and the K3s systemd unit, laid out exactly as they were on the old host.

**Why deleting the WAL files matters:** `state.db` came from SQLite's online backup API, so the
write-ahead log is already folded into it. A leftover `-wal` from the fresh install describes a
*different* database. Leaving it there is how you corrupt a restore that was about to work.

**Check:**

```bash
stat -c '%a %U:%G' /var/lib/rancher/k3s/server/token     # expect: 600 root:root
ls /var/lib/rancher/k3s/server/db/                       # expect: state.db and nothing else
ls /var/lib/rancher/k3s/server/cred/                     # encryption-config.json must be here if it was there before
```

If `k3s secrets-encrypt` was enabled on the old server, `cred/encryption-config.json` is
**mandatory** — without it every Secret in the restored database is unreadable ciphertext.

### Step 5 — Only if the new host has a different IP

Skip this entirely if the replacement keeps `45.90.98.51`. If the address changed, deal with it
**now**, before the first start.

The restored `tls/` contains certificates issued for the old endpoint. Changing `--tls-san` does
**not** prove that the restored API-serving certificate was reissued for the new address. Update
the configured SAN before startup, then inspect the actual certificate after startup:

| Check | Do |
|-------|----|
| `--tls-san` in `k3s.service` | If it lists the **old** IP, fix it before the first start, or K3s issues certs that don't match. `MANIFEST.json` has the original start command |
| `/etc/rancher/k3s/k3s.yaml` | Fine as `127.0.0.1` on the server. Any laptop copy needs its `server:` address updated |
| DNS records | Repoint anything resolving to the old address |
| Hardcoded IPs in services | `kubectl get svc -A -o wide \| grep 45.90.98.51` — these will **not** fix themselves |
| Firewall rules from `host-facts/` | May still reference the old network |

After step 6, verify the SAN rather than assuming it:

```bash
echo | openssl s_client -connect <new-ip>:6443 2>/dev/null |
  openssl x509 -noout -ext subjectAltName
```

If the new address is absent, follow the K3s certificate-rotation procedure for the API server,
then restart K3s and verify the SAN again. Never rotate the cluster CA.

### Step 6 — Start K3s and verify the control plane

```bash
sudo systemctl start k3s
kubectl get nodes                    # expect: k3-master  Ready  control-plane  <manifest version>
journalctl -u k3s -n 100 --no-pager
```

**Stop here if the node is `NotReady`.** Debugging apps on top of a broken control plane makes
everything harder.

#### Certificate errors: the normal kind vs. the real problem

K3s uses two tiers. The **cluster CA is valid ~10 years**; every certificate it issues is valid
**~1 year**. On startup K3s quietly reissues expired leaf certs from the CA.

| What you see | Which kind | Do |
|---|---|---|
| Certificate/expiry errors on first start from a backup ~a year old | **Normal** — the CA is fine and K3s is reissuing | Let it finish, restart K3s once, re-check. It fixes itself |
| Errors persist after a clean restart | **Real** | Back to step 4 — confirm `tls/` and `cred/` actually copied |
| `cred/` missing or empty | **Real** | The archive is incomplete. Use an older backup |
| Old laptop kubeconfigs failing after a move | **Normal** — the *address* changed, not the CA | Update `server:` in those files |

> 🚨 **Never regenerate the cluster CA to make an error go away.** It discards the identity you just
> restored, breaks every existing kubeconfig, and turns a recoverable situation into a full rebuild.

Read-only expiry check (never touches key material):

```bash
for c in server-ca.crt client-ca.crt serving-kube-apiserver.crt; do
  printf '%s\n  ' "$c"
  sudo openssl x509 -enddate -noout -in "/var/lib/rancher/k3s/server/tls/$c" 2>/dev/null || echo "not found"
done
```

### Step 7 — Sanity check before touching data

```bash
kubectl get pods -A
```

Expect `kube-system`, `monitoring`, `argocd`, and the SBE/COW namespaces. Workloads are already
here — they came back with the datastore. Their **volumes are empty**; step 9 fills them.

### Step 8 — Install Velero against the same bucket, read-only

```bash
cat > ./velero-credentials <<'EOF'
[default]
aws_access_key_id=<temporary recovery credentials or the dedicated Velero key>
aws_secret_access_key=<…>
EOF
chmod 600 ./velero-credentials

export S3_BUCKET=k3-master-dr AWS_REGION=ap-south-1 CREDS_FILE=./velero-credentials
export KUBELET_ROOT_DIR=/var/lib/kubelet   # use the path verified on this node
./scripts/velero/install-velero.sh

# make the backup location read-only until you have verified the restore
kubectl -n velero patch backupstoragelocation default \
  --type merge -p '{"spec":{"accessMode":"ReadOnly"}}'

shred -u ./velero-credentials
```

Do **not** apply the Schedule objects yet, and leave the location `ReadOnly`. A half-restored
cluster that starts writing backups can overwrite your idea of which backup is good — while you
still might need to start over from it. Step 12 switches both on, deliberately, once verified.

### Step 9 — Restore PVC data

This is the only step that brings monitoring history back, and it is the step most likely to
silently do nothing. Read the box before running anything.

> ### 🚨 Volume data comes back only when Velero **creates the pod**
>
> Velero's file-system backup does not copy data into an existing volume. When it restores a **Pod**
> it injects a `restore-wait` init container and creates a `PodVolumeRestore`; the node-agent then
> fills the volume before the app container starts.
>
> After step 4 the datastore is restored, so **every Deployment and Pod already exists and is
> running**. Velero skips objects that already exist — and `--existing-resource-policy=update`
> patches them without re-creating a running pod. The restore would report `Completed` and copy
> **no data at all**.
>
> So the workloads that own volumes have to go first. That is what makes room for Velero to
> re-create them properly.

Only the `monitoring` namespace currently has PVCs ([01 §11](01-discovery-baseline.md)). Suspend
ArgoCD first; otherwise it can recreate monitoring workloads before Velero injects the restore
helper and the restore can finish with empty data.

```bash
velero backup get     # record candidate creation/completion timestamps

# Job 1 and Velero are not one transaction. Conservative default: choose the
# newest scheduled Velero backup created no later than MANIFEST.run_timestamp.
# Record RUN_ID, backup name and both timestamps in the incident log.

# 1. stop GitOps reconciliation for the restore window
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
kubectl -n argocd rollout status statefulset argocd-application-controller --timeout=5m

# 2. clear the namespace that owns the volumes. With local-path, deleting the
#    PVCs deletes the (currently empty) directories too — that is intended.
kubectl delete namespace monitoring
kubectl wait --for=delete namespace/monitoring --timeout=10m

# 3. let Velero rebuild it: PVCs, workloads AND pods, so the node-agent runs
velero restore create restore-monitoring-$(date +%s) \
  --from-backup <backup-name> \
  --include-namespaces monitoring \
  --wait

velero restore describe <restore-name> --details
```

Expect this to take a while for the ~5.5 GB Prometheus volume. In `restore describe --details` you
must see a **Pod Volume Restores** section listing six volumes. If that section is empty, no data
moved — see the box above, and [gap 6](05-gaps-and-open-questions.md#6-whether-veleros-node-agent-can-actually-read-our-volumes).

**Check — volume size, not volume existence:**

```bash
kubectl -n monitoring get pvc                      # all six Bound
sudo du -sh /var/lib/rancher/k3s/storage/          # roughly the original ~7.8 GB, not near zero

# Resume reconciliation only after old Prometheus/Loki data has been verified.
kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
```

> **If anything outside `monitoring` ever gains a PVC**, add its namespace to the same treatment
> here. `kubectl get pvc -A` at the top of a restore tells you what the current answer is — don't
> trust this document's list.

### Step 10 — Let ArgoCD reconcile

SBE and COW have no PVCs — they come back purely from Git.

```bash
argocd app list        # our real apps should reach Synced / Healthy
argocd repo list       # Git repos connected
```

ArgoCD's own settings came back inside the restored datastore (and inside the Velero backup). There
is no separate export to import.

### Step 11 — Verify properly

| Check | Expect |
|-------|--------|
| `argocd app list` | Real apps Synced/Healthy (ignore the four already-broken ones) |
| Ingress / websites | Reachable, routing correctly |
| HTTPS | Valid certificates, no browser warnings — **watch this one**, see [gap 4](05-gaps-and-open-questions.md#4-where-traefiks-https-certificates-come-from) |
| `kubectl get pv,pvc -A` | All six Bound |
| Prometheus | A query over a **pre-incident** time range returns data. This is the real proof the volume restore worked — not that the pod started |
| Loki | A search over an old window returns lines |
| Grafana | Loads, dashboards present, data sources connected |
| Alertmanager | Running with its routes configured (silences and alert history are gone — expected) |

### Step 12 — Cut over

Only once step 11 has actually passed, give the rebuilt server back its ability to write backups:

```bash
# replace the Secret with the dedicated Velero credential, then:
kubectl -n velero patch backupstoragelocation default \
  --type merge -p '{"spec":{"accessMode":"ReadWrite"}}'

kubectl apply -f scripts/velero/schedule-daily.yaml
kubectl apply -f scripts/velero/schedule-weekly.yaml

# Job 1 and the Velero verifier are not in the archive — reinstall them from
# this repo before trusting the rebuilt host to back itself up. Follow
# [07 steps 3.1–3.2 and 5.2–5.3](07-setup.md#31--write-the-config-node): write
# backup.env, copy the script and units, set HEARTBEAT_URL, install the
# verifier. Then:
sudo systemctl enable --now k3s-backup.timer
sudo systemctl enable --now velero-backup-check.timer
```

Then:

- Repoint DNS at the new server.
- Confirm `HEARTBEAT_URL` is in `/etc/k3s-backup/backup.env` on the new host, and that the next run
  logs `heartbeat sent`. A restored server whose backups are silently broken is worse than no
  restore.
- Confirm the **next scheduled run of both jobs** actually lands in S3.
- **Rotate both workload credentials** if the old server is compromised or unaccounted for.
- **Write down how long this took.** That number is our real RTO — everything before this point is
  an estimate.

---

## B — Restoring one PVC or one object

The common case. Never touches the server, never touches SQLite, takes minutes.

This matters more than the full rebuild: someone deleting a Secret or a PVC by accident is far more
likely than losing the whole machine — and because `local-path` uses a `Delete` reclaim policy,
deleting a PVC destroys its files instantly.

### One deleted object

```bash
velero backup get

# Never guess a selector from a Helm chart name.
kubectl get secret -n monitoring --show-labels

velero restore create restore-$(date +%s) \
  --from-backup <backup-name> \
  --include-namespaces monitoring \
  --include-resources secrets \
  --selector app=grafana
```

Velero **skips objects that already exist**, so a narrow restore is additive by default. Use
`--existing-resource-policy=update` only when you deliberately want to overwrite something live.

Works the same for `deployments`, `configmaps`, `ingresses`, `roles`, `rolebindings`, CRD instances
— anything in the backup.

### One PVC's data

> **Same rule as §A step 9: the data arrives with a pod Velero creates.** Scaling a Deployment to
> zero is insufficient: the owner still exists, Velero skips it, and Velero documents that FSB
> restore does not work while the owner remains scaled to zero. Delete the owner and claim only
> after confirming the selected backup contains a completed PodVolumeBackup.

```bash
# 1. prove the source backup contains this pod volume before deleting anything
velero backup describe <backup-name> --details
kubectl -n velero get podvolumebackups \
  -l velero.io/backup-name=<backup-name> -o wide

# 2. stop GitOps and preserve the current data if this is corruption rather
#    than an already-lost PVC
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
kubectl -n monitoring scale deploy/grafana --replicas=0
# Optional emergency copy before deletion:
# sudo tar -C <current-local-path-directory> -czf /root/grafana-before-restore.tgz .

# 3. delete both the owner and claim. Deleting only the claim, or leaving the
#    Deployment scaled to zero, can produce a Completed restore with no data.
kubectl -n monitoring delete deploy grafana
kubectl -n monitoring wait --for=delete pod \
  -l app.kubernetes.io/name=grafana --timeout=5m
kubectl -n monitoring delete pvc grafana

# 4. restore the app: claim, workload and pod together. No --include-resources:
#    narrowing it to the claim is exactly what silently restores no data.
velero restore create pvc-restore-$(date +%s) \
  --from-backup <backup-name> \
  --include-namespaces monitoring \
  --selector app.kubernetes.io/name=grafana \
  --wait

velero restore describe <restore-name> --details   # expect a Pod Volume Restores section
```

Velero re-creates the Deployment and the pod; the injected init container blocks until the
node-agent has written the files, then the app starts on a full volume. If the workload comes back
scaled to zero (because that is how it was captured), scale it up afterwards.

**Confirm the label selector actually matches the pod**, not just the claim — that is what decides
whether the data comes back:

```bash
kubectl -n monitoring get pod,pvc -l app.kubernetes.io/name=grafana
kubectl -n argocd scale statefulset argocd-application-controller --replicas=1
```

**Verify inside the pod, not from the outside** — query Prometheus for a timestamp from before the
incident, or search Loki over an old window. A `Bound` PVC proves nothing about its contents.

### A bad deploy

Not a backup problem. Revert the commit and let ArgoCD roll it back — Git is the source of truth for
SBE and COW, and it's faster and safer than any restore.

---

## C — The restore test

**Run this once now, then every 3–6 months, and after any K3s upgrade or change to the backup
design.** It is the only thing that turns this document from a plan into a fact.

Downloading the artifacts and inspecting them — which is what
[07 stage 3.7](07-setup.md#37--verify-the-archive-off-the-server-local) does — is useful validation
but is **not** this. This needs a machine that boots.

### What to do

1. **Fresh Ubuntu 24.04 VM**, matching `k3-master`'s specs, on a throwaway address. Never the
   production host.
2. **Prove the archive is readable**, before trusting anything downstream of it. This is the check
   [07 stage 3.7](07-setup.md#37--verify-the-archive-off-the-server-local) does once at setup; doing
   it here is what makes it recur:

   ```bash
   # PREFIX and ARCHIVE come from §A step 1 (newest COMPLETE.json, then the
   # filename recorded in MANIFEST.json).
   aws s3 cp "s3://$BUCKET/$PREFIX/" . --recursive
   # verify the COMPLETE.json -> MANIFEST.json -> archive chain, as in §A step 1
   ARCHIVE=$(python3 -c 'import json;print(json.load(open("MANIFEST.json"))["archive"]["filename"])')
   tar -tzf "$ARCHIVE" | head        # MANIFEST.json state.db fs-root/ host-facts/
   ```

3. Work through **§A steps 1–11** exactly as written, from the current daily backup.
4. Deliberately exercise the awkward parts, because they're the ones that bite in an outage:
   - Install K3s from `k3s-release/` in the bucket, not from `get.k3s.io`. That proves step 3's
     fallback works while you have time to fix it.
   - Restore onto a host with a **different IP**, so step 5 gets exercised at least once.
5. Run §B's **one-object** restore once. The destructive PVC path is already exercised by §A
   step 9; do not repeat it against production-shaped data merely to satisfy a checklist.
6. **Once a year, or after any Velero upgrade, run §D instead of §A.** It is the flow you would
   reach for when the datastore is the thing that's broken, and it is the only one that proves
   Velero can rebuild the cluster without help from Job 1.

### What counts as a pass

| Must be true | Not "the pod started" |
|--------------|-----------------------|
| `kubectl get nodes` shows the node `Ready` at the manifest's K3s version | — |
| Every namespace, CRD and Secret from the old cluster is present | Count them, don't eyeball |
| `velero restore describe --details` lists **six Pod Volume Restores** | An empty section means no data moved, whatever the restore status says |
| All six PVCs `Bound` and `du -sh` on the storage path is roughly 7.8 GB | Volume size, not volume existence |
| **Prometheus answers a query over a pre-incident time range** | This is the real proof the volume restore worked |
| Loki returns lines from an old window | Same reasoning |
| Ingress routes resolve and **HTTPS presents a valid certificate** | This is where the Traefik certificate gap bites, if it bites |
| ArgoCD reaches Synced/Healthy on the real apps | Ignore the four already-broken demos |

### What to record afterwards

- **How long each phase took.** Total wall-clock time is the real RTO — replace the estimate in this
  document's header table and settle [02 §1](02-backup-strategy.md#1-two-numbers-to-agree-on-first--still-open).
- **Everything that didn't match this runbook**, and fix the runbook to match reality rather than
  intent.
- Whether each monitoring volume came back usable. Velero FSB reads a live filesystem over time;
  it is **not a point-in-time or crash-consistent snapshot**. Monitoring history is best-effort
  unless an application-native backup or tested quiesce hook is added for that component.
- The date, and the next due date.

Then tear the VM down.

---

## D — Rebuilding from Velero alone, into a fresh cluster

**Use this when every usable datastore backup is suspect.** Do not use it as a shortcut for a K3s
upgrade. Restore onto the source K3s version first; upgrade only after recovery has passed.

What you give up: the cluster's identity. A fresh cluster means a **new CA, new token, new node
identity**, so every existing kubeconfig and anything that trusted the old CA must be re-issued.
That is the trade — a clean cluster with your data, instead of the same cluster with its history.

```bash
# 1. download and verify a COMPLETE Job 1 set as in §A step 1. It provides
#    MANIFEST.json and fs-root/, even though this flow does not restore state.db.

# 2. fresh host, fresh identity, source-compatible K3s version
VER=$(python3 -c 'import json;print(json.load(open("MANIFEST.json"))["k3s_version"])')
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$VER" sh -

# 3. restore only the identity-free config you still want, from the archive:
#    registries.yaml (private registry credentials) and the hand-edited
#    traefik-helmchartconfig.yaml. NOT tls/, cred/ or token.
sudo cp -a fs-root/etc/rancher/k3s/registries.yaml /etc/rancher/k3s/
sudo cp -a fs-root/var/lib/rancher/k3s/server/manifests/traefik-helmchartconfig.yaml \
           /var/lib/rancher/k3s/server/manifests/
sudo systemctl restart k3s

# 4. install the pinned Velero version with the verified kubelet root and keep
#    the BackupStorageLocation ReadOnly
export KUBELET_ROOT_DIR=/var/lib/kubelet
./scripts/velero/install-velero.sh
kubectl -n velero patch backupstoragelocation default \
  --type merge -p '{"spec":{"accessMode":"ReadOnly"}}'

# 5. restore in phases. Do not restore kube-system, velero, node objects,
#    StorageClasses or old PV objects over the new cluster's built-ins.
velero restore create rebuild-foundation-$(date +%s) \
  --from-backup <backup-name> \
  --include-resources customresourcedefinitions.apiextensions.k8s.io \
  --wait

velero restore create rebuild-workloads-$(date +%s) \
  --from-backup <backup-name> \
  --exclude-namespaces kube-system,kube-public,kube-node-lease,velero \
  --exclude-resources nodes,persistentvolumes,storageclasses.storage.k8s.io \
  --wait
```

Review each restore's warnings before continuing. API-version conversion is not guaranteed across
large Kubernetes jumps; this is why the source version is restored first.

Then re-issue kubeconfigs, re-point ArgoCD at Git, and work through §A step 11's checks. Resume
backup writes and apply schedules only after validation. Expect to redo anything that depended on
the old cluster CA.

> A clean-cluster rebuild is a migration, not a blind replay. Cluster-scoped resources and
> Kubernetes built-ins are restored selectively to avoid replacing the new cluster's own control
> plane objects.

## Which flow for which incident

| What happened | Do |
|---|---|
| Someone deleted a Kubernetes object | §B, one object |
| One volume's data is lost or corrupt | §B, one PVC |
| A bad deployment went out | Revert in Git, roll back in ArgoCD |
| The datastore is corrupted **and you have a good older one** | §A steps 4–7 only |
| The datastore is corrupted **and every backup of it is suspect** | §D — rebuild from Velero, accept a new cluster identity |
| Certificates lost, host is fine | §A step 4 (`fs-root/` only) → step 6 |
| ArgoCD is wiped | §B scoped to the `argocd` namespace |
| Complete server loss, or moving machines | §A, all 12 steps |
| Moving to a different K3s version deliberately | Not a restore. §A restores the **source** version; upgrade after that with K3s's own upgrade path. Use §D only if the datastore is suspect too |
| Nothing — it's the quarterly check | §C |
