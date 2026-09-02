#!/usr/bin/env bash
#
# install-velero.sh — one-time install of job 2 of 2 on k3-master.
#
# Run this once, from your laptop or from the node, with a kubeconfig that has
# cluster-admin. It is idempotent: re-running it upgrades in place.
#
# What this sets up:
#   * Velero + the AWS object-store plugin, writing to s3://$S3_BUCKET/velero/
#   * The node-agent daemonset, which is the only way to back up local-path
#     volumes (no snapshot support, Delete reclaim policy)
#   * Nothing else. The two Schedule objects are applied separately so they
#     can be edited without touching the install.
#
# Encryption is the bucket's own default (SSE-S3), so nothing is passed here —
# S3 encrypts every object on arrival. See docs/02-backup-strategy.md §3.
#
# Prerequisites: the same bucket job 1 uses, and a credentials file holding the
# backup identity.

set -euo pipefail

: "${S3_BUCKET:?set S3_BUCKET, e.g. export S3_BUCKET=k3-master-dr}"
: "${AWS_REGION:?set AWS_REGION, e.g. export AWS_REGION=ap-south-1}"
: "${CREDS_FILE:?set CREDS_FILE to a file holding the AWS credentials block}"

# Pin both versions. An unpinned install means the plugin and the server can
# drift apart on the next run and fail in a way that looks like a bucket
# problem. Check compatibility before bumping either:
# https://github.com/vmware-tanzu/velero-plugin-for-aws#compatibility
VELERO_PLUGIN_VERSION=${VELERO_PLUGIN_VERSION:-v1.10.0}
VELERO_VERSION=${VELERO_VERSION:-v1.15.0}

# `velero install` deploys velero/velero:<CLI version> — the server version is
# whatever CLI happens to be on the machine running this. Pinning the plugin
# but not the CLI is half a pin: the next engineer installs from a different
# laptop and gets a different server. Fail loudly instead.
have=$(velero version --client-only 2>/dev/null | awk '/Version:/{print $2; exit}')
if [ "$have" != "$VELERO_VERSION" ]; then
  echo "velero CLI is '${have:-unknown}', this install is pinned to $VELERO_VERSION." >&2
  echo "Install the matching CLI, or set VELERO_VERSION deliberately after" >&2
  echo "checking plugin compatibility. Do not just override it to continue." >&2
  exit 1
fi

command -v velero >/dev/null || {
  echo "velero CLI not found — install it first:" >&2
  echo "  https://velero.io/docs/main/basic-install/" >&2
  exit 1
}

# CREDS_FILE must look like:
#   [default]
#   aws_access_key_id=...
#   aws_secret_access_key=...
[ -r "$CREDS_FILE" ] || { echo "cannot read $CREDS_FILE" >&2; exit 1; }

velero install \
  --provider aws \
  --plugins "velero/velero-plugin-for-aws:${VELERO_PLUGIN_VERSION}" \
  --bucket "$S3_BUCKET" \
  --prefix velero \
  --secret-file "$CREDS_FILE" \
  --backup-location-config "region=${AWS_REGION}" \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --uploader-type kopia \
  --use-volume-snapshots=false \
  --wait

echo
echo "Now apply the two schedules:"
echo "  kubectl apply -f $(dirname "$0")/schedule-daily.yaml"
echo "  kubectl apply -f $(dirname "$0")/schedule-weekly.yaml"
echo
echo "Then verify, in this order — a green checkmark is not evidence:"
echo "  kubectl -n velero get pods                 # node-agent must be Running on the node"
echo "  velero backup create verify-\$(date +%s) --wait"
echo "  velero backup describe <name> --details    # confirm all 6 PVCs listed under 'Pod Volume Backups'"
echo
echo "If 'Pod Volume Backups' is empty, the node-agent is not reading the"
echo "kubelet root correctly — see docs/05-gaps-and-open-questions.md."
