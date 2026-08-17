# 05 — Gaps & Open Questions

Not established by the [discovery baseline](01-discovery-baseline.md), and **not safe to assume
away**. Each gap has a GitHub Issue.

| # | Gap | Severity | Blocks | Issue |
|---|-----|----------|--------|-------|
| 1 | Hosting provider unconfirmed | Medium | Snapshot fallback planning | [#8](../../issues/8) |
| 2 | Ingress TLS certificate source unverified | **High** | Clean restore | [#9](../../issues/9) |
| 3 | Node-level OS configuration not captured | **High** | Runbook step 2 | [#10](../../issues/10) |
| 4 | OS package list not captured | Low | Fast parity on fresh server | [#11](../../issues/11) |
| 5 | Secrets reach S3 unencrypted unless SSE-KMS is set | **Critical** | Phase 2 | [#12](../../issues/12) |
| 6 | Single-region S3, no replication | Medium | Regional-outage DR | [#13](../../issues/13) |
| 7 | Documentation as a single point of failure | Medium | — *(resolved by this repo)* | [#14](../../issues/14) |
| 8 | No named owner for credential rotation | Medium | Ongoing security posture | [#15](../../issues/15) |
| 9 | `server/tls/` and `server/cred/` contents never enumerated | **High** | Restore confidence | [#16](../../issues/16) |

---

## 1. Hosting provider unconfirmed

The AWS EC2 metadata probe returned `AWS EC2 metadata not available`. The AWS CLI being installed
does **not** imply the server runs on AWS.

**Why it matters:** no hypervisor-level snapshot fallback can be planned until the platform is
known. A provider snapshot is not a substitute for this backup design, but it is a valuable
extra layer — and it is free on some platforms.

**To resolve:** identify the provider from billing, the control panel, or DMI/SMBIOS data.

---

## 2. Ingress TLS certificate source unverified

**Severity: High.**

No cert-manager was observed during discovery. It is therefore unclear whether Traefik's
certificates are:

- manually placed as Kubernetes Secrets (→ captured by Velero, component 7), or
- issued via Traefik's own ACME resolver (→ stored in an `acme.json` that may sit on a PVC or in
  ephemeral pod storage), or
- terminated somewhere upstream entirely

**Why it matters:** each case has a completely different backup requirement. If ACME state lives
in ephemeral storage, it is currently **not backed up by any component in the plan** — and a
restore would silently produce an ingress with no valid certificate.

**To resolve:** inspect the Traefik deployment for an ACME configuration and locate where
`acme.json` is persisted.

---

## 3. Node-level OS configuration not captured

**Severity: High.** This is [runbook step 2](03-restore-runbook.md#step-2--restore-node-level-os-configuration),
and it currently has nothing behind it.

Not in the discovery baseline:

- Netplan / network configuration for the static IPs (`45.90.98.51`, `10.10.10.103`)
- UFW / firewall rules
- SSH host keys and `authorized_keys`
- NTP and timezone configuration
- Any systemd overrides beyond the K3s unit

**Why it matters:** without these, restore step 2 is manual reconstruction from memory during an
outage — exactly when reconstruction from memory is least reliable.

**To resolve:** covered by [Phase 1](04-implementation-todo.md#phase-1--node--cluster-state-backup-track-a)
via the `node-config/` prefix.

---

## 4. OS package list not captured

`dpkg --get-selections` would let a fresh server reach parity quickly, beyond just the four tools
confirmed present (`rsync`, `aws`, `tar`, `gzip`).

**Why it matters:** minor — but it shortens the outage window for essentially zero storage cost.

**To resolve:** add to the Phase 1 `node-config/` capture.

---

## 5. Secrets reach S3 unencrypted unless SSE-KMS is configured

**Severity: Critical.**

A Velero backup is, among other things, **a bundle of live Kubernetes Secrets in plaintext** —
`imagePullSecrets`, ingress TLS keys, ArgoCD repository credentials, application secrets. The
`server-identity/` prefix likewise contains the cluster CA and the server token.

**Why it matters:** without SSE-KMS and tight IAM, the backup bucket becomes a higher-value target
than the server it protects. This is load-bearing configuration, not optional hardening.

**To resolve:** [Phase 0](04-implementation-todo.md#phase-0--foundations) — bucket must be created
encrypted from the start. Do not create it first and encrypt it later; default encryption does not
retroactively apply to existing objects.

---

## 6. Single-region S3, no cross-region replication

Reasonable given a single-node, no-HA cluster — the cluster itself is a larger single point of
failure than the region.

**Why it matters:** it should be a **stated decision**, not a default nobody chose.

**To resolve:** decide explicitly in [Phase 6](04-implementation-todo.md#phase-6--close-known-gaps)
and record the reasoning here.

---

## 7. Documentation as a single point of failure

If this documentation lives only on `k3-master`, it disappears in exactly the scenario it exists
to solve.

**Status: resolved by this repository** — it is now the canonical copy. The remaining discipline
is to keep it updated here rather than editing a copy on the server.

---

## 8. No named owner for credential rotation

The IAM keys the backup scripts use need a rotation cadence and a person accountable for it.

**Why it matters:** long-lived, unrotated credentials with write access to the DR bucket are a
standing risk — and the bucket contains the cluster CA.

**To resolve:** assign an owner and a cadence (suggested: 90 days) in Phase 6.

---

## 9. `server/tls/` and `server/cred/` contents never enumerated

**Severity: High.**

The [backup strategy](02-backup-strategy.md#2-the-correction-that-changes-the-whole-plan)
identifies these directories as P0-critical, but discovery never listed what is actually inside
them on this specific server.

**Why it matters:** the backup design is correct in principle, but has not been validated against
this host's actual contents. There may be additional files — or a non-default layout — that the
`tar` job would miss.

**To resolve:** enumerate both directories (filenames and permissions only — **never contents**)
and confirm the Phase 1 archive covers everything present.

---

## Adding a gap

When a new gap is found:

1. Add a row to the table at the top
2. Add a section below with **why it matters** and **how to resolve** — not just what is missing
3. Open a GitHub Issue and link it in the table
