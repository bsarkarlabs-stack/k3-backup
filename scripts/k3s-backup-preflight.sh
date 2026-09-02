#!/usr/bin/env bash
#
# k3s-backup-preflight.sh — check everything before the first real backup runs.
#
#   Usage:  sudo ./k3s-backup-preflight.sh              # full check
#           sudo ./k3s-backup-preflight.sh --no-aws     # local checks only
#           sudo ./k3s-backup-preflight.sh --no-upload  # AWS checks, no test object
#
# This script CHANGES NOTHING on the cluster. Against K3s it is strictly
# read-only: it never starts, stops or reconfigures anything, never writes
# inside /var/lib/rancher/k3s or /etc/rancher/k3s, and opens the datastore
# read-only. The only thing it writes anywhere is one small throwaway object
# in S3 under _preflight/ with a fixed key, so repeat runs overwrite it.
#
# It answers five questions, in order:
#
#   A. Can this box run the backup at all?
#   B. Is the config file present and correct?
#   C. Does the backup credential work, and is it as narrow as it should be?
#      Bucket *settings* (versioning, encryption, lifecycle) are deliberately
#      not checked here — this credential cannot read them, and it should not
#      be able to. They are verified once at setup with an admin login;
#      see docs/07-setup.md stage 2.
#   D. Is every file the backup reads actually there?
#   E. What is running, and what of it would NOT be recovered today?
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

for t in aws tar gzip python3 flock sha256sum curl openssl; do
  if command -v "$t" >/dev/null 2>&1; then
    pass "$t present"
  else
    case "$t" in
      aws)     fail "$t missing — required to upload backups" "apt-get install -y awscli  # or the official AWS CLI v2 installer" ;;
      curl)    warn "$t missing — only needed for the backup heartbeat" "apt-get install -y curl" ;;
      openssl) warn "$t missing — only needed to read certificate expiry dates" "apt-get install -y openssl" ;;
      *)       fail "$t missing — required by the backup script" "apt-get install -y $t" ;;
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

  for v in S3_BUCKET AWS_REGION; do
    if [ -n "${!v:-}" ]; then pass "$v is set"; else
      fail "$v is not set in $ENV_FILE" "echo '$v=...' >> $ENV_FILE"; CFG_OK=0
    fi
  done

  for v in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [ -n "${!v:-}" ]; then pass "$v is set"; else
      warn "$v not set in the config — fine only if this server uses an instance role" ""
    fi
  done

  # The one alert that survives this server dying. Everything in-cluster
  # (Prometheus, Alertmanager) goes down with it.
  if [ -n "${HEARTBEAT_URL:-}" ]; then
    pass "HEARTBEAT_URL is set — a missed backup will be noticed off this server"
  else
    warn "HEARTBEAT_URL is not set — if backups stop, nothing outside this server will notice" \
         "# pick a dead-man's-switch endpoint (docs/02-backup-strategy.md §7), then:
       echo 'HEARTBEAT_URL=https://...' >> $ENV_FILE"
  fi

  case "${KMS_KEY_ID:-}" in
    "") : ;;
    *)  warn "KMS_KEY_ID is still set in $ENV_FILE — the design now uses SSE-S3 and ignores it" \
             "# remove the KMS_KEY_ID line from $ENV_FILE (docs/02-backup-strategy.md §3)" ;;
  esac
else
  fail "config file missing: $ENV_FILE" \
       "sudo install -d -m 0700 -o root -g root /etc/k3s-backup
       sudo install -m 0600 -o root -g root /dev/null $ENV_FILE
       # then add: S3_BUCKET, AWS_REGION, AWS_ACCESS_KEY_ID,
       #           AWS_SECRET_ACCESS_KEY, HEARTBEAT_URL"
  CFG_OK=0
fi

# ===========================================================================
section "C. The backup credential"
# ===========================================================================

if [ "$DO_AWS" -eq 0 ]; then
  info "skipped (--no-aws)"
elif [ "$CFG_OK" -eq 0 ]; then
  warn "skipping AWS checks — fix the configuration above first" ""
