# 06 — Developer Access Setup

This explains how a new developer can clone and push to this private repo, using the special SSH
key they were given.

> **This document never contains the actual key itself, and never should.** The private key file
> gets sent to you separately. See [Handover](#handover-for-whoever-is-issuing-a-new-key-to-someone) at the bottom
> if you're the one issuing a key to someone else.

---

## What you've been given

| Property | Value |
|----------|-------|
| Type | A GitHub **deploy key** — this only works for one specific repo |
| Type of key | ed25519 (a modern, secure key type) |
| What it can do | **Both read and write** — you can clone, pull, and push |
| Which repo it works for | `bsarkarlabs-stack/k3-backup` **only** |
| Its name in GitHub | `new-developer-laptop` |
| Its fingerprint | `SHA256:u8XvXUOFuZh/dwX/xg9L+x0TwvyUVM/zY4ZE8p97bl4` |

**What this key is NOT:** it's not a GitHub account, and it doesn't give you access to any other
repo, team, or setting. It can't open GitHub issues or review pull requests — for that, you'd
need an actual GitHub account added as a collaborator.

---

## Setup steps

### 1. Save the private key file

You'll receive a file called `k3_backup_deploy`. Put it in your `~/.ssh/` folder and lock down its
permissions — **SSH will refuse to use a key if other users on your computer can read it.**

**On Linux / macOS / WSL**

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
mv /path/to/k3_backup_deploy ~/.ssh/k3_backup_deploy
chmod 600 ~/.ssh/k3_backup_deploy
```

**On Windows (PowerShell)**

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.ssh"
Move-Item .\k3_backup_deploy "$env:USERPROFILE\.ssh\k3_backup_deploy"
icacls "$env:USERPROFILE\.ssh\k3_backup_deploy" /inheritance:r /grant:r "$($env:USERNAME):(R)"
```

### 2. Double-check you got the right key

Make sure the key you received matches, and wasn't corrupted in transit:

```bash
ssh-keygen -lf ~/.ssh/k3_backup_deploy
```

You should see:

```text
256 SHA256:u8XvXUOFuZh/dwX/xg9L+x0TwvyUVM/zY4ZE8p97bl4 k3-backup-deploy-newdev (ED25519)
```

If this doesn't match what's listed above, **stop and report it** — don't use the key.

### 3. Set up SSH to use this key for this repo

Add this to your `~/.ssh/config` file (create the file if you don't have one, and run
`chmod 600` on it):

```sshconfig
Host github-k3backup
    HostName github.com
    User git
    IdentityFile ~/.ssh/k3_backup_deploy
    IdentitiesOnly yes
```

The `IdentitiesOnly yes` line matters — without it, SSH would try offering GitHub every key you
own, and GitHub might reject the connection before it even gets to try this one.

The `Host github-k3backup` name we made up here just keeps this key separate from any other
GitHub account or repo you might already use on this same computer.

### 4. Test that it works

```bash
ssh -T git@github-k3backup
```

You should see:

```text
Hi bsarkarlabs-stack/k3-backup! You've successfully authenticated,
but GitHub does not provide shell access.
```

> That message is actually **success** — GitHub never gives you a real shell over SSH, so that
> part of the message is normal and expected.

### 5. Clone the repo

```bash
git clone github-k3backup:bsarkarlabs-stack/k3-backup.git
cd k3-backup
```

Notice we're using the made-up name (`github-k3backup`) from your SSH config, not `github.com`
directly.

### 6. Set your name and email for commits

The deploy key only proves *which computer* is connecting — it doesn't know *who you are*.
Without this step, your commits would show whatever name/email your computer's git is already
set to globally.

```bash
git config user.name  "Your Name"
git config user.email "you@example.com"
```

---

## Everyday usage

```bash
git pull
# ...make your changes...
git add -A
git commit -m "Describe the change"
git push
```

If you already cloned this repo using the regular HTTPS method and want to switch to using this
key instead:

```bash
git remote set-url origin github-k3backup:bsarkarlabs-stack/k3-backup.git
git remote -v
```

---

## If something goes wrong

| What you see | Why | How to fix it |
|---------|-------|-----|
| `Permission denied (publickey)` | Wrong key was offered, or `IdentitiesOnly` is missing from your config | Run `ssh -v -T git@github-k3backup` and check which key it's actually trying to use |
| `UNPROTECTED PRIVATE KEY FILE` | The key file's permissions are too open | Run `chmod 600 ~/.ssh/k3_backup_deploy` |
| `Repository not found` | The key itself is fine, but it's scoped to a different repo | Double-check the fingerprint matches step 2 above |
| Push gets rejected as read-only | The key was set up without write access | Report this — the key is supposed to allow both read and write |
| Works for this repo, but breaks a different one | The key is being offered to GitHub for every connection, not just this one | Make sure you're using the `Host` alias, and don't put this key as your global default `IdentityFile` |

---

## A few ground rules

1. **Never send this key to anyone else.** If someone else needs access, they should get their
   own separate key — otherwise there's no way to tell who actually did what.
2. **Never commit the key file into this repo.** The `.gitignore` file blocks the common
   filenames as a safety net, but don't rely on that alone — just never do it.
3. **Report immediately if your laptop is lost or exposed**, so the key can be revoked right
   away. Revoking a key is instant, and only affects that one key.
4. **This repo documents how to recover a production server.** It contains real server IP
   addresses, folder paths, and how our system is laid out. Treat it as confidential — it must
   never become public.
5. **Never paste real secrets into these docs** — no actual token values, no certificate
   contents, no AWS keys. It's fine to write down *where* a secret lives, just never *what it
   actually is*.

---

## Handover (for whoever is issuing a new key to someone)

Send the private key file over a channel that's end-to-end encrypted and doesn't keep a
permanent history:

- ✅ A password manager's secure-share feature with an expiry date (like Bitwarden Send or
  1Password)
- ✅ Handed over in person, on a USB drive
- ❌ Email, Slack, WhatsApp, SMS, or any ticketing system — these all keep permanent copies

After the new developer confirms the fingerprint matches, delete your own copy of the private
key.

### Revoking someone's access

```bash
gh repo deploy-key list -R bsarkarlabs-stack/k3-backup
gh repo deploy-key delete <KEY_ID> -R bsarkarlabs-stack/k3-backup
```

This takes effect immediately, and only affects that one specific key.

### When to rotate keys

Deploy keys don't expire on their own — they stay valid forever unless removed. Rotate this key
whenever the developer who has it leaves, if their device is lost, or at least every 12 months —
whichever happens first. This is the same rule we follow for the backup login credentials, see
[gap #16](../../issues/16).
