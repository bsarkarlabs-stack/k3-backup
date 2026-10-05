#!/usr/bin/env bash
#
# install-velero.sh — install job 2 of 2, then stop.
#
# This script validates the inputs and installs (or reconciles) one pinned
# Velero pair. It does not upgrade Velero across versions, back up PVCs, or
# restore anything. Those are separate steps; the notes at the end say why
# `velero install --wait` is not that proof.
#
# A re-run when the server is already at the pinned version passes --apply so
# the same flags are reconciled. A different server version stops here.
# Version upgrades need that version's own guide (CRDs and images at least):
# https://velero.io/docs/
#
# The node-agent is required for this file-system backup install. Other
# backup methods exist; this script does not set them up.
#
# Required: S3_BUCKET AWS_REGION CREDS_FILE KUBELET_ROOT_DIR
# Optional: TARGET_CONTEXT (required when the kubeconfig has several contexts)
#           TARGET_NODE    (required when several nodes are Ready)
#
# The only pair this file knows is the pin below. To move off it, change the
# pin after checking https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility
# Do not keep a compatibility table in this script; it goes stale.

set -euo pipefail
umask 077

PIN_VELERO=v1.18.0
PIN_PLUGIN=v1.14.1

: "${S3_BUCKET:?set S3_BUCKET, for example k3-master-dr-sep-07}"
: "${AWS_REGION:?set AWS_REGION, for example us-east-1}"
: "${CREDS_FILE:?set CREDS_FILE to the Velero credentials file}"
: "${KUBELET_ROOT_DIR:?set KUBELET_ROOT_DIR to the kubelet root, normally /var/lib/kubelet}"

VELERO_VERSION=${VELERO_VERSION:-$PIN_VELERO}
VELERO_PLUGIN_VERSION=${VELERO_PLUGIN_VERSION:-$PIN_PLUGIN}

die() { echo "error: $*" >&2; exit 1; }

if [ "$VELERO_VERSION" != "$PIN_VELERO" ] || [ "$VELERO_PLUGIN_VERSION" != "$PIN_PLUGIN" ]; then
  die "refusing $VELERO_VERSION with plugin $VELERO_PLUGIN_VERSION. This script only validates the pin $PIN_VELERO + $PIN_PLUGIN. Check the plugin compatibility page, then change PIN_VELERO and PIN_PLUGIN in this file."
fi

work=$(mktemp -d)
probe_key=""
cleanup() {
  if [ -n "$probe_key" ]; then
    aws s3api delete-object --bucket "$S3_BUCKET" --key "$probe_key" --region "$AWS_REGION" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

if [ -z "${KUBECONFIG:-}" ] && [ -r /etc/rancher/k3s/k3s.yaml ]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  echo "using KUBECONFIG=/etc/rancher/k3s/k3s.yaml"
fi

if command -v kubectl >/dev/null 2>&1; then
  kctl() { kubectl "$@"; }
elif command -v k3s >/dev/null 2>&1; then
  kctl() { k3s kubectl "$@"; }
else
  die "kubectl not found"
fi
for tool in velero aws python3; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool not found"
done
case $(aws --version 2>&1) in
  aws-cli/2*) ;;
  *) die "AWS CLI v2 is required" ;;
esac

set +e
client_out=$(velero version --client-only 2>&1)
client_rc=$?
set -e
if [ "$client_rc" -ne 0 ]; then
  echo "velero version --client-only failed (exit $client_rc):" >&2
  printf '%s\n' "$client_out" >&2
  exit 1
fi
have=$(printf '%s\n' "$client_out" | awk '/Version:/{print $2; exit}')
[ -n "$have" ] || die "velero version --client-only printed no Version line"
[ "$have" = "$VELERO_VERSION" ] || die "velero CLI is $have; install $VELERO_VERSION"
echo "velero CLI $have, plugin $VELERO_PLUGIN_VERSION"

[ -f "$CREDS_FILE" ] || die "credentials file not found: $CREDS_FILE"
[ -r "$CREDS_FILE" ] || die "cannot read $CREDS_FILE"
python3 - "$CREDS_FILE" "$work/aws.env" <<'PY'
import os, shlex, stat, sys
path, dest = sys.argv[1], sys.argv[2]
if os.path.getsize(path) == 0:
    sys.exit("credentials file is empty")
if os.stat(path).st_mode & (stat.S_IRWXG | stat.S_IRWXO):
    sys.exit("credentials file is readable by group or others; chmod 600")
