#!/usr/bin/env bash
#
# k3s-server-backup.sh — job 1 of 2 for k3-master.
#
# Backs up everything K3s needs to be rebuilt on a fresh host: the SQLite
# datastore, the cluster's cryptographic identity, and the config it starts
# with. Job 2 is Velero, which backs up everything *inside* the cluster
# including PVC data. See docs/02-backup-strategy.md.
#
#   Usage:  k3s-server-backup.sh          # the daily run; the timer calls this
#           DRY_RUN=1 k3s-server-backup.sh
#
# One run produces one archive and two small companion files:
#
#   s3://$S3_BUCKET/k3s/daily/YYYY-MM-DD/
#     k3s-YYYY-MM-DD.tar.gz          the whole backup, one file
#     k3s-YYYY-MM-DD.tar.gz.sha256   verify before you trust it
#     MANIFEST.json                  which K3s version to install, read this first
#
# MANIFEST.json is also inside the archive. It is uploaded separately as well
# so a restore can learn the K3s version without downloading the archive.
#
# Inside the archive:
#
#   ./MANIFEST.json
#   ./state.db          the datastore. Placed by hand at restore time, see below
#   ./fs-root/...       mirrors the real filesystem. Restore with
#                         cp -a fs-root/. /
#                       token, tls/, cred/, manifests/, /etc/rancher/k3s and the
#                       k3s systemd unit. Named fs-root rather than root so that
#                       an accidental `tar -xzf ... -C /` cannot quietly scatter
#                       it through root's home directory.
#   ./host-facts/...    plain text. Reference material for rebuilding the host.
#                       Never extracted onto / — read it, apply what applies.
#
# On Sundays the same three files are uploaded a second time under
# k3s/weekly/YYYY-MM-DD/. That second prefix is the entire retention design: an
# S3 lifecycle rule can only say "expire N days after creation", so 7 daily +
# 4 weekly needs exactly two prefixes and two rules.
#
# Safety contract — this script must never cause cluster downtime:
#   * It never starts, stops, restarts or reloads k3s.
#   * It never writes inside /var/lib/rancher/k3s or /etc/rancher/k3s.
#   * The datastore is read through SQLite's online backup API on a read-only
#     connection. SQLite is in WAL mode, so this reader never blocks kine.
#   * systemd runs it niced and with idle I/O priority so it cannot starve the
#     control plane for disk.
#
# Config comes from /etc/k3s-backup/backup.env (mode 0600, root:root):
#   S3_BUCKET=k3-master-dr
#   AWS_REGION=ap-south-1
#   AWS_ACCESS_KEY_ID=...
#   AWS_SECRET_ACCESS_KEY=...
#   HEARTBEAT_URL=...        # optional but strongly recommended, see below
#
# The bucket has default SSE-S3 encryption, so nothing here passes an
# encryption header — S3 encrypts every object on the way in.
#
# Optional overrides:
#   STAGE_ROOT            local staging dir           (default /var/backups/k3s)
#   KEEP_STAGE=1          do not delete the stage dir on success
#   DRY_RUN=1             build the archive, skip every upload
#   FORCE_TIER=weekly     also write the weekly copy regardless of the weekday
#   INCLUDE_HOST_FACTS=0  skip the host fact sheet (default 1)
#   MIN_FREE_MB           refuse to run below this much free disk (default 2048)

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------

ENV_FILE=${ENV_FILE:-/etc/k3s-backup/backup.env}
STAGE_ROOT=${STAGE_ROOT:-/var/backups/k3s}
LOCK_FILE=/run/k3s-server-backup.lock
MIN_FREE_MB=${MIN_FREE_MB:-2048}
INCLUDE_HOST_FACTS=${INCLUDE_HOST_FACTS:-1}

K3S_SERVER_DIR=/var/lib/rancher/k3s/server
K3S_DB_DIR=$K3S_SERVER_DIR/db
K3S_BIN=/usr/local/bin/k3s
K3S_UNIT=/etc/systemd/system/k3s.service

