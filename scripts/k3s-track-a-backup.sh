#!/usr/bin/env bash
#
# k3s-track-a-backup.sh — Track A (node & cluster-state) backup for k3-master.
#
# Implements components 1, 2, 3, 4 and 8 of docs/02-backup-strategy.md.
#
#   Usage:  k3s-track-a-backup.sh db     # datastore only              (every 6h)
#           k3s-track-a-backup.sh full   # datastore + everything else (daily)
#
# Every run also writes a manifest to the run-manifests/ prefix recording the
# k3s version and the sha256 of every artifact in that run. Start a restore by
# reading the newest manifest — it names the binary version to install and the
# exact object set that belongs together. See issue #17.
#
# Safety contract — this script must never cause cluster downtime:
#   * It never starts, stops, restarts or reloads k3s.
#   * It never writes inside /var/lib/rancher/k3s or /etc/rancher/k3s.
#   * The SQLite datastore is read through the online backup API on a
#     read-only connection. SQLite is in WAL mode, so this reader does not
#     block kine's writers.
#   * It runs niced and with idle I/O priority so it cannot starve the
#     control plane for disk.
#
# Config comes from /etc/k3s-backup/backup.env (mode 0600, root:root):
#   S3_BUCKET=k3-master-dr
#   AWS_REGION=eu-central-1
#   KMS_KEY_ID=arn:aws:kms:...:key/...
#   AWS_ACCESS_KEY_ID=...
#   AWS_SECRET_ACCESS_KEY=...
#
# Optional overrides:
#   STAGE_ROOT      local staging dir            (default /var/backups/k3s)
#   KEEP_STAGE=1    do not delete the stage dir on success
#   DRY_RUN=1       build every artifact, skip the S3 upload
#   TEXTFILE_DIR    node_exporter textfile collector dir for the success metric
#   BACKUP_NODE_CONFIG=0
#                   K3s-only mode: skip the node OS config capture (netplan, ufw,
#                   /etc/ssh, dpkg selections). Default is 1 (capture it).
#                   It costs ~1 MB and it is the only thing that makes restore
#                   runbook step 2 automatic rather than reconstruction from
#                   memory during an outage. Turn it off deliberately, not by
#                   accident.

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

ENV_FILE=${ENV_FILE:-/etc/k3s-backup/backup.env}
STAGE_ROOT=${STAGE_ROOT:-/var/backups/k3s}
LOCK_FILE=/run/k3s-track-a-backup.lock
MIN_FREE_MB=${MIN_FREE_MB:-2048}
BACKUP_NODE_CONFIG=${BACKUP_NODE_CONFIG:-1}

K3S_SERVER_DIR=/var/lib/rancher/k3s/server
K3S_DB_DIR=$K3S_SERVER_DIR/db
KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml
K3S_BIN=/usr/local/bin/k3s

log()  { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die()  { printf '%s  ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

MODE=${1:-}
case "$MODE" in
  db|full) ;;
  *) die "usage: $(basename "$0") db|full" ;;
esac

[ "$(id -u)" -eq 0 ] || die "must run as root"

# --------------------------------------------------------------------------
# Single-instance lock — a 6h and a daily timer can otherwise collide
# --------------------------------------------------------------------------

exec 9>"$LOCK_FILE"
flock -n 9 || die "another run is already in progress (lock: $LOCK_FILE)"

# --------------------------------------------------------------------------
# Preconditions
# --------------------------------------------------------------------------

[ -r "$ENV_FILE" ] || die "missing config file $ENV_FILE"
# shellcheck disable=SC1090
set -a; . "$ENV_FILE"; set +a

: "${S3_BUCKET:?S3_BUCKET not set in $ENV_FILE}"
: "${AWS_REGION:?AWS_REGION not set in $ENV_FILE}"
: "${KMS_KEY_ID:?KMS_KEY_ID not set in $ENV_FILE}"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"

command -v aws     >/dev/null || die "aws CLI not found"
command -v python3 >/dev/null || die "python3 not found (needed for the SQLite backup API)"
command -v tar     >/dev/null || die "tar not found"
[ -d "$K3S_DB_DIR" ] || die "$K3S_DB_DIR does not exist — is this k3-master?"

DF_TARGET=$STAGE_ROOT
[ -d "$DF_TARGET" ] || DF_TARGET=$(dirname "$STAGE_ROOT")
[ -d "$DF_TARGET" ] || DF_TARGET=/
FREE_MB=$(df -Pm "$DF_TARGET" | awk 'NR==2{print $4}')
[ "${FREE_MB:-0}" -ge "$MIN_FREE_MB" ] \
  || die "only ${FREE_MB}MB free on $DF_TARGET, need ${MIN_FREE_MB}MB — refusing to stage a backup"

