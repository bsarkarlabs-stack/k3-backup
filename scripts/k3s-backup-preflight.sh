#!/usr/bin/env bash
#
# k3s-backup-preflight.sh — verify EVERYTHING before the first real backup runs.
#
#   Usage:  sudo ./k3s-backup-preflight.sh              # full check
#           sudo ./k3s-backup-preflight.sh --no-aws     # skip AWS/S3 checks
#           sudo ./k3s-backup-preflight.sh --no-upload  # AWS checks, no test upload
#
# This script CHANGES NOTHING on the cluster. Against K3s it is strictly
# read-only: it never starts, stops or reconfigures anything, never writes
# inside /var/lib/rancher/k3s or /etc/rancher/k3s, and opens the datastore
# read-only. The only thing it writes anywhere is two throwaway test objects
# in S3 under _preflight/ (fixed key names, so repeat runs overwrite rather
# than accumulate).
#
# It answers four questions, in order:
#
#   A. Is the tooling on this box capable of running the backup at all?
#   B. Is the config file present, correct, and correctly formatted?
#   C. Does the S3 bucket / KMS key / IAM login actually exist and work?
#      Including a 64 MB multipart upload, which is the one that catches a
#      missing kms:Decrypt (#21) — a small-file test passes and hides it.
#   D. What is actually running in each namespace, and what of it would NOT
#      be recovered by the backup we have today?
#
# Exit codes:  0 = ready to run    1 = blocking problems    2 = warnings only
#
# Anything it finds, it prints the exact command to fix.

# NOTE: deliberately no `set -e`. Every check must run even when an earlier
# one fails — a preflight that stops at the first problem makes you run it
# five times to find five things.
set -uo pipefail

DO_AWS=1
DO_UPLOAD=1
for arg in "$@"; do
  case "$arg" in
    --no-aws)    DO_AWS=0 ;;
    --no-upload) DO_UPLOAD=0 ;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

ENV_FILE=${ENV_FILE:-/etc/k3s-backup/backup.env}
K3S_SERVER_DIR=/var/lib/rancher/k3s/server
K3S_BIN=/usr/local/bin/k3s
KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml
STAGE_ROOT=${STAGE_ROOT:-/var/backups/k3s}

FAILS=0; WARNS=0; PASSES=0
declare -a REMEDIES=()

c_red=''; c_yel=''; c_grn=''; c_dim=''; c_bold=''; c_off=''
if [ -t 1 ]; then
  c_red=$'\033[31m'; c_yel=$'\033[33m'; c_grn=$'\033[32m'
  c_dim=$'\033[2m';  c_bold=$'\033[1m'; c_off=$'\033[0m'
fi