else
  export AWS_DEFAULT_REGION="$AWS_REGION"

  if WHO=$(aws sts get-caller-identity --query Arn --output text 2>&1) && [ -n "$WHO" ]; then
    pass "AWS login works: $WHO"
  else
    fail "AWS login failed — check the keys in $ENV_FILE" \
         "aws sts get-caller-identity   # run with the same env to see the error"
    WHO=""
  fi

  if [ -n "$WHO" ]; then
    if aws s3api list-objects-v2 --bucket "$S3_BUCKET" --max-items 1 >/dev/null 2>&1; then
      pass "bucket is reachable and listable: s3://$S3_BUCKET"
    else
      fail "cannot list s3://$S3_BUCKET — wrong bucket name, wrong region, or no s3:ListBucket" \
           "aws s3api list-objects-v2 --bucket $S3_BUCKET --max-items 1
       # the bucket itself is created at setup — docs/07-setup.md stage 2"
    fi

    if [ "$DO_UPLOAD" -eq 1 ]; then
      TMPD=$(mktemp -d)
      PROBE=_preflight/probe.txt
      echo "preflight $(date -u +%FT%TZ)" > "$TMPD/probe.txt"

      if aws s3 cp "$TMPD/probe.txt" "s3://$S3_BUCKET/$PROBE" \
           --only-show-errors 2>"$TMPD/err"; then
        pass "upload works, and S3 encrypted it on arrival (bucket default SSE-S3)"

        # The backup verifies its own uploads this way, so prove it works here.
        SZ=$(aws s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$PROBE" \
               --query "Contents[?Key=='$PROBE'].Size | [0]" --output text 2>/dev/null)
        if [ "$SZ" = "$(stat -c %s "$TMPD/probe.txt")" ]; then
          pass "uploads can be verified by listing — this is how the backup confirms itself"
        else
          fail "could not confirm the uploaded object by listing (got '${SZ:-nothing}')" \
               "# the credential needs s3:ListBucket on arn:aws:s3:::$S3_BUCKET"
        fi
      else
        fail "upload failed: $(head -c 200 "$TMPD/err")" \
             "# the credential needs s3:PutObject on arn:aws:s3:::$S3_BUCKET/k3s/*
       # see docs/07-setup.md stage 2"
      fi

      # Guardrail 1: this credential must not be able to READ backups. The
      # archive holds the cluster CA and every Secret, so a compromised server
      # should not be able to download its own history.
      if aws s3api get-object --bucket "$S3_BUCKET" --key "$PROBE" "$TMPD/back.txt" >/dev/null 2>&1; then
        warn "this credential CAN download objects it wrote — a compromised server could read the cluster CA out of S3" \
             "# drop s3:GetObject outside velero/* from the writer policy (docs/07-setup.md stage 2)"
      else
        pass "reading back objects is refused — a compromised server cannot exfiltrate old backups"
      fi

      # Guardrail 2: it must not be able to DELETE outside velero/.
      if aws s3api delete-object --bucket "$S3_BUCKET" --key "$PROBE" >/dev/null 2>&1; then
        warn "this credential CAN delete objects outside velero/ — a compromised server could destroy the backups" \
             "# scope s3:DeleteObject to arn:aws:s3:::$S3_BUCKET/velero/* only, never bucket-wide"
      else
        pass "delete outside velero/ is correctly refused"
      fi

      # Guardrail 3: the opposite — it MUST be able to delete inside velero/,
      # or Velero can never expire a backup and retention silently never happens.
      if aws s3 cp "$TMPD/probe.txt" "s3://$S3_BUCKET/velero/_preflight-permcheck.txt" \
           --only-show-errors 2>/dev/null; then
        if aws s3api delete-object --bucket "$S3_BUCKET" \
             --key "velero/_preflight-permcheck.txt" >/dev/null 2>&1; then
          pass "delete inside velero/ works — Velero can expire its own backups"
        else
          fail "delete inside velero/ is DENIED — Velero can never expire a backup, so retention silently becomes 'keep forever'" \
               "# add s3:DeleteObject on arn:aws:s3:::$S3_BUCKET/velero/* to the writer policy"
        fi
      else
        warn "could not write a test object under velero/ — Velero's own uploads may fail too" \
             "# confirm the writer policy covers s3:PutObject on $S3_BUCKET/velero/*"
      fi

      info "test object left at s3://$S3_BUCKET/$PROBE (this credential cannot delete it —"
      info "the _preflight/ lifecycle rule expires it in 2 days)"
      rm -rf "$TMPD"
    else
      info "upload test skipped (--no-upload)"
    fi

    if [ -n "${HEARTBEAT_URL:-}" ] && command -v curl >/dev/null 2>&1; then
      if curl -fsS -m 15 -o /dev/null "$HEARTBEAT_URL"; then
        pass "heartbeat endpoint accepted a ping"
      else
        fail "the heartbeat endpoint did not accept a ping — alerting would report every backup as missing" \
             "curl -v -m 15 '$HEARTBEAT_URL'"
      fi
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
check_path "/etc/systemd/system/k3s.service" "k3s systemd unit (holds the start flags)"

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
  warn "secrets-encryption appears ENABLED (cred/encryption-config.json exists) — without that file every Secret in a restored database is unreadable. It IS in the backup, but a restore must confirm it landed." \
       "sudo k3s secrets-encrypt status"
else
  pass "no encryption-config.json — Secrets are not separately encrypted in the datastore"
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
  Job 1 — k3s-server-backup.sh — one archive a day, covers:

    [x] K3s datastore (state.db)       -> rebuilds THIS server
    [x] Cluster identity (tls/, cred/) -> certificate authority and join key
    [x] Server token                   -> unlocks the datastore's bootstrap data
    [x] K3s config + systemd unit      -> including --tls-san and the start flags
    [x] Built-in setup files (manifests/)
    [x] Host fact sheet (text)         -> addresses, firewall, packages, timezone
    [x] MANIFEST.json                  -> which k3s version to install
    [x] The k3s binary itself          -> kept once per version under k3s-release/

  Job 2 — Velero — covers everything Job 1 cannot:

    [ ] PVC data (the volumes listed in section E)
          Job 1 does NOT back up their contents. Without Velero, a restore
          brings the monitoring stack back EMPTY.

    [ ] Restoring a single deleted object
          Without Velero there is no way to put back one Deployment or
          Secret — the only lever is rolling the whole datastore back, which
          reverts everything else too.

    [ ] Restoring into a fresh or different-version cluster

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
  printf '  a missing HEARTBEAT_URL in particular means a failure could go unnoticed.\n'
  exit 2
else
  printf '  %sREADY%s — everything checks out. Next step:\n' "$c_grn" "$c_off"
  printf '    sudo DRY_RUN=1 /usr/local/sbin/k3s-server-backup.sh\n'
  exit 0
fi