RUN_TS=$(date -u +%Y%m%dT%H%M%SZ)
STAGE="$STAGE_ROOT/$RUN_TS"
mkdir -p "$STAGE"
chmod 0700 "$STAGE_ROOT" "$STAGE"

cleanup() {
  local rc=$?
  if [ "$rc" -eq 0 ] && [ "${KEEP_STAGE:-0}" != "1" ]; then
    rm -rf "$STAGE"
  else
    log "stage directory kept for inspection: $STAGE"
  fi
  # prune anything older than 3 days regardless of outcome
  find "$STAGE_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup EXIT

log "run $RUN_TS  mode=$MODE  stage=$STAGE  bucket=$S3_BUCKET"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# tar exits 1 for "file changed as we read it", which is expected on a live
# node and is not a failure. Anything >=2 is a real error.
run_tar() {
  local rc=0
  tar "$@" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  return 0
}

ARTIFACTS=()   # "localfile|s3prefix"

register() { ARTIFACTS+=("$1|$2"); }

# --------------------------------------------------------------------------
# Component 1 — K3s datastore (SQLite online backup API)
# --------------------------------------------------------------------------

backup_datastore() {
  local out="$STAGE/state-$RUN_TS.db"
  log "component 1: SQLite online backup -> $(basename "$out")"

  python3 - "$K3S_DB_DIR/state.db" "$out" <<'PY'
import sqlite3, sys

src_path, dst_path = sys.argv[1], sys.argv[2]

# Prefer a genuinely read-only connection. WAL mode needs a writable -shm,
# which root has; if the platform still refuses, fall back to a normal open
# pinned to query_only so no write can reach the live datastore either way.
try:
    src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True, timeout=30)
    mode = "read-only"
except sqlite3.OperationalError as exc:
    sys.stderr.write(f"WARNING: read-only open failed ({exc}); using query_only fallback\n")
    src = sqlite3.connect(src_path, timeout=30)
    src.execute("PRAGMA query_only = ON")
    mode = "query_only"

dst = sqlite3.connect(dst_path)
try:
    src.backup(dst)                       # whole database, one step
    row = dst.execute("PRAGMA integrity_check").fetchone()
    if not row or row[0] != "ok":
        raise SystemExit(f"integrity_check on the snapshot returned: {row}")
    n = dst.execute(
        "SELECT count(*) FROM sqlite_master WHERE type='table'").fetchone()[0]
    print(f"    snapshot ok ({mode}), integrity_check=ok, tables={n}")
finally:
    dst.close()
    src.close()
PY

  [ -s "$out" ] || die "SQLite snapshot is empty"
  register "$out" "cluster-state/db"
}

# --------------------------------------------------------------------------
# Component 2 — node identity & certificates  (SENSITIVE)
# --------------------------------------------------------------------------

backup_server_identity() {
  local out="$STAGE/server-identity-$RUN_TS.tar.gz"
  log "component 2: server identity (tls/, cred/, token) -> $(basename "$out")"
  run_tar --warning=no-file-changed -czf "$out" \
      -C "$K3S_SERVER_DIR" tls cred token \
    || die "tar of server identity failed"
  chmod 0600 "$out"
  register "$out" "cluster-state/server-identity"
}

# --------------------------------------------------------------------------
# Component 3 — K3s configuration
# --------------------------------------------------------------------------

backup_config() {
  local out="$STAGE/config-$RUN_TS.tar.gz"
  log "component 3: /etc/rancher/k3s + k3s.service -> $(basename "$out")"
  run_tar --warning=no-file-changed -czf "$out" -C / \
      etc/rancher/k3s \
      etc/systemd/system/k3s.service \
    || die "tar of k3s config failed"
  chmod 0600 "$out"          # k3s.yaml embeds admin client certs
  register "$out" "config"
}

# --------------------------------------------------------------------------
# Component 4 — static manifests
# --------------------------------------------------------------------------

backup_manifests() {
  local out="$STAGE/manifests-$RUN_TS.tar.gz"
  log "component 4: static manifests -> $(basename "$out")"
  run_tar --warning=no-file-changed -czf "$out" \
      -C "$K3S_SERVER_DIR" manifests \
    || die "tar of static manifests failed"
  register "$out" "manifests"
}

# --------------------------------------------------------------------------
# Node OS configuration  (gap #3 / #4)  — SENSITIVE (SSH host keys)
# --------------------------------------------------------------------------