section() { printf '\n%s=== %s ===%s\n' "$c_bold" "$1" "$c_off"; }
pass()    { printf '  %sPASS%s  %s\n' "$c_grn" "$c_off" "$1"; PASSES=$((PASSES+1)); }
warn()    { printf '  %sWARN%s  %s\n' "$c_yel" "$c_off" "$1"; WARNS=$((WARNS+1));
            [ $# -gt 1 ] && REMEDIES+=("WARN|$1|$2"); return 0; }
fail()    { printf '  %sFAIL%s  %s\n' "$c_red" "$c_off" "$1"; FAILS=$((FAILS+1));
            [ $# -gt 1 ] && REMEDIES+=("FAIL|$1|$2"); return 0; }
info()    { printf '  %s%s%s\n' "$c_dim" "$1" "$c_off"; }

printf '%sK3s backup preflight%s — %s\n' "$c_bold" "$c_off" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%sread-only against the cluster; changes nothing%s\n' "$c_dim" "$c_off"

# ===========================================================================
section "A. Tooling on this server"
# ===========================================================================

if [ "$(id -u)" -eq 0 ]; then
  pass "running as root"
else
  fail "not running as root — the backup needs root to read the datastore and certs" \
       "sudo $0 $*"
fi

for t in aws tar gzip python3 flock sha256sum openssl; do
  if command -v "$t" >/dev/null 2>&1; then
    pass "$t present"
  else
    case "$t" in
      aws) fail "$t missing — required to upload backups" "apt-get install -y awscli  # or the official AWS CLI v2 installer" ;;
      openssl) warn "$t missing — only needed to read certificate expiry dates" "apt-get install -y openssl" ;;
      *)   fail "$t missing — required by the backup script" "apt-get install -y $t" ;;
    esac
  fi
done

if python3 -c 'import sqlite3' 2>/dev/null; then
  pass "python3 sqlite3 module present (this is what makes a safe DB snapshot)"
else
  fail "python3 sqlite3 module missing — cannot take a consistent datastore backup" \
       "apt-get install -y python3  # the sqlite3 module ships with python3"
fi

if [ -x "$K3S_BIN" ]; then
  K3S_VER=$("$K3S_BIN" --version 2>/dev/null | sed -n 's/^k3s version \([^ ]*\).*/\1/p')
  if [ -n "$K3S_VER" ]; then
    pass "k3s binary readable, version $K3S_VER"
  else
    fail "k3s binary present but --version gave nothing — backups would record k3s_version=unknown" \
         "$K3S_BIN --version   # investigate why this produces no output"
  fi
else
  fail "no k3s binary at $K3S_BIN — is this k3-master?" "which k3s"
fi

FREE_MB=$(df -Pm "$(dirname "$STAGE_ROOT")" 2>/dev/null | awk 'NR==2{print $4}')
if [ -n "${FREE_MB:-}" ] && [ "$FREE_MB" -ge 2048 ]; then
  pass "disk space for staging: ${FREE_MB} MB free (need 2048 MB)"
elif [ -n "${FREE_MB:-}" ]; then
  fail "only ${FREE_MB} MB free where backups stage — the script refuses under 2048 MB" \
       "df -h /   # free space before running the backup"
else
  warn "could not determine free disk space" ""
fi

# ===========================================================================
section "B. Backup configuration file"
# ===========================================================================

CFG_OK=1
if [ -r "$ENV_FILE" ]; then
  pass "config file exists: $ENV_FILE"

  PERM=$(stat -c '%a %U:%G' "$ENV_FILE" 2>/dev/null)
  if [ "$PERM" = "600 root:root" ]; then
    pass "config permissions are 600 root:root"
  else
    fail "config permissions are '$PERM', expected '600 root:root' — this file holds AWS keys" \
         "chown root:root $ENV_FILE && chmod 600 $ENV_FILE"
  fi

  # shellcheck disable=SC1090
  set -a; . "$ENV_FILE" 2>/dev/null; set +a

  for v in S3_BUCKET AWS_REGION KMS_KEY_ID; do
    if [ -n "${!v:-}" ]; then pass "$v is set"; else
      fail "$v is not set in $ENV_FILE" "echo '$v=...' >> $ENV_FILE"; CFG_OK=0
    fi
  done

  # #24 — the bucket policy compares against the full ARN
  case "${KMS_KEY_ID:-}" in
    arn:aws:kms:*) pass "KMS_KEY_ID is a full ARN (correct)" ;;
    "")            : ;;
    *) fail "KMS_KEY_ID is '${KMS_KEY_ID}' — must be the full ARN, not a key id or alias" \
            "aws kms describe-key --key-id ${KMS_KEY_ID} --query KeyMetadata.Arn --output text
       # put that ARN in $ENV_FILE as KMS_KEY_ID"; CFG_OK=0 ;;
  esac

  for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [ -n "${!v:-}" ]; then pass "$v is set"; else
      warn "$v not set in the config — fine only if this server uses an instance role" ""
    fi
  done
else
  fail "config file missing: $ENV_FILE" \
       "sudo install -d -m 0700 -o root -g root /etc/k3s-backup
       sudo install -m 0600 -o root -g root /dev/null $ENV_FILE
       # then add: S3_BUCKET, AWS_REGION, KMS_KEY_ID (full ARN),
       #           AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"
  CFG_OK=0
fi

# ===========================================================================
section "C. AWS — bucket, key, and login"
# ===========================================================================

if [ "$DO_AWS" -eq 0 ]; then
  info "skipped (--no-aws)"