log()  { printf '%s  %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '%s  WARNING: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die()  { printf '%s  ERROR: %s\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

[ $# -eq 0 ] || die "this script takes no arguments (got: $*)"
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

# --------------------------------------------------------------------------
# Run identity
#
# Everything derives from one timestamp taken once, so a run that starts at
# 23:59:59 cannot scatter its files across two days.
# --------------------------------------------------------------------------

RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
RUN_DATE=${RUN_TS%%T*}
STAGE="$STAGE_ROOT/$RUN_DATE"
PAYLOAD="$STAGE/payload"
ARCHIVE="$STAGE/k3s-$RUN_DATE.tar.gz"
MANIFEST="$STAGE/MANIFEST.json"

TIERS=(daily)
if [ "$(date -u +%u)" = "7" ] || [ "${FORCE_TIER:-}" = "weekly" ]; then
  TIERS+=(weekly)
fi

rm -rf "$STAGE"
mkdir -p "$PAYLOAD"
chmod 0700 "$STAGE_ROOT" "$STAGE" "$PAYLOAD"

cleanup() {
  local rc=$?
  if [ "$rc" -eq 0 ] && [ "${KEEP_STAGE:-0}" != "1" ]; then
    rm -rf "$STAGE"
  else
    log "stage directory kept for inspection: $STAGE"
  fi
  find "$STAGE_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime +3 -exec rm -rf {} + 2>/dev/null || true
}
trap cleanup EXIT

log "run $RUN_TS  bucket=$S3_BUCKET  tiers=${TIERS[*]}"

# tar exits 1 for "file changed as we read it", which is expected on a live
# node and is not a failure. Anything >=2 is a real error.
run_tar() {
  local rc=0
  tar "$@" || rc=$?
  [ "$rc" -le 1 ] || return "$rc"
  return 0
}

# The k3s systemd unit spreads ExecStart over continuation lines, so this
# rebuilds it into the single command line a restore has to reproduce.
k3s_start_command() {
  [ -r "$K3S_UNIT" ] || return 0
  awk '
    /^ExecStart=/ { inblk = 1 }
    inblk {
      line = $0
      cont = (line ~ /\\[[:space:]]*$/)
      sub(/\\[[:space:]]*$/, "", line)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      printf "%s ", line
      if (!cont) exit
    }
  ' "$K3S_UNIT" | sed -e 's/^ExecStart=//' -e 's/[[:space:]]\+/ /g' -e 's/[[:space:]]*$//'
}

# --------------------------------------------------------------------------
# 1 — The datastore
#
# A plain copy of a live WAL database can capture a torn page and restore into
# a corrupt cluster. The online backup API produces one consistent file with
# the WAL already folded in, which is why a restore never needs -wal/-shm.
# --------------------------------------------------------------------------

backup_datastore() {
  local out="$PAYLOAD/state.db"
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
    # integrity_check is the load-bearing assertion. The row count is a useful
    # "is this actually a cluster" sanity signal, but a schema surprise must not
    # discard a snapshot that already verified — nor skip the heartbeat and turn
    # a curiosity into a reported backup outage.
    try:
        rows = dst.execute("SELECT count(*) FROM kine").fetchone()[0]
    except sqlite3.Error as exc:
        rows = f"unknown ({exc})"
    print(f"     snapshot ok ({mode}), integrity_check=ok, kine rows={rows}")
finally:
    dst.close()
    src.close()
PY

  [ -s "$out" ] || die "SQLite snapshot is empty"
  chmod 0600 "$out"          # the datastore holds every Secret in the cluster
}

# --------------------------------------------------------------------------
# 2 — Cluster identity and config  (SENSITIVE)
#
# Staged under payload/fs-root/ mirroring the real filesystem, so a restore is
# one copy: cp -a fs-root/. /
#
# Deliberately not called root/: an operator who reaches for
# `tar -xzf ... -C /` under pressure would then write root's home directory
# instead of the paths they meant, and get a silently incomplete restore.
#
# These files only ever restore together: K3s keeps the cluster's bootstrap
# data inside the datastore, encrypted with the server token, so the token,
# tls/, cred/ and state.db are four halves of the same thing.
# --------------------------------------------------------------------------

backup_identity() {
  log "2/4  cluster identity + config -> fs-root/"

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
    [ -e "/$p" ] || die "expected /$p to exist — refusing to write an incomplete backup"
  done

  mkdir -p "$PAYLOAD/fs-root"
  chmod 0700 "$PAYLOAD/fs-root"
  # tar-to-tar rather than cp, so modes, owners and symlinks survive exactly.
  run_tar --warning=no-file-changed --numeric-owner -cf - -C / "${paths[@]}" \
    | tar -xpf - -C "$PAYLOAD/fs-root" \
    || die "staging the cluster identity failed"
}

# --------------------------------------------------------------------------
# 3 — Host fact sheet  (optional, plain text only)
#
# This is deliberately *facts*, not config to be restored. It is what turns
# "remember the static IP and the firewall rules during an outage" into "read
# this file" — about 50 KB of text.
#
# Not captured on purpose: /etc/ssh (host private keys) and authorized_keys.
# Restoring an old host's SSH identity onto a new machine is the wrong move,
# and keeping host keys in the bucket makes the bucket a bigger target.
# --------------------------------------------------------------------------

backup_host_facts() {
  local dir="$PAYLOAD/host-facts"
  log "3/4  host fact sheet -> host-facts/"
  mkdir -p "$dir"

  {
    echo "# Host facts for $(hostname), captured $RUN_TS"
    echo "# Reference material. Do NOT extract this over a fresh install's /etc."
    echo
    echo "## hostname"
    hostnamectl 2>/dev/null || hostname
    echo
    echo "## k3s start command (reproduce these flags on the replacement host)"
    k3s_start_command
    echo
    echo "## os"
    cat /etc/os-release 2>/dev/null
    uname -a
  } > "$dir/README.txt" 2>/dev/null || true

  ip -o addr            > "$dir/ip-addr.txt"          2>/dev/null || true
  ip -o route           > "$dir/ip-route.txt"         2>/dev/null || true
  ufw status verbose    > "$dir/ufw-status.txt"       2>/dev/null || true
  timedatectl           > "$dir/timedatectl.txt"      2>/dev/null || true
  lsblk -f              > "$dir/lsblk.txt"            2>/dev/null || true
  df -h                 > "$dir/df.txt"               2>/dev/null || true
  dpkg --get-selections > "$dir/dpkg-selections.txt"  2>/dev/null || true
  systemctl list-unit-files --state=enabled --no-pager \
                       > "$dir/enabled-units.txt"    2>/dev/null || true
  cp -a /etc/hosts  "$dir/etc-hosts.txt"  2>/dev/null || true
  cp -a /etc/fstab  "$dir/etc-fstab.txt"  2>/dev/null || true

  # netplan is YAML config, not a secret, and it is the fastest way to get the
  # replacement host back on the same address.
  if [ -d /etc/netplan ]; then
    mkdir -p "$dir/netplan"
    cp -a /etc/netplan/*.yaml "$dir/netplan/" 2>/dev/null || true
  fi

  chmod -R go-rwx "$dir"
}

# --------------------------------------------------------------------------
# 4 — Manifest
#
# The first file a restore reads. Nothing else in the backup records the K3s
# version: uname is the kernel, and k3s is a binary in /usr/local/bin so it
# does not appear in dpkg selections.
#
# Written twice on purpose. The copy inside the archive travels with the data;
# the copy uploaded alongside it also carries the archive's own digest, so it
# can be read and verified without downloading 20 MB first.
# --------------------------------------------------------------------------

write_manifest() {
  log "4/4  manifest -> MANIFEST.json"

  local k3s_version="unknown" k3s_raw=""
  if [ -x "$K3S_BIN" ]; then
    k3s_raw=$("$K3S_BIN" --version 2>/dev/null | tr '\n' ';' || true)
    k3s_version=$(printf '%s\n' "$k3s_raw" | sed -n 's/.*k3s version \([^ ;]*\).*/\1/p')
    [ -n "$k3s_version" ] || k3s_version="unknown"
  fi
  [ "$k3s_version" = "unknown" ] \
    && warn "could not determine the k3s version — a restore would have to guess"

  MANIFEST_RUN_TS="$RUN_TS" \
  MANIFEST_DATE="$RUN_DATE" \
  MANIFEST_TIERS="${TIERS[*]}" \
  MANIFEST_K3S_VERSION="$k3s_version" \
  MANIFEST_K3S_RAW="$k3s_raw" \
  MANIFEST_K3S_START="$(k3s_start_command)" \
  MANIFEST_BUCKET="$S3_BUCKET" \
  MANIFEST_ARCHIVE="$(basename "$ARCHIVE")" \
  python3 - "$PAYLOAD/MANIFEST.json" <<'PY'
import json, os, platform, socket, sys

os_release = "unknown"
try:
    with open("/etc/os-release") as fh:
        for line in fh:
            if line.startswith("PRETTY_NAME="):
                os_release = line.split("=", 1)[1].strip().strip('"')
                break
except OSError:
    pass

date = os.environ["MANIFEST_DATE"]
doc = {
    "schema": "k3s-server-backup/manifest/v3",
    "run_timestamp": os.environ["MANIFEST_RUN_TS"],
    "hostname": socket.gethostname(),
    "os_release": os_release,
    "kernel": platform.release(),
    "arch": platform.machine(),
    # Install exactly this version during a restore. Trust this field over any
    # version number written in the documentation.
    "k3s_version": os.environ["MANIFEST_K3S_VERSION"],
    "k3s_version_raw": os.environ.get("MANIFEST_K3S_RAW", "").strip().strip(";"),
    # The flags this server actually ran with. Reinstalling with defaults
    # silently produces a *different* cluster.
    "k3s_start_command": os.environ.get("MANIFEST_K3S_START", ""),
    "k3s_binary_in_bucket": "k3s-release/%s/k3s" % os.environ["MANIFEST_K3S_VERSION"],
    "s3_bucket": os.environ["MANIFEST_BUCKET"],
    "s3_prefixes": [f"k3s/{t}/{date}" for t in os.environ["MANIFEST_TIERS"].split()],
    "archive": {"filename": os.environ["MANIFEST_ARCHIVE"]},
    # Kept ASCII on purpose: this file gets read by whatever tooling is to hand
    # during an outage, not necessarily in a UTF-8 locale.
    "contents": {
        "state.db": "SQLite online backup of the K3s datastore",
        "fs-root/": "restore with: cp -a fs-root/. /  -- token, tls/, cred/, manifests/, /etc/rancher/k3s, systemd unit",
        "host-facts/": "plain-text reference for rebuilding the host. Never extract onto /",
    },
    "restore_hint": "cp -a fs-root/. / ; install -m 0600 state.db /var/lib/rancher/k3s/server/db/ ; rm -f .../state.db-wal .../state.db-shm",
}

with open(sys.argv[1], "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")

print(f"     manifest: k3s={doc['k3s_version']} os={os_release}")
PY
}

# The outer manifest is the inner one plus the archive's size and digest.
finalize_manifest() {
  python3 - "$PAYLOAD/MANIFEST.json" "$MANIFEST" "$ARCHIVE" "$ARCHIVE.sha256" <<'PY'
import json, os, sys

inner, outer, archive, shafile = sys.argv[1:5]
doc = json.load(open(inner))
doc["archive"] = {
    "filename": os.path.basename(archive),
    "bytes": os.path.getsize(archive),
    "sha256": open(shafile).read().split()[0],
}
with open(outer, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
  chmod 0644 "$MANIFEST"
}

# --------------------------------------------------------------------------
# Archive, checksum, upload, verify
# --------------------------------------------------------------------------

build_archive() {
  log "archiving -> $(basename "$ARCHIVE")"
  run_tar --warning=no-file-changed --numeric-owner -czf "$ARCHIVE" -C "$PAYLOAD" . \
    || die "building the archive failed"
  chmod 0600 "$ARCHIVE"

  ( cd "$STAGE" && sha256sum "$(basename "$ARCHIVE")" > "$(basename "$ARCHIVE").sha256" )
  ( cd "$STAGE" && sha256sum -c "$(basename "$ARCHIVE").sha256" >/dev/null ) \
    || die "the archive failed its own checksum before upload"

  log "  $(du -h "$ARCHIVE" | awk '{print $1}') archive, checksum verified locally"
}

upload_all() {
  if [ "${DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN=1 — skipping upload. Archive left in $STAGE"
    KEEP_STAGE=1
    return 0
  fi

  local tier prefix file
  for tier in "${TIERS[@]}"; do
    prefix="k3s/$tier/$RUN_DATE"
    log "upload -> s3://$S3_BUCKET/$prefix/"
    for file in "$ARCHIVE" "$ARCHIVE.sha256" "$MANIFEST"; do
      aws s3 cp "$file" "s3://$S3_BUCKET/$prefix/" --only-show-errors \
        || die "upload failed for $file"
    done
    verify_prefix "$prefix"
  done
}

# Proof the objects actually landed, at the right size. Uses ListBucket rather
# than HeadObject on purpose: the backup credential has no read access to
# k3s/, so a compromised server cannot download what it uploaded.
verify_prefix() {
  local prefix="$1" file name want got
  for file in "$ARCHIVE" "$ARCHIVE.sha256" "$MANIFEST"; do
    name=$(basename "$file")
    want=$(stat -c %s "$file")
    got=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$prefix/$name" \
            --query "Contents[?Key=='$prefix/$name'].Size | [0]" --output text 2>/dev/null || true)
    [ "$got" = "$want" ] \
      || die "verification failed: s3://$S3_BUCKET/$prefix/$name is '${got:-missing}', expected $want bytes"
  done
  log "  verified 3 objects in s3://$S3_BUCKET/$prefix/"
}

# --------------------------------------------------------------------------
# The K3s binary, kept once per version
#
# A restore needs the *matching* K3s release, and old releases are not
# guaranteed to still be downloadable years from now. This uploads the binary
# once per version — the daily run after that is a no-op.
#
# install.sh is not needed: with this binary plus the systemd unit from the
# archive, a restore is copy, chmod, symlink, start. See docs/03.
# --------------------------------------------------------------------------

vault_k3s_release() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  [ -x "$K3S_BIN" ] || return 0

  # Nothing below this point may fail the run: the backup is already safely in
  # S3 by now, and failing here would also skip the heartbeat.
  local ver key
  ver=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["k3s_version"])' \
          "$MANIFEST" 2>/dev/null || true)
  [ -n "$ver" ] && [ "$ver" != "unknown" ] || return 0
  key="k3s-release/$ver/k3s"

  if aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$key" \
       --query "Contents[?Key=='$key'].Size | [0]" --output text 2>/dev/null | grep -qE '^[0-9]+$'; then
    return 0
  fi

  log "vaulting the k3s binary for $ver (once per version)"
  aws s3 cp "$K3S_BIN" "s3://$S3_BUCKET/$key" --only-show-errors \
    || { warn "could not vault the k3s binary — the backup itself is fine"; return 0; }

  local note="$STAGE/RESTORE.txt"
  cat > "$note" <<EOF
K3s $ver, saved from $(hostname) on $RUN_DATE.

This is the exact binary that produced the backups under k3s/. Use it when the
matching release is no longer downloadable from get.k3s.io.

  aws s3 cp s3://$S3_BUCKET/$key ./k3s
  sudo install -m 0755 -o root -g root ./k3s /usr/local/bin/k3s
  for c in kubectl crictl ctr; do sudo ln -sf /usr/local/bin/k3s /usr/local/bin/\$c; done
  # then restore fs-root/etc/systemd/system/k3s.service from the backup archive
  sudo systemctl daemon-reload

install.sh is not required — it only writes the systemd unit, and the unit is
in the backup archive.
EOF
  aws s3 cp "$note" "s3://$S3_BUCKET/k3s-release/$ver/RESTORE.txt" --only-show-errors || true
}

# --------------------------------------------------------------------------
# Heartbeat
#
# The only alert that still works when this server is dead. Pinged after the
# objects have been verified in S3, so it means "the backup arrived", not "the
# script is pleased with itself". If the ping stops arriving, something
# outside this server raises the alarm. See docs/02-backup-strategy.md §7.
# --------------------------------------------------------------------------

ping_heartbeat() {
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  if [ -z "${HEARTBEAT_URL:-}" ]; then
    warn "HEARTBEAT_URL is not set — nothing off this server will notice if the backup stops"
    return 0
  fi
  if curl -fsS -m 15 --retry 2 -o /dev/null "$HEARTBEAT_URL"; then
    log "heartbeat sent"
  else
    warn "heartbeat ping failed — the backup succeeded, but monitoring may report it as missing"
  fi
}

# --------------------------------------------------------------------------
# Run
# --------------------------------------------------------------------------

backup_datastore
backup_identity

if [ "$INCLUDE_HOST_FACTS" = "1" ]; then
  backup_host_facts
else
  log "3/4  host fact sheet: skipped (INCLUDE_HOST_FACTS=0)"
fi

write_manifest
build_archive
finalize_manifest
upload_all
vault_k3s_release
ping_heartbeat

log "run $RUN_TS completed successfully (tiers: ${TIERS[*]})"
