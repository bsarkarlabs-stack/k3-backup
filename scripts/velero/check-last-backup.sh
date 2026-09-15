#!/usr/bin/env bash
#
# check-last-backup.sh — verify Velero actually protected PVC data, then ping
# an off-cluster dead-man endpoint.
#
# Why this exists: a Velero Backup can reach `Completed` having copied zero
# pod volumes (for example when the node-agent cannot read the kubelet root).
# Backup phase alone is therefore not evidence, so this checks the volume work
# as well and only then reports success.
#
# The heartbeat is deliberately *edge-triggered on a new backup*. A run that
# merely re-observes yesterday's still-fresh backup must NOT ping, otherwise a
# single missed schedule silently resets the dead-man timer and the outage is
# never reported. The last reported backup is recorded in STATE_FILE.
#
#   Usage:  check-last-backup.sh
#
# EnvironmentFile: /etc/k3s-backup/velero-monitor.env (0600 root:root)
#   VELERO_HEARTBEAT_URL=https://...   required; must differ from Job 1's URL
#   MIN_EXPECTED_PVBS=6                required; take it from a verified backup
#   MAX_AGE_HOURS=30                   optional; default 30
#   STATE_FILE=...                     optional; default below
#
# Exit codes: 0 = verified and reported, 1 = a problem worth alerting on.

set -euo pipefail

KUBECONFIG_PATH=${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}
MAX_AGE_HOURS=${MAX_AGE_HOURS:-30}
STATE_FILE=${STATE_FILE:-/var/lib/k3s-backup/velero-last-reported}

: "${VELERO_HEARTBEAT_URL:?VELERO_HEARTBEAT_URL is required}"
: "${MIN_EXPECTED_PVBS:?MIN_EXPECTED_PVBS is required; set it from a known-good backup}"

case "$MIN_EXPECTED_PVBS" in ''|*[!0-9]*) echo "MIN_EXPECTED_PVBS must be a positive integer" >&2; exit 1 ;; esac
case "$MAX_AGE_HOURS"    in ''|*[!0-9]*) echo "MAX_AGE_HOURS must be a positive integer"    >&2; exit 1 ;; esac
[ "$MIN_EXPECTED_PVBS" -gt 0 ] || { echo "MIN_EXPECTED_PVBS must be greater than zero" >&2; exit 1; }
[ "$MAX_AGE_HOURS"    -gt 0 ] || { echo "MAX_AGE_HOURS must be greater than zero"    >&2; exit 1; }

for tool in k3s python3 curl; do
  command -v "$tool" >/dev/null || { echo "$tool not found" >&2; exit 1; }
done
[ -r "$KUBECONFIG_PATH" ] || { echo "cannot read $KUBECONFIG_PATH" >&2; exit 1; }

export KUBECONFIG="$KUBECONFIG_PATH"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"

' EXIT

k3s kubectl -n velero get backups.velero.io -o json > "$tmp/backups.json"

# Selects the newest scheduled backup, enforces phase and freshness, and
# refuses to report a backup that was already reported on an earlier run.
backup_uid=$(python3 - "$tmp/backups.json" "$MAX_AGE_HOURS" "$STATE_FILE" <<'PY'
import datetime as dt
import json
import os
import sys

path, max_age_hours, state_file = sys.argv[1], int(sys.argv[2]), sys.argv[3]
doc = json.load(open(path))

scheduled = [
    item
    for item in doc.get("items", [])
    if item.get("metadata", {}).get("labels", {}).get("velero.io/schedule-name")
    in {"daily", "weekly"}
]
if not scheduled:
    raise SystemExit("no daily/weekly Velero backup exists")

latest = max(scheduled, key=lambda item: item["metadata"]["creationTimestamp"])
meta = latest["metadata"]
status = latest.get("status", {})
name, uid = meta["name"], meta["uid"]

phase = status.get("phase")
if phase != "Completed":
    raise SystemExit(f"latest scheduled backup {name} is {phase!r}, not Completed")

stamp = status.get("completionTimestamp")
if not stamp:
    raise SystemExit(f"backup {name} has no completionTimestamp")

completed = dt.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
age = dt.datetime.now(dt.timezone.utc) - completed
if age > dt.timedelta(hours=max_age_hours):
    raise SystemExit(f"backup {name} completed {age} ago; maximum is {max_age_hours}h")

# Edge trigger: never re-report a backup already reported. Without this, a
# missed schedule would still refresh the dead-man timer from the previous
# backup and the missed run would go unnoticed.
if os.path.exists(state_file):
    with open(state_file) as fh:
        if fh.read().strip() == uid:
            raise SystemExit(
                f"no new scheduled Velero backup since {name} was last verified "
                f"(completed {age} ago) - a scheduled run was missed"
            )

print(uid)
PY
)

k3s kubectl -n velero get podvolumebackups.velero.io \
  -l "velero.io/backup-uid=$backup_uid" -o json > "$tmp/pvbs.json"

backup_name=$(python3 - "$tmp/pvbs.json" "$MIN_EXPECTED_PVBS" <<'PY'
import json
import sys

doc = json.load(open(sys.argv[1]))
minimum = int(sys.argv[2])
items = doc.get("items", [])
if not items:
    raise SystemExit(
        "the newest scheduled backup has no PodVolumeBackups - no PVC data was "
        "captured even though the backup reported Completed"
    )

name = items[0]["metadata"]["labels"].get("velero.io/backup-name", "unknown")
incomplete = sorted(
    item["metadata"]["name"]
    for item in items
    if item.get("status", {}).get("phase") != "Completed"
)
if incomplete:
    raise SystemExit(f"backup {name} has non-Completed PodVolumeBackups: {incomplete}")
if len(items) < minimum:
    raise SystemExit(
        f"backup {name} captured {len(items)} pod volumes; expected at least {minimum}"
    )

print(name)
PY
)

curl -fsS -m 15 --retry 2 -o /dev/null "$VELERO_HEARTBEAT_URL"

# Recorded only after a successful ping, so a failed ping is retried next run.
install -d -m 0700 "$(dirname "$STATE_FILE")"
printf '%s\n' "$backup_uid" > "$STATE_FILE"
chmod 0600 "$STATE_FILE"

echo "verified and reported $backup_name"