section, vals = None, {}
for raw in open(path, encoding="utf-8"):
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    if line.startswith("[") and line.endswith("]"):
        section = line[1:-1].strip()
        continue
    if section != "default" or "=" not in line:
        continue
    key, value = line.split("=", 1)
    vals[key.strip()] = value.strip().strip('"').strip("'")
missing = [k for k in ("aws_access_key_id", "aws_secret_access_key") if not vals.get(k)]
if missing:
    sys.exit("credentials file needs non-empty [default] " + ", ".join(missing))
for key, value in vals.items():
    if "PUT_" in value.upper() or "CHANGEME" in value.upper():
        sys.exit("credentials file still has a placeholder in " + key)
with open(dest, "w", encoding="utf-8") as out:
    out.write("export AWS_ACCESS_KEY_ID=%s\n" % shlex.quote(vals["aws_access_key_id"]))
    out.write("export AWS_SECRET_ACCESS_KEY=%s\n" % shlex.quote(vals["aws_secret_access_key"]))
    out.write("unset AWS_SESSION_TOKEN\nunset AWS_PROFILE\n")
PY
# shellcheck disable=SC1091
source "$work/aws.env"
rm -f "$work/aws.env"
export AWS_DEFAULT_REGION="$AWS_REGION"

set +e
ident=$(aws sts get-caller-identity --output json 2>"$work/sts.err")
ident_rc=$?
set -e
if [ "$ident_rc" -ne 0 ]; then
  echo "STS rejected these credentials:" >&2
  cat "$work/sts.err" >&2
  exit 1
fi
printf '%s\n' "$ident" | python3 -c 'import json,sys; arn=json.load(sys.stdin).get("Arn",""); print(arn); sys.exit(0 if arn.endswith(":user/k3-master-velero") else 1)' \
  || die "caller must be IAM user k3-master-velero (not the Job 1 writer, and not an admin key)"

set +e
loc=$(aws s3api get-bucket-location --bucket "$S3_BUCKET" --region "$AWS_REGION" --query LocationConstraint --output text 2>"$work/loc.err")
loc_rc=$?
set -e
if [ "$loc_rc" -ne 0 ]; then
  echo "cannot read bucket location:" >&2
  cat "$work/loc.err" >&2
  exit 1
fi
if [ -z "$loc" ] || [ "$loc" = "None" ] || [ "$loc" = "null" ]; then
  loc=us-east-1
fi
[ "$loc" = "$AWS_REGION" ] || die "bucket $S3_BUCKET is in $loc, AWS_REGION is $AWS_REGION"
aws s3api head-bucket --bucket "$S3_BUCKET" --region "$AWS_REGION" >/dev/null
echo "bucket $S3_BUCKET is in $loc"

probe_key="velero/_install-preflight/$(date +%Y%m%dT%H%M%SZ)-$$"
printf 'probe\n' > "$work/probe-body"
aws s3api put-object --bucket "$S3_BUCKET" --key "$probe_key" --region "$AWS_REGION" --body "$work/probe-body" >/dev/null
aws s3api get-object --bucket "$S3_BUCKET" --key "$probe_key" --region "$AWS_REGION" "$work/probe-got" >/dev/null
cmp -s "$work/probe-body" "$work/probe-got" || die "GetObject did not return the probe object"
sse=$(aws s3api head-object --bucket "$S3_BUCKET" --key "$probe_key" --region "$AWS_REGION" --query ServerSideEncryption --output text)
[ "$sse" = "AES256" ] || die "probe object encryption is ${sse:-none}; expected AES256 from the bucket default. This script did not request encryption."
aws s3api delete-object --bucket "$S3_BUCKET" --key "$probe_key" --region "$AWS_REGION" >/dev/null
probe_key=""
echo "velero key can write and read velero/; object stored as AES256"

if ! ctx=$(kctl config current-context 2>"$work/ctx.err"); then
  echo "cannot read the kubeconfig context:" >&2
  cat "$work/ctx.err" >&2
  exit 1
fi
[ -n "$ctx" ] || die "kubeconfig has no current context"
if [ -n "${TARGET_CONTEXT:-}" ] && [ "$ctx" != "$TARGET_CONTEXT" ]; then
  die "current context is $ctx, TARGET_CONTEXT is $TARGET_CONTEXT"
fi
nctx=$(kctl config get-contexts -o name | grep -c . || true)
nctx=${nctx:-0}
if [ "$nctx" -gt 1 ] && [ -z "${TARGET_CONTEXT:-}" ]; then
  die "kubeconfig has $nctx contexts; set TARGET_CONTEXT"
