#!/usr/bin/env bash
# syncoidsetup.sh — v0.1.0
# Run as your NORMAL USER — the script will ask for sudo when needed.
#
# Usage: ./syncoidsetup.sh [--site <name>] --remote <host> [--remote <host2> ...]
# --site defaults to this machine's hostname if omitted.
# Example: ./syncoidsetup.sh --site homelab --remote 100.64.0.1 --remote 100.64.0.2
# Example: ./syncoidsetup.sh --remote 100.64.0.1 --remote 100.64.0.2

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SEND_USER="sendsyncoid"
REC_USER="recsyncoid"
ADMIN_USER="${SUDO_USER:-${USER}}"   # the actual human user, not root
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [--site <name>] --remote <host> [--remote <host2> ...]"
    echo "       --site defaults to this machine's hostname if omitted."
    exit 1
}

[[ $EUID -eq 0 ]] && { echo "Do NOT run this script as root. Run as your normal user."; exit 1; }

SITE_NAME=""
PROD_SERVERS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site)   SITE_NAME="$2";       shift 2 ;;
        --remote) PROD_SERVERS+=("$2"); shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; usage ;;
    esac
done

[[ -z "${SITE_NAME}" ]] && SITE_NAME=$(hostname -s)
[[ ${#PROD_SERVERS[@]} -eq 0 ]] && { echo "[ERROR] At least one --remote <host> is required." >&2; usage; }

# ── Input validation ──────────────────────────────────────────────────────────
if [[ ! "${SITE_NAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[ERROR] Invalid site-name '${SITE_NAME}': only letters, digits, '.', '_', and '-' are allowed." >&2
    exit 1
fi

for SERVER in "${PROD_SERVERS[@]}"; do
    if [[ ! "${SERVER}" =~ ^[a-zA-Z0-9._:\[\]-]+$ ]]; then
        echo "[ERROR] Invalid server '${SERVER}': only letters, digits, '.', '_', ':', '[', ']', and '-' are allowed." >&2
        exit 1
    fi
done

# ── SSH connectivity pre-check (before any local changes) ─────────────────────
echo "[INFO] Checking SSH connectivity to all production servers..."
for SERVER in "${PROD_SERVERS[@]}"; do
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes \
              -o StrictHostKeyChecking=accept-new \
              "${ADMIN_USER}@${SERVER}" true 2>/dev/null; then
        echo "[ERROR] Cannot reach ${SERVER} as ${ADMIN_USER} — aborting before making any local changes." >&2
        exit 1
    fi
    echo "[OK] Reachable: ${SERVER}"
done

KEY_PATH="${HOME}/.ssh/id_ed25519_${SITE_NAME}_syncoid"
KEY_COMMENT="${SITE_NAME}-backup-syncoid"

# ── 1. Validate and cache sudo credentials upfront ───────────────────────────
echo "[INFO] This script needs sudo for a few local operations."
echo "       Please enter your sudo password once:"
sudo -v
# Keep the sudo ticket alive in the background for long-running scripts
( for _ in $(seq 10); do sleep 50; sudo -v; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null' EXIT INT TERM

# ── 2. Generate key pair as the current user (no sudo needed) ─────────────────
mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if [[ -f "${KEY_PATH}" ]]; then
    echo "[INFO] Key already exists at ${KEY_PATH}, skipping generation."
else
    echo "[INFO] Generating ed25519 key pair..."
    ssh-keygen \
        -t ed25519 \
        -C "${KEY_COMMENT}" \
        -f "${KEY_PATH}" \
        -N ""
    echo "[OK] Key pair created: ${KEY_PATH}"
fi

PUB_KEY=$(cat "${KEY_PATH}.pub")

# ── 3. Install key into recsyncoid's .ssh dir (sudo needed) ──────────────────
echo ""
echo "[INFO] Installing key into ${REC_USER}'s .ssh directory..."

REC_HOME=$(getent passwd "${REC_USER}" | cut -d: -f6 || true)
if [[ -z "${REC_HOME}" ]]; then
    read -r -p "[PROMPT] User '${REC_USER}' not found locally. Create it now? [y/N] " yn
    [[ "$yn" =~ ^[Yy]$ ]] || { echo "[ERROR] Cannot continue without ${REC_USER}."; exit 1; }
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "${REC_USER}"
    REC_HOME=$(getent passwd "${REC_USER}" | cut -d: -f6)
    echo "[OK] Created system user ${REC_USER}."
fi
REC_SSH_DIR="${REC_HOME}/.ssh"
REC_KEY_PATH="${REC_SSH_DIR}/id_ed25519_${SITE_NAME}_syncoid"

sudo bash -s << LOCALEOF
set -euo pipefail
mkdir -p "${REC_SSH_DIR}"
chmod 700 "${REC_SSH_DIR}"
chown "${REC_USER}:${REC_USER}" "${REC_SSH_DIR}"

# Back up any existing private key before overwriting
if [[ -f "${REC_KEY_PATH}" ]]; then
    cp "${REC_KEY_PATH}" "${REC_KEY_PATH}.bak"
    echo "[WARN] Existing key backed up to ${REC_KEY_PATH}.bak"
fi

# Copy private and public key into recsyncoid's .ssh (install handles mode+owner atomically)
install -m 600 -o "${REC_USER}" -g "${REC_USER}" "${KEY_PATH}"     "${REC_KEY_PATH}"
install -m 644 -o "${REC_USER}" -g "${REC_USER}" "${KEY_PATH}.pub" "${REC_KEY_PATH}.pub"

# Harden local recsyncoid account
if command -v usermod > /dev/null; then
    sudo usermod -s /usr/sbin/nologin "${REC_USER}"
else
    echo "[WARN] usermod not found — set shell for ${REC_USER} to /usr/sbin/nologin manually."
fi
if command -v passwd > /dev/null; then
    sudo passwd -l "${REC_USER}" > /dev/null
else
    echo "[WARN] passwd not found — lock account for ${REC_USER} manually."
fi
echo "[OK] ${REC_USER} hardened and key installed locally."
LOCALEOF

# ── 4. Detect Tailscale IP for from= restriction ──────────────────────────────
# Honour a pre-set BACKUP_IP env var; otherwise probe Tailscale (take only first address).
if [[ -z "${BACKUP_IP:-}" ]]; then
    if command -v tailscale > /dev/null 2>&1; then
        BACKUP_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
        if [[ -z "${BACKUP_IP}" ]]; then
            IPV6=$(tailscale ip -6 2>/dev/null | head -n1 || true)
            [[ -n "${IPV6}" ]] && BACKUP_IP="${IPV6}"
        fi
    fi
fi
if [[ -n "${BACKUP_IP}" ]]; then
    FROM_CLAUSE="from=\"${BACKUP_IP}\","
    echo "[INFO] Tailscale IP: ${BACKUP_IP}"
else
    FROM_CLAUSE=""
    echo "[WARN] Could not detect Tailscale IP — omitting 'from=' restriction."
    echo "       To enforce source-IP restriction, set BACKUP_IP=<ip> before running."
fi

if [[ -n "${FROM_CLAUSE}" ]]; then
    AUTH_ENTRY="restrict,${FROM_CLAUSE}command=\"/usr/sbin/zfs\" ${PUB_KEY}"
else
    AUTH_ENTRY="restrict,command=\"/usr/sbin/zfs\" ${PUB_KEY}"
fi

# ── 5. Push public key to each production server via SSH ──────────────────────
for HOST in "${PROD_SERVERS[@]}"; do
    echo ""
    echo "[INFO] Deploying key to ${SEND_USER}@${HOST} (connecting as ${ADMIN_USER})..."

    # We SSH as the admin user — no sudo needed locally for this step.
    # The remote side uses sudo, which will prompt if the ticket isn't cached there.
    ssh -T "${ADMIN_USER}@${HOST}" bash -s \
        2> >(sed "s/^/[${HOST}] /" >&2) \
        << REMOTEEOF
set -euo pipefail
command -v bash > /dev/null || { echo "[ERROR] bash not found on ${HOST}"; exit 1; }

# Check hard requirement: zfs must be present for syncoid to send snapshots
command -v zfs > /dev/null || { echo "[ERROR] zfs not found on ${HOST} — install zfsutils-linux first."; exit 1; }

# Check soft requirement: sanoid creates the snapshots that syncoid replicates
if ! command -v sanoid > /dev/null; then
    echo "[WARN] sanoid not found on ${HOST} — snapshots won't be created automatically."
    echo "       Install sanoid and configure a snapshot policy before relying on replication."
fi

SEND_HOME=\$(getent passwd "${SEND_USER}" | cut -d: -f6 || true)
if [[ -z "\${SEND_HOME}" ]]; then
    echo "[INFO] User '${SEND_USER}' not found on \$(hostname) — creating system account."
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "${SEND_USER}"
    SEND_HOME=\$(getent passwd "${SEND_USER}" | cut -d: -f6)
fi
SSH_DIR="\${SEND_HOME}/.ssh"
AUTH_FILE="\${SSH_DIR}/authorized_keys"

sudo mkdir -p "\${SSH_DIR}"
sudo chmod 700 "\${SSH_DIR}"
sudo chown "${SEND_USER}:${SEND_USER}" "\${SSH_DIR}"

# Avoid duplicate entries by comparing SSH fingerprints
TMPKEY=\$(mktemp)
printf '%s\n' "${PUB_KEY}" > "\${TMPKEY}"
NEW_FP=\$(ssh-keygen -lf "\${TMPKEY}" | awk '{print \$2}')
rm -f "\${TMPKEY}"

ALREADY_PRESENT=false
if sudo test -f "\${AUTH_FILE}"; then
    if sudo ssh-keygen -lf "\${AUTH_FILE}" 2>/dev/null | awk '{print \$2}' | grep -qF "\${NEW_FP}"; then
        ALREADY_PRESENT=true
    fi
fi

if \${ALREADY_PRESENT}; then
    echo "[INFO] Key already present in \${AUTH_FILE} (fingerprint match), skipping."
else
    printf '%s\n' "${AUTH_ENTRY}" | sudo tee -a "\${AUTH_FILE}" > /dev/null
    echo "[OK] Key appended to \${AUTH_FILE}"
fi

sudo chmod 600 "\${AUTH_FILE}"
sudo chown "${SEND_USER}:${SEND_USER}" "\${AUTH_FILE}"

# Harden remote sendsyncoid account
if command -v usermod > /dev/null; then
    sudo usermod -s /usr/sbin/nologin "${SEND_USER}"
else
    echo "[WARN] usermod not found — set shell for ${SEND_USER} to /usr/sbin/nologin manually."
fi
if command -v passwd > /dev/null; then
    sudo passwd -l "${SEND_USER}" > /dev/null
else
    echo "[WARN] passwd not found — lock account for ${SEND_USER} manually."
fi
echo "[OK] ${SEND_USER} hardened on \$(hostname)"
REMOTEEOF

    echo "[OK] Done with ${HOST}"
done

# ── 6. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo " Setup complete for site: ${SITE_NAME}"
echo " Your key  : ${KEY_PATH}"
echo " recsyncoid: ${REC_KEY_PATH}"
echo " Deployed to: ${PROD_SERVERS[*]}"
echo ""
echo " Use this in your syncoid command:"
echo "   syncoid --no-privilege-elevation \\"
echo "     --sshkey=${REC_KEY_PATH} \\"
echo "     ${SEND_USER}@<prod-host>:pool/dataset \\"
echo "     pool/backup/${SITE_NAME}/dataset"
echo "════════════════════════════════════════════════════════"