elif [ "$CFG_OK" -eq 0 ]; then
  warn "skipping AWS checks — fix the configuration above first" ""
else
  export AWS_DEFAULT_REGION="$AWS_REGION"

  WHO=$(aws sts get-caller-identity --query Arn --output text 2>&1)
  if [ $? -eq 0 ] && [ -n "$WHO" ]; then
    pass "AWS login works: $WHO"
  else
    fail "AWS login failed — check the keys in $ENV_FILE" \
         "aws sts get-caller-identity   # run with the same env to see the error"
    WHO=""
  fi

  if [ -n "$WHO" ]; then
    # ---- bucket exists and is reachable -------------------------------
    if aws s3api head-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1; then
      pass "bucket exists and is reachable: s3://$S3_BUCKET"

      # ---- public access block ----------------------------------------
      PAB=$(aws s3api get-public-access-block --bucket "$S3_BUCKET" \
              --query 'PublicAccessBlockConfiguration.[BlockPublicAcls,IgnorePublicAcls,BlockPublicPolicy,RestrictPublicBuckets]' \
              --output text 2>/dev/null)
      if [ "$PAB" = "True	True	True	True" ]; then
        pass "all public access is blocked"
      else
        fail "public access is not fully blocked (got: ${PAB:-none}) — this bucket holds the cluster CA" \
             "aws s3api put-public-access-block --bucket $S3_BUCKET \\
         --public-access-block-configuration \\
         BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
      fi

      # ---- versioning --------------------------------------------------
      VER=$(aws s3api get-bucket-versioning --bucket "$S3_BUCKET" --query Status --output text 2>/dev/null)
      if [ "$VER" = "Enabled" ]; then
        pass "versioning is enabled"
      else
        fail "versioning is '${VER:-off}' — without it a bad overwrite is unrecoverable" \
             "aws s3api put-bucket-versioning --bucket $S3_BUCKET \\
         --versioning-configuration Status=Enabled"
      fi

      # ---- default encryption -----------------------------------------
      ENC=$(aws s3api get-bucket-encryption --bucket "$S3_BUCKET" \
              --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
              --output text 2>/dev/null)
      ENCKEY=$(aws s3api get-bucket-encryption --bucket "$S3_BUCKET" \
              --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID' \
              --output text 2>/dev/null)
      if [ "$ENC" = "aws:kms" ]; then
        pass "default encryption is SSE-KMS"
        if [ "$ENCKEY" = "$KMS_KEY_ID" ]; then
          pass "bucket default key matches KMS_KEY_ID"
        else
          warn "bucket default key differs from KMS_KEY_ID — uploads pass the key explicitly, so this is survivable, but confirm it is intended" \
               "aws s3api get-bucket-encryption --bucket $S3_BUCKET"
        fi
      else
        fail "default encryption is '${ENC:-none}', expected aws:kms — backups contain plaintext Secrets and the cluster CA" \
             "# see docs/07 Stage C.5 — and note encryption is NOT retroactive,
       # anything already uploaded stays unencrypted"
      fi

      # ---- bucket policy -----------------------------------------------
      if aws s3api get-bucket-policy --bucket "$S3_BUCKET" >/dev/null 2>&1; then
        pass "a bucket policy is attached"
      else
        warn "no bucket policy — the deny-unencrypted and deny-wrong-key guards are missing" \
             "# see docs/07 Stage C.6"
      fi

      # ---- lifecycle rules: without these the bucket grows forever ------
      LC=$(aws s3api get-bucket-lifecycle-configuration --bucket "$S3_BUCKET" \
             --query 'Rules[].Filter.Prefix' --output text 2>/dev/null)
      if [ -n "$LC" ]; then
        pass "lifecycle rules are configured"

        # Exactly two rules are expected: 7 daily + 4 weekly. See docs/02 §6.
        for p in k3s/daily/ k3s/weekly/; do
          case " $LC " in
            *" $p "*) : ;;
            *) warn "no lifecycle rule covers $p — that folder will grow without limit" \
                    "# see docs/07 Stage C.6a for the two-rule set" ;;
          esac
        done

        # A lifecycle rule on velero/ is actively destructive: Velero's file-system
        # backups live in a Kopia repository whose objects reference each other, and
        # it expires them itself by TTL. An S3 expiry deletes chunks that valid
        # backups still depend on, and the damage only surfaces during a restore.
        case " $LC " in
          *" velero"*)
            fail "a lifecycle rule covers velero/ — this will silently corrupt Velero backups" \
                 "# remove any rule whose prefix starts with velero/ (docs/02 §6).
       Velero expires its own backups by TTL. If you want a safety net there,
       use a NONCURRENT version expiry, never a current-version one." ;;
        esac

        aws s3api get-bucket-lifecycle-configuration --bucket "$S3_BUCKET" \
          --query "Rules[?AbortIncompleteMultipartUpload].ID" --output text 2>/dev/null \
          | grep -q . \
          && pass "stuck multipart uploads get cleaned up" \
          || warn "no AbortIncompleteMultipartUpload rule — a failed 64 MB upload leaves chunks that cost money and don't show in 'aws s3 ls'" \
                  "# see docs/07 Stage C.6a"
      else
        warn "NO lifecycle rules — nothing under k3s/ is ever deleted, so the bucket grows without limit" \
             "# see docs/07 Stage C.6a — two rules: k3s/daily/ expire 8 days,
       # k3s/weekly/ expire 31 days. Nothing on velero/ (Velero uses TTL)."
      fi
    else
      fail "bucket s3://$S3_BUCKET does not exist or is not reachable" \
           "# create it first — docs/07 Stage C.2:
       aws s3api create-bucket --bucket $S3_BUCKET --region $AWS_REGION \\
         --create-bucket-configuration LocationConstraint=$AWS_REGION
       # (us-east-1 is the exception: it rejects --create-bucket-configuration)"
    fi

    # ---- KMS key ------------------------------------------------------
    KSTATE=$(aws kms describe-key --key-id "$KMS_KEY_ID" \
               --query 'KeyMetadata.[KeyState,KeyManager]' --output text 2>/dev/null)
    if [ -n "$KSTATE" ]; then
      pass "KMS key reachable ($KSTATE)"
      case "$KSTATE" in
        *PendingDeletion*) fail "the KMS key is PENDING DELETION — every backup encrypted with it becomes unreadable" \
                                "aws kms cancel-key-deletion --key-id $KMS_KEY_ID" ;;
      esac
    else
      fail "cannot read the KMS key $KMS_KEY_ID — wrong ARN, wrong region, or missing kms:DescribeKey" \
           "aws kms describe-key --key-id $KMS_KEY_ID --region $AWS_REGION"
    fi

    # ---- the upload tests --------------------------------------------
    if [ "$DO_UPLOAD" -eq 1 ]; then
      TMPD=$(mktemp -d)

      # small: single-part. Passes with minimal KMS permissions.
      echo "preflight $(date -u +%FT%TZ)" > "$TMPD/small.txt"
      if aws s3 cp "$TMPD/small.txt" "s3://$S3_BUCKET/_preflight/small.txt" \
           --only-show-errors --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID" 2>"$TMPD/err1"; then
        pass "small upload works (single-part)"
      else
        fail "even a small upload failed: $(head -c 200 "$TMPD/err1")" \
             "# check the IAM policy allows s3:PutObject and kms:GenerateDataKey on this bucket/key"
      fi

      # large: multipart. THIS is the one that catches a missing kms:Decrypt (#21).
      info "building a 64 MB test file to force a multipart upload (this is the check that catches #21)..."
      dd if=/dev/zero of="$TMPD/big.bin" bs=1M count=64 status=none 2>/dev/null
      if aws s3 cp "$TMPD/big.bin" "s3://$S3_BUCKET/_preflight/big.bin" \
           --only-show-errors --sse aws:kms --sse-kms-key-id "$KMS_KEY_ID" 2>"$TMPD/err2"; then
        pass "64 MB multipart upload works — the real datastore upload will succeed"
      else
        fail "multipart (64 MB) upload FAILED while the small one succeeded — this is the missing-kms:Decrypt trap: $(head -c 200 "$TMPD/err2")" \
             "# add kms:Decrypt for this key to the backup login's policy (issue #21):
       #   \"Action\": [\"kms:Encrypt\",\"kms:GenerateDataKey\",\"kms:Decrypt\",\"kms:DescribeKey\"]
       # it does not widen access — the policy already grants s3:GetObject"
      fi

      # guardrail: delete must be refused
      if aws s3api delete-object --bucket "$S3_BUCKET" --key "_preflight/small.txt" >/dev/null 2>&1; then
        warn "this login CAN delete objects — a compromised server could destroy the backups" \
             "# remove s3:DeleteObject from the writer policy (docs/07 Stage C.7)"
      else
        pass "delete is correctly refused for this login"
      fi

      # guardrail: unencrypted put must be refused
      if aws s3api put-object --bucket "$S3_BUCKET" --key "_preflight/plain.txt" \
           --body "$TMPD/small.txt" >/dev/null 2>&1; then
        warn "an UNENCRYPTED upload was accepted — the deny-unencrypted policy is not working" \
             "# see docs/07 Stage C.6"
      else
        pass "unencrypted uploads are correctly refused"
      fi

      info "test objects left at s3://$S3_BUCKET/_preflight/ (this login cannot delete them —"
      info "remove with an admin login, or let a lifecycle rule expire that prefix)"
      rm -rf "$TMPD"
    else
      info "upload tests skipped (--no-upload) — note this leaves #21 unverified"
    fi
  fi
