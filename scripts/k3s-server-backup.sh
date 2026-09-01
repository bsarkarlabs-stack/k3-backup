#!/usr/bin/env bash
#
# k3s-server-backup.sh — Job 1 of 2 for k3-master.
#
# Backs up everything K3s needs to be rebuilt on a fresh host: the SQLite
# datastore, the cluster's cryptographic identity, and the config that tells
# K3s how to start. Job 2 is Velero, which backs up everything *inside* the
# cluster including PVC data. See docs/02-backup-strategy.md.
#
#   Usage:  k3s-server-backup.sh          # the daily run; the timer calls this
#           DRY_RUN=1 k3s-server-backup.sh
#
# One run produces one folder in S3:
#
#   s3://$S3_BUCKET/k3s/daily/YYYY-MM-DD/
#     state.db              SQLite online backup — a single consistent file
#     k3s-identity.tar.gz   tls/ cred/ token manifests/ /etc/rancher/k3s
#                           /etc/systemd/system/k3s.service[.env]
#     node-config.tar.gz    host OS config (optional, see INCLUDE_NODE_CONFIG)
#     MANIFEST.json         k3s version, OS, and the sha256 of every file above
#     *.sha256              one per artifact
#
# On Sundays the same files are uploaded a second time under
# k3s/weekly/YYYY-MM-DD/. That second prefix is the entire retention design:
# an S3 lifecycle rule can only say "expire N days after creation", so a
# 7-daily + 4-weekly policy needs exactly two prefixes and two rules.
#
#   k3s/daily/   expire  8 days   ->  7 daily restore points
#   k3s/weekly/  expire 31 days   ->  4 weekly restore points
#
# Filenames carry no timestamp on purpose: the folder is the timestamp, and a
# re-run on the same day replaces that day's set cleanly instead of leaving
# half-matched files behind. Bucket versioning keeps the replaced copies.
#
# Safety contract — this script must never cause cluster downtime:
#   * It never starts, stops, restarts or reloads k3s.
#   * It never writes inside /var/lib/rancher/k3s or /etc/rancher/k3s.
#   * The SQLite datastore is read through the online backup API on a
#     read-only connection. SQLite is in WAL mode, so this reader does not
#     block kine's writers.
#   * systemd runs it niced and with idle I/O priority so it cannot starve
#     the control plane for disk.
#
# Config comes from /etc/k3s-backup/backup.env (mode 0600, root:root):
#   S3_BUCKET=k3-master-dr
#   AWS_REGION=ap-south-1
#   KMS_KEY_ID=arn:aws:kms:...:key/...        # full ARN, not the bare key id
#   AWS_ACCESS_KEY_ID=...
#   AWS_SECRET_ACCESS_KEY=...
#
# Optional overrides:
#   STAGE_ROOT            local staging dir           (default /var/backups/k3s)
#   KEEP_STAGE=1          do not delete the stage dir on success
#   DRY_RUN=1             build every artifact, skip the S3 upload
#   FORCE_TIER=weekly     also write the weekly copy regardless of the weekday
#   INCLUDE_NODE_CONFIG=0 skip the host OS config capture (default 1)
#   TEXTFILE_DIR          node_exporter textfile collector dir for the metric

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

ENV_FILE=${ENV_FILE:-/etc/k3s-backup/backup.env}
STAGE_ROOT=${STAGE_ROOT:-/var/backups/k3s}
LOCK_FILE=/run/k3s-server-backup.lock
MIN_FREE_MB=${MIN_FREE_MB:-2048}
INCLUDE_NODE_CONFIG=${INCLUDE_NODE_CONFIG:-1}

K3S_SERVER_DIR=/var/lib/rancher/k3s/server
K3S_DB_DIR=$K3S_SERVER_DIR/db
K3S_BIN=/usr/local/bin/k3s

log() { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { printf '%s  ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[ $# -eq 0 ] || die "this script takes no arguments (got: $*)
       The old db|full modes are gone — there is one daily run now.
       See docs/02-backup-strategy.md."

[ "$(id -u)" -eq 0 ] || die "must run as root"

# --------------------------------------------------------------------------
# Single-instance lock
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

# KMS_KEY_ID must be the full ARN, not the bare key id. The bucket policy compares
# the upload header against the ARN with StringNotEquals, so a bare id denies every
# single upload with an AccessDenied that looks like an encryption fault rather than
# a wrongly-formatted variable. Fail here instead, where the message is readable.
case "$KMS_KEY_ID" in
  arn:aws:kms:*) ;;
  *) die "KMS_KEY_ID must be the full key ARN, not the key id.
       got:      $KMS_KEY_ID
       expected: arn:aws:kms:<region>:<account-id>:key/<uuid>
       Fix it in $ENV_FILE. A bare key id makes the bucket policy reject every upload." ;;
esac

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

# --------------------------------------------------------------------------
# Run identity
#
# Everything derives from one timestamp taken once, so a run that starts at
# 23:59:59 cannot scatter its files across two days.
# --------------------------------------------------------------------------

RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_DATE=${RUN_TS%%T*}
STAGE="$STAGE_ROOT/$RUN_DATE"

# Sunday (7) also writes the weekly copy. Two prefixes, two lifecycle rules,
# no date arithmetic anywhere else.
TIERS=(daily)
if [ "$(date -u +%u)" = "7" ] || [ "${FORCE_TIER:-}" = "weekly" ]; then
  TIERS+=(weekly)
fi

rm -rf "$STAGE"
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

log "run $RUN_TS  bucket=$S3_BUCKET  tiers=${TIERS[*]}"

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

ARTIFACTS=()
register() { ARTIFACTS+=("$1"); }

# --------------------------------------------------------------------------
# 1 — The datastore
#
# A plain copy of a live WAL database can capture a torn page and restore into
# a corrupt cluster. The online backup API produces one consistent file with
# the WAL already folded in, which is why the restore never needs -wal/-shm.
# --------------------------------------------------------------------------

backup_datastore() {
  local out="$STAGE/state.db"
  log "1/4  SQLite online backup -> state.db"

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
    print(f"     snapshot ok ({mode}), integrity_check=ok, tables={n}")
finally:
    dst.close()
    src.close()
PY

  [ -s "$out" ] || die "SQLite snapshot is empty"
  chmod 0600 "$out"          # the datastore holds every Secret in the cluster
  register "$out"
}

# --------------------------------------------------------------------------
# 2 — Cluster identity and config  (SENSITIVE)
#
# One archive, rooted at /, so a restore is a single `tar -xzf ... -C /`.
# These files only ever restore together: K3s keeps the cluster's bootstrap
# data inside the datastore, encrypted with the server token, so the token,
# tls/, cred/ and state.db are four halves of the same thing.
# --------------------------------------------------------------------------

backup_identity() {
  local out="$STAGE/k3s-identity.tar.gz"
  log "2/4  cluster identity + config -> k3s-identity.tar.gz"

  local -a paths=(
    var/lib/rancher/k3s/server/tls
    var/lib/rancher/k3s/server/cred
    var/lib/rancher/k3s/server/token
    var/lib/rancher/k3s/server/manifests
    etc/rancher/k3s
    etc/systemd/system/k3s.service
  )
  # Present on installs that pass flags via the environment file.
  [ -f /etc/systemd/system/k3s.service.env ] && paths+=(etc/systemd/system/k3s.service.env)

  local p
  for p in "${paths[@]}"; do
    [ -e "/$p" ] || die "expected /$p to exist — refusing to write an incomplete identity archive"
  done

  run_tar --warning=no-file-changed --numeric-owner -czf "$out" -C / "${paths[@]}" \
    || die "tar of cluster identity failed"
  chmod 0600 "$out"
  register "$out"
}

# --------------------------------------------------------------------------
# 3 — Host OS config  (optional, SENSITIVE: SSH host keys)
#
# Not needed to bring K3s back, but it is the difference between restore step 2
# being a file extraction and being reconstruction from memory during an
# outage. It rides along in this job's folder — no extra job, no extra prefix,
# no extra retention rule, about 1 MB.
# --------------------------------------------------------------------------

