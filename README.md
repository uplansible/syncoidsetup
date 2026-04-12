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
- `sendsyncoid` system account pre-created on each production server
- `recsyncoid` system account pre-created on the backup machine
- Tailscale installed (optional — used to restrict the SSH key to your backup network)

## Usage

Run as your **normal user** (not root):

```bash
./syncoidsetup.sh [site-name] <prod-server-1> [prod-server-2] ...
```

`site-name` is optional. When omitted, the backup server's hostname (`hostname -s`) is used — handy when running the same script on multiple backup machines without extra arguments.

```bash
# site-name defaults to hostname
./syncoidsetup.sh 192.168.1.10 192.168.1.11

# Explicit site-name
./syncoidsetup.sh homelab 192.168.1.10 192.168.1.11

# Override source-IP restriction (skip Tailscale auto-detection)
BACKUP_IP=100.64.0.5 ./syncoidsetup.sh 192.168.1.10
```

The script will prompt for your sudo password once and keep the ticket alive for the duration.

## What it does

1. Generates an ed25519 keypair at `~/.ssh/id_ed25519_<site-name>_syncoid` (skipped if already present)
2. Installs the keypair into `recsyncoid`'s `.ssh/` directory on the backup machine; backs up any existing key to `.bak` first
3. Detects your Tailscale IPv4 to add a `from="<ip>"` restriction to the authorized key (set `BACKUP_IP` manually to skip detection)
4. SSHs into each production server and appends the public key to `sendsyncoid`'s `authorized_keys`, restricted to run only `/usr/sbin/zfs`
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
