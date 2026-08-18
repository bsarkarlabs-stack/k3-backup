# 05 — Gaps & Open Questions

Not established by the [discovery baseline](01-discovery-baseline.md), and **not safe to assume
away**. Each gap has a GitHub Issue.

| # | Gap | Severity | Blocks | Issue |
|---|-----|----------|--------|-------|
| 1 | ~~Hosting provider unconfirmed~~ → **Datalix, on-premise, no snapshot fallback** | ✅ Resolved — but raises severity elsewhere | — | [#13](../../issues/13) |
| 2 | Ingress TLS certificate source unverified | **High** | Clean restore | [#4](../../issues/4) |
| 3 | Node-level OS configuration not captured | **High** | Runbook step 2 | [#5](../../issues/5) |
| 4 | OS package list not captured | Low | Fast parity on fresh server | [#6](../../issues/6) |
| 5 | Secrets reach S3 unencrypted unless SSE-KMS is set | **Critical** | Phase 2 | [#14](../../issues/14) |
| 6 | Single-region S3, no replication | Medium | Regional-outage DR | [#15](../../issues/15) |
| 7 | Documentation as a single point of failure | Medium | — *(resolved by this repo)* | [#7](../../issues/7) |
| 8 | No named owner for credential rotation | Medium | Ongoing security posture | [#16](../../issues/16) |
| 9 | `server/tls/` and `server/cred/` contents never enumerated | **High** | Restore confidence | [#8](../../issues/8) |

---

## 1. Hosting provider — **RESOLVED: Datalix, treated as on-premise**

Confirmed by the operator. The server is hosted with **Datalix** on a public IP and is to be
treated as an **on-premise / bare-metal** machine. **No hypervisor-level snapshot or provider
backup is available.**

**Why this closes as a gap but makes everything else worse:**

There is no fallback layer. On a cloud provider, a botched restore still leaves you a VM snapshot
to roll back to. Here there is nothing behind the S3 backup set — it is the entire recovery
story, not the first of two.

Concretely, this raises the priority of three things:

| Consequence | Where |
|-------------|-------|
| Phase 2 (Velero + PVC data) stops being "next" and becomes the thing standing between you and unrecoverable data loss | [04, Phase 2](04-implementation-todo.md#phase-2--kubernetes-level-backup-track-b) |
| The restore drill is the only way you will ever find out whether recovery works, because there is no snapshot to fall back on when it doesn't | [04, Phase 5](04-implementation-todo.md#phase-5--restore-validation) |
| Single-region S3 (gap 6) is now a *single copy of the only recovery path*, not a second copy | [gap 6](#6-single-region-s3-no-cross-region-replication) |

> Hardware failure on an on-premise box also means **procurement time** is part of your RTO. A
> cloud VM is replaced in minutes; a physical server may not be. Factor this into the RTO recorded
> in Phase 5 — the restore procedure is only part of the outage.

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

The original reasoning was: reasonable given a single-node, no-HA cluster — the cluster itself is a
larger single point of failure than the region.

**That reasoning is now weaker.** With [gap 1](#1-hosting-provider--resolved-datalix-treated-as-on-premise)
resolved as *on-premise with no snapshot fallback*, the S3 bucket is not a second copy of your
recovery path — it **is** your recovery path, in one region, in one account.

**Why it matters:** it should be a **stated decision**, not a default nobody chose. The cheap
middle ground, if full cross-region replication is overkill, is a periodic offline copy of the
`cluster-state/` prefix pulled with the restore-reader credential and kept somewhere outside AWS.

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