backup_node_config() {
  local dir="$STAGE/node-config" out="$STAGE/node-config.tar.gz"
  log "3/4  host OS config -> node-config.tar.gz"
  mkdir -p "$dir"; chmod 0700 "$dir"

  cp -a /etc/netplan                "$dir/netplan"   2>/dev/null || true
  cp -a /etc/ufw                    "$dir/ufw"       2>/dev/null || true
  cp -a /etc/ssh                    "$dir/ssh"       2>/dev/null || true
  cp -a /etc/chrony                 "$dir/chrony"    2>/dev/null || true
  cp -a /etc/hosts /etc/fstab /etc/hostname "$dir/"  2>/dev/null || true
  cp -a /etc/systemd/timesyncd.conf "$dir/"          2>/dev/null || true

  mkdir -p "$dir/authorized_keys"
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [ -f "$f" ] || continue
    cp -a "$f" "$dir/authorized_keys/$(echo "$f" | tr '/' '_')" 2>/dev/null || true
  done

  ufw status verbose    > "$dir/ufw-status.txt"      2>/dev/null || true
  timedatectl           > "$dir/timedatectl.txt"     2>/dev/null || true
  ip -j addr            > "$dir/ip-addr.json"        2>/dev/null || true
  ip -j route           > "$dir/ip-route.json"       2>/dev/null || true
  lsblk -f              > "$dir/lsblk.txt"           2>/dev/null || true
  dpkg --get-selections > "$dir/dpkg-selections.txt" 2>/dev/null || true
  uname -a              > "$dir/uname.txt"           2>/dev/null || true
  systemctl list-unit-files --state=enabled --no-pager \
                        > "$dir/enabled-units.txt"   2>/dev/null || true

  run_tar --warning=no-file-changed -czf "$out" -C "$STAGE" node-config \
    || die "tar of node config failed"
  chmod 0600 "$out"
  rm -rf "$dir"
  register "$out"
}

# --------------------------------------------------------------------------
# 4 — Manifest
#
# A restore needs the *matching* k3s version, and nothing else in the backup
# records it: uname is the kernel, and k3s is a binary in /usr/local/bin so it
# does not appear in dpkg selections. Written after the checksums so it can
# carry each artifact's digest, and it lives in the same folder as the files it
# describes — it can never expire before them or outlive them.
# --------------------------------------------------------------------------

