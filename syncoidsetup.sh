#!/usr/bin/env bash
# syncoidsetup.sh — v0.1.2
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
echo " Generic syncoid template:"
echo "   syncoid --no-privilege-elevation \\"
echo "     --sshkey=${REC_KEY_PATH} \\"
echo "     ${SEND_USER}@<prod-host>:pool/dataset \\"
echo "     pool/backup/${SITE_NAME}/dataset"
echo "════════════════════════════════════════════════════════"

# ── 7. Interactive wizard — generate ready-to-use syncoid commands ────────────
# Skip if stdin is not a terminal (e.g. piped/non-interactive run)
if [[ ! -t 0 ]]; then
    echo "[INFO] Non-interactive mode — skipping command wizard."
    exit 0
fi

# Parse multi-select input into SELECTED_INDICES (global).
# Returns 1 if input is 'q' or results in no valid indices.
wizard_parse_selection() {
    local input="$1"
    local max="$2"
    SELECTED_INDICES=()
    [[ "${input}" == "q" ]] && return 1
    if [[ "${input}" == "a" ]]; then
        for ((i=1; i<=max; i++)); do SELECTED_INDICES+=("$i"); done
        return 0
    fi
    # Normalise commas to spaces
    input="${input//,/ }"
    local token start end
    for token in ${input}; do
        if [[ "${token}" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            for ((i=start; i<=end; i++)); do
                [[ $i -ge 1 && $i -le $max ]] && SELECTED_INDICES+=("$i")
            done
        elif [[ "${token}" =~ ^[0-9]+$ ]]; then
            [[ ${token} -ge 1 && ${token} -le ${max} ]] && SELECTED_INDICES+=("${token}")
        fi
    done
    [[ ${#SELECTED_INDICES[@]} -gt 0 ]]
}

echo ""
echo "════════════════════════════════════════════════════════"
echo " Syncoid Command Wizard"
echo " (select datasets, destinations, and encryption options)"
echo "════════════════════════════════════════════════════════"

# Collect local ZFS datasets once for the destination picker
LOCAL_DATASETS=()
if command -v zfs > /dev/null 2>&1; then
    mapfile -t LOCAL_DATASETS < <(sudo zfs list -H -o name 2>/dev/null || true)
fi

ALL_CMDS=()  # accumulates all generated commands across hosts

for HOST in "${PROD_SERVERS[@]}"; do
    echo ""
    echo "┌─ Host: ${HOST} ──────────────────────────────────────────"

    # Fetch remote dataset list via admin SSH (sendsyncoid key has command= restriction)
    mapfile -t REMOTE_LINES < <(
        ssh -o BatchMode=yes -o ConnectTimeout=5 "${ADMIN_USER}@${HOST}" \
            "sudo zfs list -H -r -o name,encryption,keystatus" 2>/dev/null || true
    )

    DS_NAMES=()
    DS_ENCS=()

    if [[ ${#REMOTE_LINES[@]} -eq 0 ]]; then
        echo "│ [WARN] Could not list remote datasets (no sudo access or zfs unavailable)."
        read -r -p "│ Enter dataset path manually (or press Enter to skip): " MANUAL_DS || true
        if [[ -z "${MANUAL_DS}" ]]; then
            echo "│ Skipping ${HOST}."
            echo "└──────────────────────────────────────────────────────────"
            continue
        fi
        DS_NAMES+=("${MANUAL_DS}")
        DS_ENCS+=("unknown")
    else
        for line in "${REMOTE_LINES[@]}"; do
            DS_NAMES+=("$(printf '%s' "${line}" | cut -f1)")
            DS_ENCS+=("$(printf '%s' "${line}" | cut -f2)")
        done
    fi

    # Display numbered dataset list
    echo "│"
    echo "│  Datasets on ${HOST}:"
    for ((i=0; i<${#DS_NAMES[@]}; i++)); do
        enc_label=""
        [[ "${DS_ENCS[$i]}" != "off" && "${DS_ENCS[$i]}" != "-" ]] && enc_label="  [encrypted]"
        printf "│    [%2d] %s%s\n" "$((i+1))" "${DS_NAMES[$i]}" "${enc_label}"
    done
    echo "│"
    echo "│  Select datasets to replicate:"
    echo "│    Numbers (e.g. 1 3, 1-3, 1,3,5), 'a' = all, Enter to skip host"
    read -r -p "│  > " SEL_INPUT || true

    if [[ -z "${SEL_INPUT}" || "${SEL_INPUT}" == "q" ]]; then
        echo "│ Skipping ${HOST}."
        echo "└──────────────────────────────────────────────────────────"
        continue
    fi

    SELECTED_INDICES=()
    if ! wizard_parse_selection "${SEL_INPUT}" "${#DS_NAMES[@]}"; then
        echo "│ [WARN] No valid selection — skipping ${HOST}."
        echo "└──────────────────────────────────────────────────────────"
        continue
    fi

    # Map indices → dataset names
    SEL_NAMES=()
    for idx in "${SELECTED_INDICES[@]}"; do
        SEL_NAMES+=("${DS_NAMES[$((idx-1))]}")
    done

    # Remove children whose parent is also selected (avoids double-replication)
    FILTERED_NAMES=()
    for ds in "${SEL_NAMES[@]}"; do
        IS_CHILD=false
        PARENT_DS=""
        for other in "${SEL_NAMES[@]}"; do
            [[ "${other}" == "${ds}" ]] && continue
            if [[ "${ds}" == "${other}/"* ]]; then
                IS_CHILD=true
                PARENT_DS="${other}"
                break
            fi
        done
        if ${IS_CHILD}; then
            echo "│ [INFO] Skipping '${ds}' — parent '${PARENT_DS}' selected (use --recursive on parent to include children)."
        else
            FILTERED_NAMES+=("${ds}")
        fi
    done

    [[ ${#FILTERED_NAMES[@]} -eq 0 ]] && {
        echo "│ No datasets to replicate after deduplication."
        echo "└──────────────────────────────────────────────────────────"
        continue
    }

    # Determine encryption policy for this host
    HAS_ENCRYPTED=false
    for ds in "${FILTERED_NAMES[@]}"; do
        for ((i=0; i<${#DS_NAMES[@]}; i++)); do
            if [[ "${DS_NAMES[$i]}" == "${ds}" && \
                  "${DS_ENCS[$i]}" != "off" && "${DS_ENCS[$i]}" != "-" && "${DS_ENCS[$i]}" != "unknown" ]]; then
                HAS_ENCRYPTED=true
                break 2
            fi
        done
    done

    ENC_POLICY="raw"  # default: keep encryption
    if ${HAS_ENCRYPTED}; then
        echo "│"
        echo "│  One or more datasets are encrypted. How should they be received?"
        echo "│    [1] Raw — keep encryption on the backup server (recommended)"
        echo "│    [2] Decrypted — backup server stores plaintext"
        read -r -p "│  > Choice [1]: " ENC_CHOICE || true
        [[ "${ENC_CHOICE}" == "2" ]] && ENC_POLICY="decrypt" || ENC_POLICY="raw"
    fi

    # Local destination parent
    echo "│"
    if [[ ${#LOCAL_DATASETS[@]} -gt 0 ]]; then
        echo "│  Local ZFS datasets (select a destination parent):"
        for ((i=0; i<${#LOCAL_DATASETS[@]}; i++)); do
            printf "│    [%2d] %s\n" "$((i+1))" "${LOCAL_DATASETS[$i]}"
        done
        echo "│"
        read -r -p "│  > Destination parent [number or path]: " DEST_INPUT || true
        if [[ "${DEST_INPUT}" =~ ^[0-9]+$ ]] && \
           [[ ${DEST_INPUT} -ge 1 && ${DEST_INPUT} -le ${#LOCAL_DATASETS[@]} ]]; then
            LOCAL_PARENT="${LOCAL_DATASETS[$((DEST_INPUT-1))]}"
        else
            LOCAL_PARENT="${DEST_INPUT}"
        fi
    else
        read -r -p "│  > Destination parent dataset (e.g. tank/backup): " LOCAL_PARENT || true
    fi

    if [[ -z "${LOCAL_PARENT}" ]]; then
        echo "│ [WARN] No destination specified — skipping ${HOST}."
        echo "└──────────────────────────────────────────────────────────"
        continue
    fi

    # Build commands per selected dataset
    HOST_CMDS=("# ── syncoid commands for site: ${SITE_NAME} / host: ${HOST}")
    echo "│"
    echo "│  Confirm destinations (press Enter to accept default):"

    for ds in "${FILTERED_NAMES[@]}"; do
        LEAF="${ds##*/}"
        DEFAULT_DEST="${LOCAL_PARENT}/${SITE_NAME}/${LEAF}"
        read -r -p "│    '${ds}' → [${DEFAULT_DEST}]: " CUSTOM_DEST || true
        DEST="${DEFAULT_DEST}"
        [[ -n "${CUSTOM_DEST}" ]] && DEST="${CUSTOM_DEST}"

        # Check encryption for this specific dataset
        DS_IS_ENC=false
        for ((i=0; i<${#DS_NAMES[@]}; i++)); do
            if [[ "${DS_NAMES[$i]}" == "${ds}" && \
                  "${DS_ENCS[$i]}" != "off" && "${DS_ENCS[$i]}" != "-" && "${DS_ENCS[$i]}" != "unknown" ]]; then
                DS_IS_ENC=true
                break
            fi
        done

        CMD="syncoid --no-privilege-elevation \\"$'\n'
        CMD+="  --sshkey=${REC_KEY_PATH} \\"$'\n'
        if ${DS_IS_ENC} && [[ "${ENC_POLICY}" == "raw" ]]; then
            CMD+="  --sendoptions=w \\"$'\n'
        fi
        CMD+="  ${SEND_USER}@${HOST}:${ds} \\"$'\n'
        CMD+="  ${DEST}"

        HOST_CMDS+=("${CMD}")
    done

    # Preview commands in the box
    echo "│"
    for cmd in "${HOST_CMDS[@]}"; do
        while IFS= read -r line; do
            echo "│  ${line}"
        done <<< "${cmd}"
        echo "│"
    done

    ALL_CMDS+=("${HOST_CMDS[@]}")
    echo "└──────────────────────────────────────────────────────────"
done

# Final clean printout of all commands
if [[ ${#ALL_CMDS[@]} -gt 0 ]]; then
    echo ""
    echo "════════════════════════════════════════════════════════"
    echo " All generated syncoid commands:"
    echo "════════════════════════════════════════════════════════"
    echo ""
    for cmd in "${ALL_CMDS[@]}"; do
        echo "${cmd}"
        echo ""
    done
    echo "════════════════════════════════════════════════════════"
fi