backup_node_config() {
  local dir="$STAGE/node-config" out="$STAGE/node-config-$RUN_TS.tar.gz"
  log "node config: netplan, ufw, ssh, time, packages -> $(basename "$out")"
  mkdir -p "$dir"; chmod 0700 "$dir"

  cp -a /etc/netplan               "$dir/netplan"        2>/dev/null || true
  cp -a /etc/ufw                   "$dir/ufw"            2>/dev/null || true
  cp -a /etc/ssh                   "$dir/ssh"            2>/dev/null || true
  cp -a /etc/hosts /etc/fstab /etc/hostname "$dir/"      2>/dev/null || true
  cp -a /etc/systemd/timesyncd.conf "$dir/"              2>/dev/null || true
  cp -a /etc/chrony                "$dir/chrony"         2>/dev/null || true

  mkdir -p "$dir/authorized_keys"
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    cp -a "$f" "$dir/authorized_keys/$(echo "$f" | tr '/' '_')" 2>/dev/null || true
  done

  ufw status verbose            > "$dir/ufw-status.txt"      2>/dev/null || true
  timedatectl                   > "$dir/timedatectl.txt"     2>/dev/null || true
  ip -j addr                    > "$dir/ip-addr.json"        2>/dev/null || true
  ip -j route                   > "$dir/ip-route.json"       2>/dev/null || true
  lsblk -f                      > "$dir/lsblk.txt"           2>/dev/null || true
  dpkg --get-selections         > "$dir/dpkg-selections.txt" 2>/dev/null || true
  uname -a                      > "$dir/uname.txt"           2>/dev/null || true
  systemctl list-unit-files --state=enabled --no-pager \
                                > "$dir/enabled-units.txt"   2>/dev/null || true
  find /etc/systemd/system -maxdepth 2 -type d -name '*.d' \
                                > "$dir/systemd-overrides.txt" 2>/dev/null || true

  run_tar --warning=no-file-changed -czf "$out" -C "$STAGE" node-config \
    || die "tar of node config failed"
  chmod 0600 "$out"
  rm -rf "$dir"
  register "$out" "node-config"
}

# --------------------------------------------------------------------------
# Component 8 — container image manifest
# --------------------------------------------------------------------------

backup_image_manifest() {
  local out="$STAGE/images-$RUN_TS.txt" dig="$STAGE/image-digests-$RUN_TS.txt"
  log "component 8: image manifest from live pods"

  if [ ! -x "$K3S_BIN" ] || [ ! -r "$KUBECONFIG_PATH" ]; then
    log "  WARNING: kubectl/kubeconfig unavailable, skipping image manifest"
    return 0
  fi

  local jp_images='{range .items[*]}{range .spec.initContainers[*]}{.image}{"\n"}{end}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
  local jp_digests='{range .items[*]}{range .status.containerStatuses[*]}{.imageID}{"\n"}{end}{end}'

  KUBECONFIG=$KUBECONFIG_PATH "$K3S_BIN" kubectl get pods -A -o jsonpath="$jp_images" \
    | sed '/^$/d' | sort -u > "$out" || { log "  WARNING: image list failed"; return 0; }

  KUBECONFIG=$KUBECONFIG_PATH "$K3S_BIN" kubectl get pods -A -o jsonpath="$jp_digests" \
    | sed '/^$/d' | sort -u > "$dig" || true

  log "  $(wc -l < "$out") unique image references"
  register "$out" "image-manifest"
  [ -s "$dig" ] && register "$dig" "image-manifest"
  return 0
}

# --------------------------------------------------------------------------
# Run manifest  (issue #17)
#
# A restore needs the *matching* k3s binary version, and needs to know which
# objects across six S3 prefixes belong to the same run. Nothing else in the
# backup records either: uname is the kernel, dpkg selections do not list k3s
# (it is a binary in /usr/local/bin), and every prefix carries its own
# timestamp. Without this file the version is only ever written down in
# markdown, which goes stale the first time k3s is upgraded.
#
# Written after checksum_all so it can carry each artifact's digest, and
# registered afterwards so it uploads alongside them.
# --------------------------------------------------------------------------