write_manifest() {
  local out="$STAGE/MANIFEST.json"
  local list="$STAGE/.manifest-input"
  log "4/4  manifest -> MANIFEST.json"

  local k3s_version="unknown" k3s_raw=""
  if [ -x "$K3S_BIN" ]; then
    k3s_raw=$("$K3S_BIN" --version 2>/dev/null | tr '\n' ';' || true)
    k3s_version=$(printf '%s\n' "$k3s_raw" | sed -n 's/.*k3s version \([^ ;]*\).*/\1/p')
    [ -n "$k3s_version" ] || k3s_version="unknown"
  fi
  [ "$k3s_version" = "unknown" ] \
    && log "     WARNING: could not determine k3s version — a restore would have to guess"

  : > "$list"
  local file
  for file in "${ARTIFACTS[@]}"; do
    printf '%s\t%s\t%s\n' \
      "$(basename "$file")" \
      "$(stat -c %s "$file")" \
      "$(awk '{print $1}' "$file.sha256")" >> "$list"
  done

  MANIFEST_RUN_TS="$RUN_TS" \
  MANIFEST_DATE="$RUN_DATE" \
  MANIFEST_TIERS="${TIERS[*]}" \
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
        name, size, sha = line.split("\t")
        artifacts.append({"filename": name, "bytes": int(size), "sha256": sha})

os_release = "unknown"
try:
    with open("/etc/os-release") as fh:
        for line in fh:
            if line.startswith("PRETTY_NAME="):
                os_release = line.split("=", 1)[1].strip().strip('"')
                break
except OSError:
    pass

tiers = os.environ["MANIFEST_TIERS"].split()
date = os.environ["MANIFEST_DATE"]

doc = {
    "schema": "k3s-server-backup/manifest/v2",
    "run_timestamp": os.environ["MANIFEST_RUN_TS"],
    "hostname": socket.gethostname(),
    "os_release": os_release,
    "kernel": platform.release(),
    "arch": platform.machine(),
    # Install exactly this version during a restore. Trust this field over any
    # version number written in the documentation.
    "k3s_version": os.environ["MANIFEST_K3S_VERSION"],
    "k3s_version_raw": os.environ.get("MANIFEST_K3S_RAW", "").strip().strip(";"),
    "s3_bucket": os.environ["MANIFEST_BUCKET"],
    "s3_prefixes": [f"k3s/{t}/{date}" for t in tiers],
    "artifact_count": len(artifacts),
    "artifacts": artifacts,
}

with open(out_path, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")

print(f"     manifest: k3s={doc['k3s_version']} os={os_release} "
      f"artifacts={len(artifacts)} prefixes={','.join(doc['s3_prefixes'])}")
PY

  rm -f "$list"
  [ -s "$out" ] || die "manifest is empty"
  ( cd "$STAGE" && sha256sum MANIFEST.json > MANIFEST.json.sha256 )
  register "$out"
}

# --------------------------------------------------------------------------
# Checksum + upload
# --------------------------------------------------------------------------

checksum_all() {
  log "checksumming ${#ARTIFACTS[@]} artifact(s)"
  local file
  for file in "${ARTIFACTS[@]}"; do
    ( cd "$(dirname "$file")" && sha256sum "$(basename "$file")" > "$(basename "$file").sha256" )
  done
  for file in "${ARTIFACTS[@]}"; do
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
  local tier file
  for tier in "${TIERS[@]}"; do
    local prefix="k3s/$tier/$RUN_DATE"
    log "upload -> s3://$S3_BUCKET/$prefix/"
    for file in "${ARTIFACTS[@]}"; do
      # Files >8 MB go up as a multipart upload, which needs kms:Decrypt on the
      # backup credential as well as GenerateDataKey. state.db is ~64 MB.
      aws s3 cp "$file" "s3://$S3_BUCKET/$prefix/" \
          --only-show-errors --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID" \
        || die "upload failed for $file"
      aws s3 cp "$file.sha256" "s3://$S3_BUCKET/$prefix/" \
          --only-show-errors --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID" \
        || die "upload failed for $file.sha256"
    done
  done
}

# --------------------------------------------------------------------------
# Success metric
#
# Harmless if node-exporter is not reading this directory — but do not rely on
# it as the only alert. Alerting on the age of the newest object under
# k3s/daily/ proves the backup arrived, rather than trusting the script's own
# opinion of itself. See docs/02-backup-strategy.md.
# --------------------------------------------------------------------------

write_metric() {
  local dir=${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}
  [ -d "$dir" ] || return 0
  local f="$dir/k3s_server_backup.prom"
  {
    echo "# HELP k3s_server_backup_last_success_timestamp Unix time of the last successful k3s server backup."
    echo "# TYPE k3s_server_backup_last_success_timestamp gauge"
    echo "k3s_server_backup_last_success_timestamp $(date +%s)"
  } > "$f.tmp" && mv "$f.tmp" "$f"
  log "wrote success metric to $f"
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

backup_datastore
backup_identity

if [ "$INCLUDE_NODE_CONFIG" = "1" ]; then
  backup_node_config
else
  log "3/4  host OS config: skipped (INCLUDE_NODE_CONFIG=0)"
  log "     NOTE: restore step 2 becomes manual reconstruction without this."
fi

checksum_all
write_manifest      # after checksum_all: the manifest carries every digest
upload_all
write_metric

log "run $RUN_TS completed successfully (tiers: ${TIERS[*]})"