fi
server=$(kctl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
[ -n "$server" ] || die "context $ctx has no cluster server"
echo "context=$ctx server=$server"

kctl get nodes -o json > "$work/nodes.json"
TARGET_NODE=$(python3 - "$work/nodes.json" "${TARGET_NODE:-}" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
wanted = sys.argv[2]
ready = []
for node in doc.get("items", []):
    ok = any(c.get("type") == "Ready" and c.get("status") == "True" for c in node.get("status", {}).get("conditions", []))
    if ok:
        ready.append(node["metadata"]["name"])
if wanted:
    if wanted not in ready:
        sys.exit("TARGET_NODE %s is not Ready (%s)" % (wanted, ", ".join(ready) or "none"))
    print(wanted)
elif len(ready) == 1:
    print(ready[0])
elif not ready:
    sys.exit("no Ready nodes")
else:
    sys.exit("several Ready nodes; set TARGET_NODE to one of: " + ", ".join(ready))
PY
)
echo "target node: $TARGET_NODE"
if [ "${KUBECONFIG:-}" = "/etc/rancher/k3s/k3s.yaml" ]; then
  names=$({ hostname || true; hostname -s || true; hostname -f || true; } | sort -u)
  printf '%s\n' "$names" | grep -Fxq "$TARGET_NODE" || die "this machine is $(hostname), Ready node is $TARGET_NODE"
  [ -d "$KUBELET_ROOT_DIR/pods" ] || die "$KUBELET_ROOT_DIR/pods does not exist on this machine"
fi

enc=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$TARGET_NODE")
kctl get --raw "/api/v1/nodes/${enc}/proxy/configz" > "$work/configz.json"
python3 - "$work/configz.json" "$KUBELET_ROOT_DIR" <<'PY'
import json, sys
wanted = sys.argv[2].rstrip("/") or "/"
found = []
def walk(obj):
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key == "rootDirectory" and isinstance(value, str):
                found.append(value.rstrip("/") or "/")
            else:
                walk(value)
    elif isinstance(obj, list):
        for item in obj:
            walk(item)
walk(json.load(open(sys.argv[1])))
if not found:
    sys.exit("kubelet configz has no rootDirectory")
if any(item != wanted for item in found):
    sys.exit("KUBELET_ROOT_DIR is %s, node rootDirectory is %s" % (wanted, sorted(set(found))))
print("kubelet root matches " + wanted)
PY

kctl get pv -o json > "$work/pvs.json"
kctl get pvc -A -o json > "$work/pvcs.json"
python3 - "$work/pvs.json" "$work/pvcs.json" <<'PY'
import json, sys
pvs = {item["metadata"]["name"]: item for item in json.load(open(sys.argv[1])).get("items", [])}
skip = {"capacity", "claimRef", "accessModes", "persistentVolumeReclaimPolicy", "storageClassName", "volumeMode", "nodeAffinity", "mountOptions"}
bad = []
for pvc in json.load(open(sys.argv[2])).get("items", []):
    if pvc.get("status", {}).get("phase") != "Bound":
        continue
    meta = pvc["metadata"]
    pv = pvs.get(pvc.get("spec", {}).get("volumeName", ""))
    label = "%s/%s" % (meta["namespace"], meta["name"])
    if pv is None:
        bad.append(label + " is Bound but its PV is missing")
        continue
    spec = pv.get("spec", {})
    if spec.get("volumeMode") == "Block":
        kind = "block"
    elif "hostPath" in spec:
        kind = "hostPath"
    elif "local" in spec:
        kind = "local"
    else:
        kind = next((key for key in spec if key not in skip), "unknown")
    if kind not in ("hostPath", "local"):
        bad.append("%s storageClass=%s type=%s" % (label, pvc.get("spec", {}).get("storageClassName") or "-", kind))
if bad:
    sys.exit("this install disables snapshots, so every Bound PVC must be hostPath or local:\n" + "\n".join(bad))
print("bound PVCs are hostPath or local")
PY

script_dir=$(cd "$(dirname "$0")" && pwd)
for schedule in "$script_dir/schedule-daily.yaml" "$script_dir/schedule-weekly.yaml"; do
  [ -f "$schedule" ] || die "missing $schedule"
  echo "schedule file: $schedule"
  grep -E '^[[:space:]]*(schedule|ttl|defaultVolumesToFsBackup|snapshotVolumes|includeClusterResources):' "$schedule" | sed 's/^[[:space:]]*//'
  grep -Eq '^[[:space:]]*(includedNamespaces|excludedNamespaces):' "$schedule" && die "$schedule limits namespaces; this design backs up every namespace"
  grep -q 'defaultVolumesToFsBackup: true' "$schedule" || die "$schedule must set defaultVolumesToFsBackup: true"
  grep -q 'snapshotVolumes: false' "$schedule" || die "$schedule must set snapshotVolumes: false"
  grep -q 'includeClusterResources: true' "$schedule" || die "$schedule must set includeClusterResources: true"
done

install_args=(
  --provider aws
  --plugins "velero/velero-plugin-for-aws:${VELERO_PLUGIN_VERSION}"
  --bucket "$S3_BUCKET"
  --prefix velero
  --secret-file "$CREDS_FILE"
  --backup-location-config "region=${AWS_REGION}"
  --use-node-agent
  --kubelet-root-dir "$KUBELET_ROOT_DIR"
  --default-volumes-to-fs-backup
  --uploader-type kopia
  --use-volume-snapshots=false
  --wait
)

if kctl -n velero get deploy/velero >/dev/null 2>&1; then
  set +e
  server_out=$(velero version 2>&1)
  server_rc=$?
  set -e
  [ "$server_rc" -eq 0 ] || { printf '%s\n' "$server_out" >&2; die "Velero is installed but the server version could not be read"; }
  current=$(printf '%s\n' "$server_out" | awk '/^Server:$/{s=1} s && /Version:/{print $2; exit}')
  [ -n "$current" ] || die "Velero is installed but returned no server version"
  if [ "$current" != "$VELERO_VERSION" ]; then
    die "server is $current, pin is $VELERO_VERSION. Re-running this script is not an upgrade. Follow the Velero upgrade guide for that jump (CRDs and images, then install --apply with these same flags): https://velero.io/docs/"
  fi
  echo "server is already $current; reconciling flags with velero install --apply"
  velero install --apply "${install_args[@]}"
else
  echo "first install"
  velero install "${install_args[@]}"
fi

echo "velero install --wait only waits for the deployment. It does not prove S3 from the cluster, a PVC backup, or a restore."

phase=""
for _ in $(seq 1 24); do
  phase=$(kctl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$phase" = "Available" ] && break
  sleep 5
done
[ "$phase" = "Available" ] || die "BackupStorageLocation default is ${phase:-missing}, not Available"
kctl -n velero rollout status daemonset/node-agent --timeout=300s
echo "BackupStorageLocation default is Available and the node-agent daemonset is rolled out"

kctl get pods -A -o json > "$work/pods.json"
python3 - "$work/pods.json" <<'PY'
import json, sys
rows = []
for pod in json.load(open(sys.argv[1])).get("items", []):
    if pod.get("status", {}).get("phase") != "Running":
        continue
    meta = pod["metadata"]
    excludes = {part.strip() for part in (meta.get("annotations") or {}).get("backup.velero.io/backup-volumes-excludes", "").split(",") if part.strip()}
    claims = {vol["name"] for vol in pod.get("spec", {}).get("volumes", []) if "persistentVolumeClaim" in vol}
    seen = set()
    containers = list(pod.get("spec", {}).get("containers", [])) + list(pod.get("spec", {}).get("initContainers") or [])
    for container in containers:
        for mount in container.get("volumeMounts", []):
            name = mount.get("name")
            if name in claims and name not in excludes and name not in seen:
                seen.add(name)
                rows.append("%s/%s volume=%s" % (meta["namespace"], meta["name"], name))
print("mounted PVCs to expect in a later backup: %d" % len(rows))
for row in sorted(rows):
    print("  " + row)
if not rows:
    print("  (none right now)")
PY

echo
echo "Do not treat a fixed PVC count as the check. Use the mounted list above."
echo "An empty Pod Volume Backups section can be a wrong kubelet root, backup scope, an exclusion, an unsupported volume, or a node-agent that is not Running on that node."
echo "File-system backup copies live files. It does not make Prometheus, Loki, or other databases application-consistent."
echo "Recovery is not proven until a backup shows each of those volumes Completed and a restored file matches."
echo
echo "Apply the schedules:"
printf '  kubectl apply -f %q\n' "$script_dir/schedule-daily.yaml"
printf '  kubectl apply -f %q\n' "$script_dir/schedule-weekly.yaml"