fi

# ===========================================================================
section "D. K3s data the backup will read"
# ===========================================================================

check_path() {
  local p="$1" what="$2"
  if [ -e "$p" ]; then pass "$what exists: $p"; else
    fail "$what MISSING: $p" "ls -la $(dirname "$p")"; fi
}

check_path "$K3S_SERVER_DIR/db/state.db"  "datastore"
check_path "$K3S_SERVER_DIR/tls"          "certificates folder"
check_path "$K3S_SERVER_DIR/cred"         "join credentials folder"
check_path "$K3S_SERVER_DIR/token"        "server token"
check_path "$K3S_SERVER_DIR/manifests"    "built-in setup files"
check_path "/etc/rancher/k3s"             "k3s config folder"

if [ -e "$K3S_SERVER_DIR/token" ]; then
  TPERM=$(stat -c '%a %U:%G' "$K3S_SERVER_DIR/token" 2>/dev/null)
  if [ "$TPERM" = "600 root:root" ]; then
    pass "token permissions are 600 root:root"
  else
    warn "token permissions are '$TPERM', expected '600 root:root'" \
         "chmod 600 $K3S_SERVER_DIR/token"
  fi
fi

# datastore readable, and a genuine integrity check — read-only, no writes
if [ -r "$K3S_SERVER_DIR/db/state.db" ]; then
  DBSZ=$(du -h "$K3S_SERVER_DIR/db/state.db" 2>/dev/null | awk '{print $1}')
  RES=$(python3 - "$K3S_SERVER_DIR/db/state.db" 2>&1 <<'PY'
import sqlite3, sys
try:
    c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True, timeout=20)
    mode = "read-only"