write_manifest() {
  local out="$STAGE/manifest-$RUN_TS.json"
  local list="$STAGE/.manifest-input"
  log "run manifest -> $(basename "$out")"

  local k3s_version="unknown" k3s_raw=""
  if [ -x "$K3S_BIN" ]; then
    k3s_raw=$("$K3S_BIN" --version 2>/dev/null | tr '\n' ';' || true)
    k3s_version=$(printf '%s\n' "$k3s_raw" | sed -n 's/.*k3s version \([^ ;]*\).*/\1/p')
    [ -n "$k3s_version" ] || k3s_version="unknown"
  fi
  [ "$k3s_version" = "unknown" ] \
    && log "  WARNING: could not determine k3s version — restore will have to guess"

  : > "$list"
  local entry file prefix
  for entry in "${ARTIFACTS[@]}"; do
    file=${entry%%|*}; prefix=${entry##*|}
    printf '%s\t%s\t%s\t%s\n' \
      "$prefix" "$(basename "$file")" \
      "$(stat -c %s "$file")" \
      "$(awk '{print $1}' "$file.sha256")" >> "$list"
  done

  MANIFEST_RUN_TS="$RUN_TS" \
  MANIFEST_MODE="$MODE" \
  MANIFEST_K3S_VERSION="$k3s_version" \
  MANIFEST_K3S_RAW="$k3s_raw" \
  MANIFEST_BUCKET="$S3_BUCKET" \
  python3 - "$list" "$out" <<'PY'
import json, os, platform, socket, sys

list_path, out_path = sys.argv[1], sys.argv[2]

artifacts = []
with open(list_path) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        prefix, name, size, sha = line.split("\t")
        artifacts.append({"s3_prefix": prefix, "filename": name,
                          "bytes": int(size), "sha256": sha})

os_release = "unknown"
try:
    with open("/etc/os-release") as fh:
        for line in fh:
            if line.startswith("PRETTY_NAME="):
                os_release = line.split("=", 1)[1].strip().strip('"')
                break
except OSError:
    pass

doc = {
    "schema": "k3s-track-a-backup/manifest/v1",
    "run_timestamp": os.environ["MANIFEST_RUN_TS"],
    "mode": os.environ["MANIFEST_MODE"],
    "hostname": socket.gethostname(),
    "os_release": os_release,
    "kernel": platform.release(),
    "arch": platform.machine(),
    "k3s_version": os.environ["MANIFEST_K3S_VERSION"],
    "k3s_version_raw": os.environ.get("MANIFEST_K3S_RAW", "").strip().strip(";"),
    "s3_bucket": os.environ["MANIFEST_BUCKET"],
    "artifact_count": len(artifacts),
    "artifacts": artifacts,
}

with open(out_path, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")

print(f"    manifest: k3s={doc['k3s_version']} "
      f"os={os_release} artifacts={len(artifacts)}")
PY

  rm -f "$list"
  [ -s "$out" ] || die "run manifest is empty"
  ( cd "$(dirname "$out")" && sha256sum "$(basename "$out")" > "$(basename "$out").sha256" )
  register "$out" "run-manifests"
}

# --------------------------------------------------------------------------
# Checksum + upload
# --------------------------------------------------------------------------

checksum_all() {
  log "checksumming ${#ARTIFACTS[@]} artifact(s)"
  local entry file
  for entry in "${ARTIFACTS[@]}"; do
    file=${entry%%|*}
    ( cd "$(dirname "$file")" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256" )
  done
  for entry in "${ARTIFACTS[@]}"; do
    file=${entry%%|*}
    ( cd "$(dirname "$file")" && sha256sum -c "$(basename "$file").sha256" >/dev/null ) \
      || die "checksum verification failed for $file"
  done
  log "  all checksums verified locally before upload"
}

upload_all() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1 — skipping upload. Artifacts left in $STAGE"
    KEEP_STAGE=1
    return 0
  fi
  local entry file prefix
  for entry in "${ARTIFACTS[@]}"; do
    file=${entry%%|*}; prefix=${entry##*|}
    log "upload -> s3://$S3_BUCKET/$prefix/$(basename "$file")"
    aws s3 cp "$file" "s3://$S3_BUCKET/$prefix/" \
        --only-show-errors --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID" \
      || die "upload failed for $file"
    aws s3 cp "$file.sha256" "s3://$S3_BUCKET/$prefix/" \
        --only-show-errors --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID" \
      || die "upload failed for $file.sha256"
  done
}

# --------------------------------------------------------------------------
# Success metric for Alertmanager (phase 4 wiring; harmless if absent)
# --------------------------------------------------------------------------

write_metric() {
  local dir=${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}
  [ -d "$dir" ] || return 0
  local f="$dir/k3s_backup_track_a.prom"
  {
    echo "# HELP backup_last_success_timestamp Unix time of the last successful Track A backup."
    echo "# TYPE backup_last_success_timestamp gauge"
    echo "backup_last_success_timestamp{track=\"a\",mode=\"$MODE\"} $(date +%s)"
  } > "$f.tmp" && mv "$f.tmp" "$f"
  log "wrote success metric to $f"
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

backup_datastore

if [ "$MODE" = "full" ]; then
  backup_server_identity
  backup_config
  backup_manifests
  if [ "$BACKUP_NODE_CONFIG" = "1" ]; then
    backup_node_config
  else
    log "node config: skipped (BACKUP_NODE_CONFIG=0, K3s-only mode)"
    log "  NOTE: restore runbook step 2 is manual reconstruction without this."
  fi
  backup_image_manifest
fi

checksum_all
write_manifest      # after checksum_all: the manifest carries every digest
upload_all
write_metric

log "run $RUN_TS completed successfully (mode=$MODE)"
