# 06 — Developer Access Setup

How a new developer clones and pushes to this private repository using the issued SSH deploy key.

> **This document contains no key material and never should.** The private key is delivered
> separately. See [Handover](#handover-for-whoever-issues-the-key) at the bottom.

---

## What you have been issued

| Property | Value |
|----------|-------|
| Type | GitHub **deploy key** (repository-scoped) |
| Algorithm | ed25519 |
| Access | **Read + write** — you can clone, pull, and push |
| Scope | `bsarkarlabs-stack/k3-backup` **only** |
| Title in GitHub | `new-developer-laptop` |
| Fingerprint | `SHA256:u8XvXUOFuZh/dwX/xg9L+x0TwvyUVM/zY4ZE8p97bl4` |

**What this key is not:** it is not a GitHub account and grants no access to any other repository,
organisation, or setting. It cannot open issues or review pull requests — for that you need a
GitHub account added as a collaborator.

---

## Setup

### 1. Place the private key

You will receive a file named `k3_backup_deploy`. Put it in `~/.ssh/` and lock down its
permissions — **SSH refuses to use a key that other users can read.**

**Linux / macOS / WSL**

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
mv /path/to/k3_backup_deploy ~/.ssh/k3_backup_deploy
chmod 600 ~/.ssh/k3_backup_deploy
```

**Windows (PowerShell)**

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh"
Move-Item .\k3_backup_deploy "$env:USERPROFILE\.ssh\k3_backup_deploy"
icacls "$env:USERPROFILE\.ssh\k3_backup_deploy" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

### 2. Verify the fingerprint

Confirm you received the right key, uncorrupted:

```bash
ssh-keygen -lf ~/.ssh/k3_backup_deploy
```

Expected output:

```text
256 SHA256:u8XvXUOFuZh/dwX/xg9L+x0TwvyUVM/zY4ZE8p97bl4 k3-backup-deploy-newdev (ED25519)
```

If the fingerprint does not match, **stop** and report it — do not use the key.

### 3. Configure SSH

Add this block to `~/.ssh/config` (create the file if it does not exist; `chmod 600` it):

```sshconfig
Host github-k3backup
    HostName github.com
    User git
    IdentityFile ~/.ssh/k3_backup_deploy
    IdentitiesOnly yes
```

`IdentitiesOnly yes` matters — without it SSH offers every key you own and GitHub may reject the
connection before reaching this one.

The `Host github-k3backup` alias keeps this key from interfering with any other GitHub account or
repo you already use.

### 4. Test authentication

```bash
ssh -T git@github-k3backup
```

Expected:

```text
Hi bsarkarlabs-stack/k3-backup! You've successfully authenticated,
but GitHub does not provide shell access.
```

> That message is a **success**. GitHub never provides shell access over SSH.

### 5. Clone

```bash
git clone github-k3backup:bsarkarlabs-stack/k3-backup.git
cd k3-backup
```

Note the URL uses the alias from your SSH config, not `github.com`.

### 6. Set your commit identity

The deploy key authenticates the *machine*, not you — commits will otherwise carry whatever
identity your global git config holds.

```bash
git config user.name  "Your Name"
git config user.email "you@example.com"
```

---

## Daily use

```bash
git pull
# ...edit...
git add -A
git commit -m "Describe the change"
git push
```

If you already cloned over HTTPS and want to switch this checkout to the key:

```bash
git remote set-url origin github-k3backup:bsarkarlabs-stack/k3-backup.git
git remote -v
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Permission denied (publickey)` | Wrong key offered, or `IdentitiesOnly` missing | Test with `ssh -v -T git@github-k3backup` and check which key is offered |
| `UNPROTECTED PRIVATE KEY FILE` | Permissions too open | `chmod 600 ~/.ssh/k3_backup_deploy` |
| `Repository not found` | Key is valid but scoped elsewhere | Confirm the fingerprint matches step 2 |
| Push rejected as read-only | Key registered without write access | Report it — the key should be read-write |
| Works for this repo, breaks another | Key being offered globally | Use the `Host` alias; do not put this key in a global `IdentityFile` |

---

## Ground rules

1. **Do not forward this key to anyone.** If someone else needs access, they get their own key —
   otherwise nothing in the audit trail distinguishes you from them.
2. **Do not commit key material to this repo.** `.gitignore` blocks the common filenames, but it
   is a safety net, not a guarantee.
3. **Report a lost or exposed laptop immediately** so the key can be revoked. Revocation is
   instant and affects only this key.
4. **This repo documents recovery for a production cluster.** It contains server IPs, filesystem
   paths, and topology. Treat it as confidential; it must never become public.
5. **Never paste real secrets into these docs** — no token contents, no certificate bodies, no
   IAM keys. Document *where* a secret lives, never *what it is*.

---

## Handover (for whoever issues the key)

Transmit the private key over a channel that is end-to-end encrypted and does not retain history:

- ✅ A password manager's secure-share feature with an expiry (Bitwarden Send, 1Password)
- ✅ In person, on removable media
- ❌ Email, Slack, WhatsApp, SMS, or any ticketing system — these retain copies indefinitely

After the developer confirms the fingerprint matches, delete your copy of the private key.

### Revoking access

```bash
gh repo deploy-key list -R bsarkarlabs-stack/k3-backup
gh repo deploy-key delete <KEY_ID> -R bsarkarlabs-stack/k3-backup
```

Revocation takes effect immediately and affects only this key.

### Rotation

Deploy keys do not expire on their own. Rotate this one when the developer leaves, when a device
is lost, or every 12 months — whichever comes first. This is the same discipline tracked for the
backup IAM credentials in [#16](../../issues/16).
