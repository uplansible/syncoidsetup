#!/usr/bin/env bash
# syncoidsetup.sh
# Run as your NORMAL USER — the script will ask for sudo when needed.
#
# Usage: ./syncoidsetup.sh [site-name] <prod-server-1> [prod-server-2] ...
# site-name defaults to this machine's hostname if omitted.
# Example: ./syncoidsetup.sh site-a 100.64.0.1 100.64.0.2
# Example: ./syncoidsetup.sh 100.64.0.1 100.64.0.2

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SEND_USER="sendsyncoid"
REC_USER="recsyncoid"
ADMIN_USER="${SUDO_USER:-${USER}}"   # the actual human user, not root
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [site-name] <prod-server-1> [prod-server-2] ..."
    echo "       site-name defaults to this machine's hostname if omitted."
    exit 1
}

[[ $# -lt 1 ]] && usage
[[ $EUID -eq 0 ]] && { echo "Do NOT run this script as root. Run as your normal user."; exit 1; }

# If only one argument is given it must be a prod server; use hostname as site-name.
if [[ $# -eq 1 ]]; then
    SITE_NAME=$(hostname -s)
    PROD_SERVERS=("$1")
else
    SITE_NAME="$1"
    shift
    PROD_SERVERS=("$@")
fi

KEY_PATH="${HOME}/.ssh/id_ed25519_${SITE_NAME}_syncoid"
KEY_COMMENT="${SITE_NAME}-backup-syncoid"

# ── 1. Validate and cache sudo credentials upfront ───────────────────────────
echo "[INFO] This script needs sudo for a few local operations."
echo "       Please enter your sudo password once:"
sudo -v
# Keep the sudo ticket alive in the background for long-running scripts
( while true; do sudo -v; sleep 50; done ) &
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

REC_HOME=$(getent passwd "${REC_USER}" | cut -d: -f6)
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
    usermod -s /usr/sbin/nologin "${REC_USER}"
else
    echo "[WARN] usermod not found — set shell for ${REC_USER} to /usr/sbin/nologin manually."
fi
if command -v passwd > /dev/null; then
    passwd -l "${REC_USER}" > /dev/null
else
    echo "[WARN] passwd not found — lock account for ${REC_USER} manually."
fi
echo "[OK] ${REC_USER} hardened and key installed locally."
LOCALEOF

# ── 4. Detect Tailscale IP for from= restriction ──────────────────────────────
# Honour a pre-set BACKUP_IP env var; otherwise probe Tailscale (take only first address).
if [[ -z "${BACKUP_IP:-}" ]]; then
    BACKUP_IP=$(tailscale ip -4 2>/dev/null | head -n1 || true)
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
    ssh -T "${ADMIN_USER}@${HOST}" bash -s << REMOTEEOF
command -v bash > /dev/null || { echo "[ERROR] bash not found on ${HOST}"; exit 1; }
set -euo pipefail

# Check hard requirement: zfs must be present for syncoid to send snapshots
command -v zfs > /dev/null || { echo "[ERROR] zfs not found on ${HOST} — install zfsutils-linux first."; exit 1; }

# Check soft requirement: sanoid creates the snapshots that syncoid replicates
if ! command -v sanoid > /dev/null; then
    echo "[WARN] sanoid not found on ${HOST} — snapshots won't be created automatically."
    echo "       Install sanoid and configure a snapshot policy before relying on replication."
fi

SEND_HOME=\$(getent passwd "${SEND_USER}" | cut -d: -f6)
SSH_DIR="\${SEND_HOME}/.ssh"
AUTH_FILE="\${SSH_DIR}/authorized_keys"

sudo mkdir -p "\${SSH_DIR}"
sudo chmod 700 "\${SSH_DIR}"
sudo chown "${SEND_USER}:${SEND_USER}" "\${SSH_DIR}"

# Avoid duplicate entries by matching the base64 key body (printf avoids glob expansion)
KEY_BODY="${PUB_KEY##* }"
if sudo grep -qF "\$(printf '%s' "\${KEY_BODY}")" "\${AUTH_FILE}" 2>/dev/null; then
    echo "[INFO] Key already present in \${AUTH_FILE}, skipping."
else
    echo '${AUTH_ENTRY}' | sudo tee -a "\${AUTH_FILE}" > /dev/null
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
