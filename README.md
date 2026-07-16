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

A script to automate SSH key-based authentication setup for [syncoid](https://github.com/jimsalterjrs/sanoid) (ZFS replication). Run it once per site and it handles key generation, local installation, and remote deployment across all your source servers. After setup it launches an interactive wizard to discover remote ZFS datasets and generate ready-to-paste `syncoid` commands.

It supports two directions:

- **Pull mode (default)** — the backup server initiates the connection and *pulls* snapshots from each source server. Use when the backup server can always reach the source servers.
- **Push mode (`--push`)** — each source server initiates the connection and *pushes* snapshots to the backup server. Use when source servers are intermittently online (laptops, machines behind NAT, etc.).

## Prerequisites

- SSH access (as your admin user) to the backup server and each source server
- `sudo` rights on the backup server and each source server

> `recsyncoid` (backup server) and `sendsyncoid` (source servers) are created automatically as system accounts if they do not already exist.

## Usage

Run as your **normal user** (not root) on your **management machine** (laptop/workstation):

```bash
./syncoidsetup.sh [--push] [--password-auth] [--site <name>] \
                  --backup [user@]backuphost \
                  --source [user@]sourcehost [--source [user@]sourcehost2 ...]
```

| Flag | Meaning |
|------|---------|
| `--push` | Push mode: syncoid runs on each source server and pushes to the backup server. Omit for pull mode (default). |
| `--password-auth` | Force password authentication for the admin SSH connections (disables pubkey). Use when many keys in your SSH agent cause `too many authentication failures`. |
| `--site <name>` | Optional. Site name for this backup set. Defaults to the backup server's short hostname; for IPv4 addresses it tries reverse DNS, otherwise replaces dots with dashes. |
| `--backup [user@]host` | Backup server. `user@` defaults to `$USER`. |
| `--source [user@]host` | Source server(s). Repeatable; each may use a different admin user. `user@` defaults to `$USER`. |

> **Renamed:** the source-server flag used to be `--remote`, and the push-mode IP override env var used to be `PROD_IP` (now `SOURCE_IP`). "Remote" was ambiguous — from the management machine both servers are remote, and in push mode syncoid actually runs on that server. There are **no backward-compat aliases**: update existing invocations.

```bash
# Minimal example (current user on both servers, pull mode)
./syncoidsetup.sh --backup 100.64.0.10 --source 100.64.0.1

# Push mode (source pushes to backup; source is intermittently online)
./syncoidsetup.sh --push --backup ma@100.88.1.4 --source nobi@100.103.188.87

# Explicit site-name, multiple source servers
./syncoidsetup.sh --site homelab --backup backup.lan --source source1.lan --source source2.lan

# Different admin users per server
./syncoidsetup.sh --backup admin@100.64.0.10 --source ubuntu@100.64.0.1 --source root@100.64.0.2

# Force password auth (agent has too many keys)
./syncoidsetup.sh --password-auth --backup backup.lan --source source1.lan
```

## What it does

1. Generates an ed25519 keypair at `~/.ssh/id_ed25519_<site-name>_syncoid` (skipped if already present).
2. Runs a TCP reachability pre-check (port 22) against the backup server **and** every source server, and warns for any host missing from `known_hosts` — so you can verify the fingerprint before any credential is sent on first connect.
3. **Backup server:** SSHs in, creates `recsyncoid` if absent, and hardens the account (locked password). In pull mode the private key is installed into its `.ssh/` (existing key backed up to `.bak` first); in push mode the public key is added to its `authorized_keys`.
4. **Source servers:** SSHs into each, creates `sendsyncoid` if absent, hardens the account, and grants the ZFS delegation needed to send snapshots. In pull mode the public key is added to `sendsyncoid`'s `authorized_keys`; in push mode the private key is installed for `sendsyncoid`.
5. Determines the real outgoing IP of the connecting side **per source server** (by running `ip route get` on the connecting host itself) and pins it as a `from=` restriction on the `authorized_keys` entry — the backup server's outbound IP can differ per source server (LAN vs. VPN).
6. Seeds the connecting user's `known_hosts` via `ssh-keyscan` so the first unattended (cron/systemd) run isn't blocked by the interactive host-key prompt.
7. Launches an interactive command wizard (see below).

The setup phase is idempotent: existing keys and `authorized_keys` entries are detected (by SSH fingerprint) and left in place. In pull mode, if the backup server's IP changed since the last run, the stale `from=` restriction is rewritten in place rather than skipped.

## Which account holds the key

| Mode | Private key lives on | Connection initiated by | `recsyncoid` shell | `sendsyncoid` shell |
|------|----------------------|--------------------------|--------------------|---------------------|
| Pull (default) | Backup server (`recsyncoid`) | Backup server → source | `/usr/sbin/nologin` | `/bin/sh` |
| Push (`--push`) | Source servers (`sendsyncoid`) | Source → backup server | `/bin/sh` | `/bin/sh` |

`sendsyncoid` needs `/bin/sh` because sshd executes the incoming `zfs`/syncoid commands via the login shell (`nologin` would ignore `-c` and block them). In push mode `recsyncoid` likewise needs `/bin/sh` to accept the incoming push. Both accounts always have a **locked password** and are reachable only via the restricted SSH key.

## Command wizard

After setup, the script immediately walks you through generating `syncoid` commands:

1. **Dataset selection** — lists ZFS datasets on each source server (fetched via your admin SSH session); select by number, range (`1-3`), comma-separated (`1,3,5`), or `a` for all. Child datasets whose parent is also selected are suppressed automatically, and the parent command gets `--recursive`. If a selected dataset has children that were *not* selected, the wizard asks whether to include them recursively (default yes).
2. **Destination** — shows ZFS datasets on the backup server as a numbered menu for the destination parent; then prompts for a middle path component (default: `backup`). The default full destination preserves the entire source path (`<parent>/<middle>/<full-source-path>`, e.g. `tank/backup/rpool/data/www`) to avoid collisions between pools. Each destination can be overridden per dataset — a bare name renames only the leaf, a path with a slash replaces the full destination. Missing intermediate datasets are pre-created (`zfs create -p`), since `zfs receive` cannot create them.
3. **Encryption** — for encrypted datasets you choose raw receive (`--sendoptions=w`, keeps encryption on the backup server, recommended) or decrypted receive. Detection is descendant-aware: an encrypted child of an unencrypted parent still triggers raw receive when the parent is sent recursively.

Generated commands carry `--recvoptions=u` (don't mount on receive). ZFS receive permissions are granted on the destination parent (children inherit); a full-path override outside that subtree gets its own grant.

The wizard is re-run every time you invoke the script — safe to run again when adding new datasets, since the setup phase skips steps that are already done. It is skipped automatically when stdin is not a terminal (e.g. cron, piped run); in that case the backup-side ZFS receive permissions must be granted manually (the script prints the exact command).

Example output (pull mode — command runs on the backup server):

```bash
sudo -H -u recsyncoid bash -c \
  'syncoid --no-privilege-elevation --sshkey=/home/recsyncoid/.ssh/id_ed25519_homelab_syncoid --recvoptions=u --sendoptions=w sendsyncoid@192.168.1.10:tank/data tank/backup/tank/data'
```

Example output (push mode — command runs on the source server):

```bash
sudo -H -u sendsyncoid bash -c \
  'syncoid --no-privilege-elevation --sshkey=/home/sendsyncoid/.ssh/id_ed25519_homelab_syncoid --recvoptions=u --sendoptions=w tank/data recsyncoid@backup.lan:tank/backup/tank/data'
```

`--sendoptions=w` is included automatically for encrypted datasets when raw receive is chosen.

Generated commands are also written to `~/.syncoid/<site-name>.sh` on the management machine (a ready-to-run script; a pre-existing file is preserved as `<site-name>.sh.bak`).

## Scheduling the generated commands

**Pull mode** — schedule the generated `~/.syncoid/<site>.sh` on the **backup server** via cron or systemd.

**Push mode** — schedule on **each source server**. A systemd service + timer pair is recommended so the push runs whenever the machine is online:

`/etc/systemd/system/syncoid-push.service`:
```ini
[Unit]
Description=Syncoid push backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/sudo -H -u sendsyncoid bash -c \
  'syncoid --no-privilege-elevation --sshkey=/home/sendsyncoid/.ssh/id_ed25519_<site>_syncoid <source> recsyncoid@<backup-host>:<dest>'
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/syncoid-push.timer` (fires 1 min after boot, then hourly):
```ini
[Unit]
Description=Run syncoid push backup hourly

[Timer]
OnBootSec=1min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
```

Enable the **timer** (it drives the service): `sudo systemctl daemon-reload && sudo systemctl enable --now syncoid-push.timer`.

## Security model

| Account | Machine | Role |
|---------|---------|------|
| `recsyncoid` | Backup server | Receives snapshots |
| `sendsyncoid` | Source servers | Sends snapshots |

The script runs on your management machine — the backup server never holds admin SSH credentials to source servers, reducing its attack surface. Multiple sites are supported — each gets its own keypair, so access can be revoked per site.

Both syncoid accounts have a **locked password** and are reachable only via the restricted SSH key. Each `authorized_keys` entry carries `restrict` (no port/agent/X11 forwarding, no pty) plus `from=<ip>` pinning the connection to the peer's real source address.

**No `command=` restriction (deliberate).** Because syncoid's `zfs` invocations vary, pinning them with `command=` is fragile, so it is intentionally omitted. As a result, possession of the private key **plus** the ability to present the pinned `from=` IP is enough to run commands as these users — including the delegated `zfs destroy` (`sendsyncoid` gets `send,snapshot,hold,destroy,mount`; `recsyncoid` gets `receive,create,mount,rollback,destroy,compression`). The `from=` IP is the only network control and is spoofable on a flat L2 segment; the primary mitigation is that the private key is mode `600` under a password-locked account. This is a documented trade-off, not an oversight.

### Source-IP restriction

The `from=` value is derived by SSH-ing into the **connecting** host and running `ip route get <peer>` there, so the IP recorded is the one actually used for the outbound connection — not the IP as seen from the management machine (which may differ on multi-homed/VPN setups). It is resolved **per source server**. Override the detection with:

- **Pull mode:** `BACKUP_IP=<ip>` — pins the backup server's IP used in every source server's `from=`.
- **Push mode:** `SOURCE_IP=<ip>` — pins the source-side IP used in the backup server's `from=` (applies to all source servers).

```bash
BACKUP_IP=100.64.0.5 ./syncoidsetup.sh --site site-a --backup backup-host --source source1
SOURCE_IP=100.64.0.1 ./syncoidsetup.sh --push --site site-a --backup backup-host --source source1
```

### First-connect trust-on-first-use

The shared sudo password and the generated private key are delivered into the remote shell over SSH. On a host not yet in `known_hosts` this is trust-on-first-use — a first-connect MITM could harvest the sudo password. The script warns for every host missing from `known_hosts` and relies on SSH's default interactive fingerprint prompt (it does **not** force `StrictHostKeyChecking`). Pre-populating `~/.ssh/known_hosts` beforehand eliminates the window.

### Sudo password handling

The script prompts for a sudo password once and uses it for all remote servers. It is held **base64-encoded in a bash variable** for the duration of the script — never written to disk, never passed as a command-line argument (so it never appears in `ps`/process listings on either machine), and never logged. It transits to each remote only inside the SSH-encrypted connection, on stdin (via heredocs).

**Known trade-off:** the password lives in bash process memory. On a shared machine a privileged user could in principle read it from `/proc/<pid>/mem`. On a single-user management machine this is acceptable. If you are on a shared system, configure passwordless sudo (`NOPASSWD`) on the remote servers instead (press Enter at the password prompt).
