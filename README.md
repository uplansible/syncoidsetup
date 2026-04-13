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

- SSH access (as your admin user) to the backup server and each production server
- `sudo` rights on the backup server and each production server

> `recsyncoid` (backup server) and `sendsyncoid` (production servers) are created automatically as system accounts if they do not already exist.

## Usage

Run as your **normal user** (not root) on your **management machine** (laptop/workstation):

```bash
./syncoidsetup.sh [--site <name>] --backup [user@]backuphost \
                  --remote [user@]remotehost [--remote [user@]remotehost2 ...]
```

`--site` is optional. When omitted, the backup server's short hostname is used as the site name — handy when you only have one backup server.

```bash
# Minimal example (current user on both servers)
./syncoidsetup.sh --backup 100.64.0.10 --remote 100.64.0.1

# Explicit site-name
./syncoidsetup.sh --site homelab --backup backup.lan --remote prod1.lan --remote prod2.lan

# Different admin users per server
./syncoidsetup.sh --backup admin@100.64.0.10 --remote ubuntu@100.64.0.1 --remote root@100.64.0.2

# Override the source-IP restriction used in authorized_keys
BACKUP_IP=100.64.0.5 ./syncoidsetup.sh --backup mybackup --remote 192.168.1.10
```

## What it does

1. Generates an ed25519 keypair at `~/.ssh/id_ed25519_<site-name>_syncoid` (skipped if already present)
2. SSHs into the backup server, creates `recsyncoid` if absent, installs the keypair into its `.ssh/` directory; backs up any existing key to `.bak` first; hardens the account (nologin shell, locked password)
3. Determines the backup server's actual outgoing IP toward each production server (by running `ip route get` on the backup server itself), so the `from=` restriction in `authorized_keys` matches the real source address
4. SSHs into each production server, creates `sendsyncoid` if absent, appends the public key to its `authorized_keys` restricted to run only `/usr/sbin/zfs` and only from the backup server's IP; duplicate detection uses SSH fingerprint comparison; hardens the account
5. Launches an interactive command wizard (see below)

## Command wizard

After setup, the script immediately walks you through generating `syncoid` commands:

1. **Dataset selection** — lists all ZFS datasets on each production server (fetched via your admin SSH session); select by number, range (`1-3`), comma-separated (`1,3,5`), or `a` for all
2. **Destination** — shows ZFS datasets on the backup server as a numbered menu for the destination parent; then prompts for a middle path component (default: `backup`) and confirms each dataset's full destination path (overridable per dataset, including renaming the leaf)
3. **Encryption** — for encrypted datasets you choose raw receive (keeps encryption on the backup server, recommended) or decrypted receive

The wizard is re-run every time you invoke the script — safe to run again when adding new datasets, since the setup phase skips steps that are already done (existing keys and `authorized_keys` entries are detected and left in place).

The wizard is skipped automatically when stdin is not a terminal (e.g. cron, piped run).

Example output:

```bash
sudo -H -u recsyncoid bash -c \
  'syncoid --no-privilege-elevation \
   --sshkey=/home/recsyncoid/.ssh/id_ed25519_testbkp_syncoid \
   --sendoptions=w \
   sendsyncoid@192.168.1.10:tank/data \
   tank/backup/data'
```

`--sendoptions=w` is included automatically for encrypted datasets when raw receive is chosen.

Generated commands are also written to `~/.syncoid/<site-name>.sh` on the management machine.

## Security model

| Account | Machine | Role |
|---------|---------|------|
| `recsyncoid` | Backup server | Pulls snapshots; holds the private SSH key |
| `sendsyncoid` | Production servers | Sends snapshots; accepts the restricted public key |

Both accounts have no interactive login shell and no password. The authorized key on each production server is locked to `/usr/sbin/zfs` only, and restricted to connections originating from the backup server's IP.

The script runs on your management machine — the backup server never holds admin SSH credentials to production servers, reducing its attack surface.

Multiple sites are supported — each gets its own keypair, so access can be revoked per site.

### Source-IP restriction

The `from=` value in `authorized_keys` is derived by SSH-ing into the backup server and running `ip route get <prod-server-ip>`, so the IP recorded is the one the backup server actually uses when connecting outbound — not the IP as seen from the management machine (which may differ on multi-homed or VPN setups). Set `BACKUP_IP=<ip>` in the environment to override this detection.

### Sudo password handling

The script prompts for a sudo password once and uses it for all remote servers. It is held in a bash variable for the duration of the script — never written to disk, never passed as a command-line argument, and never visible in shell history (`read -rsp`). It transits to each remote only inside the SSH-encrypted connection.

**Known trade-off:** the password lives in bash process memory. On a shared machine a privileged user could in principle read it from `/proc/<pid>/mem`. On a single-user management machine this is acceptable. If you are on a shared system, configure passwordless sudo (`NOPASSWD`) on the remote servers instead.
