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

A script to automate SSH key-based authentication setup for [syncoid](https://github.com/jimsalterjrs/sanoid) (ZFS replication). Run it once per site and it handles key generation, local installation, and remote deployment across all your production servers. After setup it launches an interactive wizard to discover remote ZFS datasets and generate ready-to-paste `syncoid` commands.

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
6. Launches an interactive command wizard (see below)

## Command wizard

After setup, the script immediately walks you through generating `syncoid` commands:

1. **Dataset selection** — lists all ZFS datasets on each remote server (fetched via your admin SSH session); select by number, range (`1-3`), comma-separated (`1,3,5`), or `a` for all
2. **Destination** — shows local ZFS datasets as a numbered menu; default destination is `<parent>/<site-name>/<leaf>`, overridable per dataset
3. **Encryption** — for encrypted datasets you choose raw receive (keeps encryption on the backup server, recommended) or decrypted receive

The wizard is re-run every time you invoke the script — safe to run again when adding new datasets, since the setup phase skips steps that are already done (existing keys and authorized_keys entries are detected and left in place).

The wizard is skipped automatically when stdin is not a terminal (e.g. cron, piped run).

Example output:

```bash
syncoid --no-privilege-elevation \
  --sshkey=/home/recsyncoid/.ssh/id_ed25519_homelab_syncoid \
  --sendoptions=w \
  sendsyncoid@192.168.1.10:tank/data \
  backup/homelab/data
```

`--sendoptions=w` is included automatically for encrypted datasets when raw receive is chosen.

## Security model

| Account | Machine | Role |
|---------|---------|------|
| `recsyncoid` | Backup server | Pulls snapshots; holds the private key |
| `sendsyncoid` | Production servers | Sends snapshots; accepts the restricted public key |

Both accounts have no interactive login shell and no password. The authorized key on each production server is locked to `/usr/sbin/zfs` only, and optionally restricted to the backup machine's Tailscale IP.

Multiple sites are supported — each gets its own keypair, so access can be revoked per site.

### Sudo password handling

The script requires sudo access on each remote server. It first tests for passwordless sudo (`sudo -n true`). If that passes, no password is ever read. If it fails, the script prompts once per server and holds the password in a bash variable for the duration of the setup block — it is never written to disk, never passed as a command-line argument, and never appears in shell history (`read -rsp`). It transits to the remote only inside the SSH-encrypted connection.

**Known trade-off:** the password lives in the bash process's memory for the lifetime of the script. On a shared machine a privileged user could in principle read it from `/proc/<pid>/mem`. This is acceptable on a single-user management machine. If you are on a shared system, configure passwordless sudo (`NOPASSWD`) on the remote servers instead — the script will then skip the prompt entirely.