except sqlite3.OperationalError:
    c = sqlite3.connect(sys.argv[1], timeout=20); c.execute("PRAGMA query_only = ON")
    mode = "query_only fallback"
try:
    ic = c.execute("PRAGMA integrity_check").fetchone()[0]
    n  = c.execute("SELECT count(*) FROM kine").fetchone()[0]
    print(f"{ic}|{n}|{mode}")
except Exception as e:
    print(f"ERROR|{e}|{mode}")
finally:
    c.close()
PY
)
  IC=${RES%%|*}; REST=${RES#*|}; ROWS=${REST%%|*}; MODE=${REST##*|}
  if [ "$IC" = "ok" ]; then
    pass "datastore readable ($DBSZ), integrity ok, ${ROWS} rows, opened $MODE"
    [ "$MODE" != "read-only" ] && warn "datastore opened via $MODE rather than true read-only — still safe, but note it" ""
  else
    fail "datastore integrity check did not return ok: $RES" \
         "# do NOT back this up as good. Investigate before relying on it."
  fi

  [ -e "$K3S_SERVER_DIR/db/state.db-wal" ] \
    && pass "WAL file present (normal for a running cluster)" \
    || warn "no -wal file — unusual while k3s is running; confirm k3s is actually up" ""
fi

if systemctl is-active --quiet k3s 2>/dev/null; then
  pass "k3s service is active"
else
  warn "k3s service is not active — backups still work, and are arguably more consistent, but confirm this is intentional" ""
fi

# secrets-encryption: changes how critical cred/ is
if [ -e "$K3S_SERVER_DIR/cred/encryption-config.json" ]; then
  warn "secrets-encryption appears ENABLED (cred/encryption-config.json exists) — without that file every Secret in a restored database is unreadable. It IS backed up inside cred/, but a restore must confirm it landed." \
       "sudo k3s secrets-encrypt status"
else
  pass "no encryption-config.json — Secrets are not separately encrypted in the datastore"
fi

# #22 — is anything actually reading the success metric?
TFD=${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}
if [ -d "$TFD" ]; then
  pass "node_exporter textfile directory exists ($TFD) — the success metric will be picked up"
else
  warn "no textfile directory at $TFD — the 'backup succeeded' metric is written nowhere, so failure alerting would be silent (issue #22)" \
       "# find out what node_exporter actually is here:
       systemctl list-units --all | grep -i node.exporter
       k3s kubectl get ds,deploy -A | grep -i node-exporter
       # then set TEXTFILE_DIR in $ENV_FILE, or alert on S3 object age instead"
fi

# ===========================================================================
section "E. What is running, namespace by namespace"
# ===========================================================================

if [ ! -x "$K3S_BIN" ] || [ ! -r "$KUBECONFIG_PATH" ]; then
  warn "cannot reach the cluster API — skipping the namespace inventory" ""
else
  INV=$(mktemp)
  if KUBECONFIG=$KUBECONFIG_PATH "$K3S_BIN" kubectl get \
        deploy,statefulset,daemonset,svc,configmap,secret,pvc,ingress \
        -A -o json > "$INV" 2>/dev/null; then

    python3 - "$INV" <<'PY'
import json, sys
from collections import defaultdict

data = json.load(open(sys.argv[1]))
ns = defaultdict(lambda: defaultdict(int))
pvc_size = defaultdict(list)

KIND = {
    "Deployment": "deploy", "StatefulSet": "sts", "DaemonSet": "ds",
    "Service": "svc", "ConfigMap": "cm", "Secret": "secret",
    "PersistentVolumeClaim": "pvc", "Ingress": "ing",
}

for item in data.get("items", []):
    k = KIND.get(item.get("kind", ""))
    if not k:
        continue
    n = item["metadata"].get("namespace", "-")
    ns[n][k] += 1
    if k == "pvc":
        cap = item.get("status", {}).get("capacity", {}).get("storage", "?")
        pvc_size[n].append(f'{item["metadata"]["name"]} ({cap})')

hdr = f'  {"NAMESPACE":<22}{"deploy":>7}{"sts":>5}{"ds":>4}{"svc":>5}{"cm":>5}{"secret":>8}{"pvc":>5}{"ing":>5}'
print(hdr)
print("  " + "-" * (len(hdr) - 2))

tot = defaultdict(int)
for n in sorted(ns):
    r = ns[n]
    for k, v in r.items():
        tot[k] += v
    print(f'  {n:<22}{r["deploy"]:>7}{r["sts"]:>5}{r["ds"]:>4}'
          f'{r["svc"]:>5}{r["cm"]:>5}{r["secret"]:>8}{r["pvc"]:>5}{r["ing"]:>5}')

print("  " + "-" * (len(hdr) - 2))
print(f'  {"TOTAL":<22}{tot["deploy"]:>7}{tot["sts"]:>5}{tot["ds"]:>4}'
      f'{tot["svc"]:>5}{tot["cm"]:>5}{tot["secret"]:>8}{tot["pvc"]:>5}{tot["ing"]:>5}')

print()
print("  Namespaces holding data on disk (PVCs) — this is what is most at risk:")
if pvc_size:
    for n in sorted(pvc_size):
        print(f"    {n}:")
        for p in sorted(pvc_size[n]):
            print(f"      - {p}")
else:
    print("    (none found)")

print()
print(f"  Secrets across all namespaces: {tot['secret']}")
print("    These include TLS certificates, registry logins and app credentials.")
PY
  else
    warn "could not query the cluster for a namespace inventory" ""
  fi
  rm -f "$INV"
fi

# ===========================================================================
section "F. Coverage — what today's backup does NOT recover"
# ===========================================================================

cat <<'EOF'
  Job 1 — k3s-server-backup.sh — covers:

    [x] K3s datastore (state.db)       -> rebuilds THIS server
    [x] Cluster identity (tls/, cred/) -> certificate authority and join key
    [x] Server token                   -> unlocks the datastore's bootstrap data
    [x] K3s config + systemd unit      -> including --tls-san and start flags
    [x] Built-in setup files (manifests/)
    [x] Host OS settings               -> network, firewall, ssh, packages
    [x] MANIFEST.json                  -> which k3s version made this backup

  Job 2 — Velero — covers everything Job 1 cannot:

    [ ] PVC data (the volumes listed in section E)
          Job 1 does NOT back up their contents. Without Velero, a restore
          brings the monitoring stack back EMPTY. Issue #11.

    [ ] Restoring a single deleted object
          Without Velero there is no way to put back one Deployment or
          Secret — the only lever is rolling the whole datastore back, which
          reverts everything else too. Issue #11.

    [ ] Restoring into a fresh or different-version cluster
          The datastore snapshot only helps when rebuilding THIS server at
          THIS k3s version. Issue #11.

  If Velero is not installed yet, everything under Job 2 is uncovered today.

  Reminder about the storage: the local-path reclaim policy is Delete, so
  deleting a PVC destroys its data immediately — no grace period, nothing to
  recover from. Until Velero exists, an accidental `kubectl delete pvc` is
  permanent.
EOF

# ===========================================================================
section "SUMMARY"
# ===========================================================================

printf '  %spassed: %d%s   %swarnings: %d%s   %sfailures: %d%s\n' \
  "$c_grn" "$PASSES" "$c_off" "$c_yel" "$WARNS" "$c_off" "$c_red" "$FAILS" "$c_off"

if [ "${#REMEDIES[@]}" -gt 0 ]; then
  printf '\n%sThings to fix, and how:%s\n' "$c_bold" "$c_off"
  i=1
  for r in "${REMEDIES[@]}"; do
    lvl=${r%%|*}; rest=${r#*|}; msg=${rest%%|*}; cmd=${rest#*|}
    [ -z "$cmd" ] && continue
    col=$c_yel; [ "$lvl" = "FAIL" ] && col=$c_red
    printf '\n  %s%d. [%s]%s %s\n' "$col" "$i" "$lvl" "$c_off" "$msg"
    # strip the source indentation first, then apply one uniform indent, so
    # multi-line remediation blocks line up instead of stair-stepping
    printf '%s\n' "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/^/       /'
    i=$((i+1))
  done
fi

echo
if [ "$FAILS" -gt 0 ]; then
  printf '  %sNOT READY%s — fix the failures above, then run this again.\n' "$c_red" "$c_off"
  printf '  Do not run the backup script until this comes back clean.\n'
  exit 1
elif [ "$WARNS" -gt 0 ]; then
  printf '  %sREADY, with warnings%s — safe to run the backup. Read the warnings first;\n' "$c_yel" "$c_off"
  printf '  some of them (especially #22) mean a failure could go unnoticed later.\n'
  exit 2
else
  printf '  %sREADY%s — everything checks out. Next step:\n' "$c_grn" "$c_off"
  printf '    sudo DRY_RUN=1 /usr/local/sbin/k3s-server-backup.sh\n'
  exit 0
fi
