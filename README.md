# syncoidsetup

> **DISCLAIMER — WORK IN PROGRESS**
>
> This script is under active development and has **not been fully tested** across all environments.
> It is provided **as-is, without any warranty** of any kind, express or implied.
>
> **Before running:**
> - Review the entire script and understand what it does
> - Back up your SSH keys, `authorized_keys` files, and any ZFS configuration
> - Test in a non-production environment first
> - Ensure you have a recovery path if SSH access is disrupted
>
> The authors accept no responsibility for data loss, locked-out servers, or any other damage resulting from use of this script.

A script to automate SSH key-based authentication setup for [syncoid](https://github.com/jimsalterjrs/sanoid) (ZFS replication). Run it once per site and it handles key generation, local installation, and remote deployment across all your production servers.

## Prerequisites

- `sudo` access on the backup machine
- SSH access (as your admin user) to each production server
- Tailscale installed (optional — used to restrict the SSH key to your backup network)

> `recsyncoid` (backup machine) and `sendsyncoid` (production servers) are created automatically as system accounts if they do not already exist. You will be prompted locally before creation; remote accounts are created without prompting.

## Usage

Run as your **normal user** (not root):

```bash
./syncoidsetup.sh [--site <name>] --remote <host> [--remote <host2> ...]
```

`--site` is optional. When omitted, the backup server's hostname (`hostname -s`) is used — handy when running the same script on multiple backup machines without extra arguments.

```bash
# --site defaults to hostname
./syncoidsetup.sh --remote 192.168.1.10 --remote 192.168.1.11

# Explicit site-name
./syncoidsetup.sh --site homelab --remote 192.168.1.10 --remote 192.168.1.11

# Override source-IP restriction (skip Tailscale auto-detection)
BACKUP_IP=100.64.0.5 ./syncoidsetup.sh --remote 192.168.1.10
```

The script will prompt for your sudo password once and keep the ticket alive for up to ~500 s (self-terminating keepalive). It also validates all inputs and checks SSH connectivity to every production server before modifying anything locally.

## What it does

1. Generates an ed25519 keypair at `~/.ssh/id_ed25519_<site-name>_syncoid` (skipped if already present)
2. Creates `recsyncoid` locally if absent (prompts first), then installs the keypair into its `.ssh/` directory; backs up any existing key to `.bak` first
3. Detects your Tailscale IPv4 (or plain IPv6 as fallback) to add a `from="<ip>"` restriction to the authorized key (set `BACKUP_IP` manually to skip detection; Tailscale is optional)
4. SSHs into each production server, creates `sendsyncoid` if absent, then appends the public key to its `authorized_keys`, restricted to run only `/usr/sbin/zfs`; duplicate detection uses SSH fingerprint comparison
5. Hardens both accounts: shell set to `/usr/sbin/nologin`, password locked
6. Prints the exact `syncoid` command to use

## After setup

```bash
syncoid --no-privilege-elevation \
  --sshkey=/home/recsyncoid/.ssh/id_ed25519_<site-name>_syncoid \
  sendsyncoid@<prod-host>:pool/dataset \
  pool/backup/<site-name>/dataset
```

## Security model

| Account | Machine | Role |
|---------|---------|------|
| `recsyncoid` | Backup server | Pulls snapshots; holds the private key |
| `sendsyncoid` | Production servers | Sends snapshots; accepts the restricted public key |

Both accounts have no interactive login shell and no password. The authorized key on each production server is locked to `/usr/sbin/zfs` only, and optionally restricted to the backup machine's Tailscale IP.

Multiple sites are supported — each gets its own keypair, so access can be revoked per site.
