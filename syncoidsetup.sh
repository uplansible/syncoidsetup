#!/usr/bin/env bash
# syncoidsetup.sh — v0.2.17
# Run on your MANAGEMENT machine (laptop/workstation) — NOT on the backup server.
# Requires SSH access (with sudo rights) to both the backup server and all prod servers.
#
# Usage:
#   ./syncoidsetup.sh [--site <name>] --backup [backupuser@]backuphost \
#                     --remote [remoteuser@]remotehost \
#                     [--remote [remoteuser2@]remotehost2 ...]
#
# --site   Optional. Defaults to the backup server's short hostname.
# user@    Optional for both --backup and --remote; defaults to $USER.
#
# Examples:
#   ./syncoidsetup.sh --backup admin@100.64.0.10 --remote ubuntu@100.64.0.1
#   ./syncoidsetup.sh --site homelab --backup 100.64.0.10 \
#                     --remote ubuntu@100.64.0.1 --remote root@100.64.0.2

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
SEND_USER="sendsyncoid"
REC_USER="recsyncoid"
# ─────────────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [--site <name>] --backup [user@]host --remote [user@]host [--remote [user@]host2 ...]"
    echo "       --site     Optional. Site name for this backup set (defaults to the backup server's short hostname)."
    echo "       --backup   Backup server in [user@]host format (user defaults to \$USER)."
    echo "       --remote   Production server(s) in [user@]host format (user defaults to \$USER). Repeatable."
    exit 1
}

[[ $EUID -eq 0 ]] && { echo "Do NOT run this script as root. Run as your normal user."; exit 1; }

SITE_NAME=""
BACKUP_HOST=""
BACKUP_USER=""
PROD_SERVERS=()
PROD_USERS=()


# Split [user@]host into _SPLIT_USER and _SPLIT_HOST; user defaults to $USER
split_userhost() {
    local val="$1"
    if [[ "${val}" == *@* ]]; then
        _SPLIT_USER="${val%%@*}"
        _SPLIT_HOST="${val#*@}"
    else
        _SPLIT_USER="${USER}"
        _SPLIT_HOST="${val}"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site)
            SITE_NAME="$2"
            shift 2 ;;
        --backup)
            split_userhost "$2"
            BACKUP_USER="${_SPLIT_USER}"
            BACKUP_HOST="${_SPLIT_HOST}"
            shift 2 ;;
        --remote)
            split_userhost "$2"
            PROD_USERS+=("${_SPLIT_USER}")
            PROD_SERVERS+=("${_SPLIT_HOST}")
            shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1" >&2; usage ;;
    esac
done

if [[ -z "${SITE_NAME}" ]]; then
    if [[ "${BACKUP_HOST}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        # Try reverse DNS; fall back to IP with dots replaced by dashes
        _REV=$(getent hosts "${BACKUP_HOST}" 2>/dev/null | awk '{print $2; exit}' || true)
        if [[ -n "${_REV}" ]]; then
            SITE_NAME="${_REV%%.*}"
        else
            SITE_NAME="${BACKUP_HOST//./-}"
        fi
        unset _REV
    else
        SITE_NAME="${BACKUP_HOST%%.*}"    # FQDN/hostname → short name
    fi
fi
[[ -z "${BACKUP_HOST}" ]] && { echo "[ERROR] --backup [user@]host is required." >&2; usage; }
[[ ${#PROD_SERVERS[@]} -eq 0 ]] && { echo "[ERROR] At least one --remote [user@]host is required." >&2; usage; }

# ── Input validation ──────────────────────────────────────────────────────────
if [[ ! "${SITE_NAME}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "[ERROR] Invalid site-name '${SITE_NAME}': only letters, digits, '.', '_', and '-' are allowed." >&2
    exit 1
fi

if [[ ! "${BACKUP_HOST}" =~ ^[][a-zA-Z0-9._:-]+$ ]]; then
    echo "[ERROR] Invalid backup host '${BACKUP_HOST}'." >&2
    exit 1
fi

for SERVER in "${PROD_SERVERS[@]}"; do
    if [[ ! "${SERVER}" =~ ^[][a-zA-Z0-9._:-]+$ ]]; then
        echo "[ERROR] Invalid server '${SERVER}': only letters, digits, '.', '_', ':', '[', ']', and '-' are allowed." >&2
        exit 1
    fi
done

# ── TCP reachability pre-check ────────────────────────────────────────────────
# Checks port 22 only — does not test SSH authentication.
echo "[INFO] Checking TCP reachability of all servers (port 22)..."
ALL_HOSTS=("${BACKUP_HOST}" "${PROD_SERVERS[@]}")
for SERVER in "${ALL_HOSTS[@]}"; do
    if command -v nc > /dev/null 2>&1; then
        if ! nc -z -w 5 "${SERVER}" 22 2>/dev/null; then
            echo "[ERROR] Cannot reach ${SERVER}:22 — aborting before making any changes." >&2
            exit 1
        fi
        echo "[OK] Reachable: ${SERVER}"
    else
        echo "[WARN] nc not found — skipping TCP reachability check for ${SERVER}."
    fi
done

# BACKUP_IP for the authorized_keys from= restriction is resolved after SSH connection
# to the backup server (see below), so the correct outgoing IP is used rather than
# the IP as seen from this management machine.
# Honour a pre-set BACKUP_IP env var to override.
if [[ -n "${BACKUP_IP:-}" ]]; then
    echo "[INFO] Using pre-set BACKUP_IP=${BACKUP_IP}"
fi

# ── SSH ControlMaster — one TCP connection per host, reused for all SSH calls ──
_CTLDIR=$(mktemp -d)
trap 'rm -rf "${_CTLDIR}"' EXIT
SSH_CTL=(-o ControlMaster=auto -o "ControlPath=${_CTLDIR}/%h_%p_%r" -o ControlPersist=60)

KEY_PATH="${HOME}/.ssh/id_ed25519_${SITE_NAME}_syncoid"
KEY_COMMENT="${SITE_NAME}-backup-syncoid"

# ── 1. Generate key pair on the management machine (no sudo needed) ───────────
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
# Encode keys as single-line base64 for safe transfer via heredoc
PRIVKEY_B64=$(base64 -w0 "${KEY_PATH}")
PUBKEY_B64=$(base64 -w0 "${KEY_PATH}.pub")

# ── Sudo password (asked once, reused for all remote servers) ─────────────────
_sudo_pass=""
read -rsp "[PROMPT] Sudo password for remote servers (press Enter if passwordless): " _sudo_pass
echo ""
SUDO_B64=$(printf '%s' "${_sudo_pass}" | base64 -w0)
unset _sudo_pass

# ── 2. Set up recsyncoid on the backup server ─────────────────────────────────
echo ""
echo "[INFO] Setting up ${REC_USER} on backup server ${BACKUP_HOST} (connecting as ${BACKUP_USER})..."


ssh -T "${SSH_CTL[@]}" "${BACKUP_USER}@${BACKUP_HOST}" bash -s \
    2> >(sed "s/^/[${BACKUP_HOST}] /" >&2) \
    << BACKUPEOF
set -euo pipefail

_SUDO_B64="${SUDO_B64}"
_sudo() {
    if [[ -n "\${_SUDO_B64}" ]]; then
        printf '%s\n' "\$(printf '%s' "\${_SUDO_B64}" | base64 -d)" | sudo -S -p '' "\$@"
    else
        sudo "\$@"
    fi
}

REM_REC_HOME=\$(getent passwd "${REC_USER}" | cut -d: -f6 || true)
if [[ -z "\${REM_REC_HOME}" ]]; then
    _sudo useradd --system --no-create-home --shell /usr/sbin/nologin "${REC_USER}"
    REM_REC_HOME=\$(getent passwd "${REC_USER}" | cut -d: -f6)
    echo "[OK] Created system user ${REC_USER}."
fi

REM_SSH_DIR="\${REM_REC_HOME}/.ssh"
REM_KEY_PATH="\${REM_SSH_DIR}/id_ed25519_${SITE_NAME}_syncoid"

_sudo mkdir -p "\${REM_SSH_DIR}"
_sudo chmod 700 "\${REM_SSH_DIR}"
_sudo chown "${REC_USER}:${REC_USER}" "\${REM_SSH_DIR}"

if _sudo test -f "\${REM_KEY_PATH}"; then
    _sudo cp "\${REM_KEY_PATH}" "\${REM_KEY_PATH}.bak"
    echo "[WARN] Existing private key backed up to \${REM_KEY_PATH}.bak"
fi

# Decode and install private key from base64
TMPPRIV=\$(mktemp)
echo "${PRIVKEY_B64}" | base64 -d > "\${TMPPRIV}"
_sudo install -m 600 -o "${REC_USER}" -g "${REC_USER}" "\${TMPPRIV}" "\${REM_KEY_PATH}"
rm -f "\${TMPPRIV}"

# Decode and install public key from base64
TMPPUB=\$(mktemp)
echo "${PUBKEY_B64}" | base64 -d > "\${TMPPUB}"
_sudo install -m 644 -o "${REC_USER}" -g "${REC_USER}" "\${TMPPUB}" "\${REM_KEY_PATH}.pub"
rm -f "\${TMPPUB}"

if command -v usermod > /dev/null; then
    _sudo usermod -s /usr/sbin/nologin "${REC_USER}"
else
    echo "[WARN] usermod not found — set shell for ${REC_USER} to /usr/sbin/nologin manually."
fi
if command -v passwd > /dev/null; then
    _sudo passwd -l "${REC_USER}" > /dev/null
else
    echo "[WARN] passwd not found — lock account for ${REC_USER} manually."
fi

# Grant ZFS receive permissions on every pool root so recsyncoid can receive streams.
# Permissions propagate to all child datasets; zfs allow is idempotent.
for _pool in \$(zfs list -H -o name -d 0 2>/dev/null || true); do
    _sudo zfs allow -u "${REC_USER}" receive,create,mount,compression "\${_pool}"
    echo "[OK] ZFS permissions (receive,create,mount,compression) granted to ${REC_USER} on \${_pool}"
done

echo "[OK] ${REC_USER} hardened and keys installed on \$(hostname)."
BACKUPEOF

# Fetch REC_HOME from backup server so we can reference the key path in generated commands
REC_HOME=$(ssh "${SSH_CTL[@]}" -o ConnectTimeout=10 "${BACKUP_USER}@${BACKUP_HOST}" \
    "getent passwd ${REC_USER} | cut -d: -f6")
REC_SSH_DIR="${REC_HOME}/.ssh"
REC_KEY_PATH="${REC_SSH_DIR}/id_ed25519_${SITE_NAME}_syncoid"

# Resolve BACKUP_IP from the backup server's perspective so the from= restriction
# matches the IP it actually uses when connecting outbound to production servers.
if [[ -z "${BACKUP_IP:-}" ]]; then
    _PROBE="${PROD_SERVERS[0]}"
    BACKUP_IP=$(ssh "${SSH_CTL[@]}" -o ConnectTimeout=10 "${BACKUP_USER}@${BACKUP_HOST}" \
        "ip route get '${_PROBE}' 2>/dev/null | awk 'NR==1{for(i=1;i<NF;i++) if(\$i==\"src\"){print \$(i+1); exit}}' || \
         ip route get 8.8.8.8 2>/dev/null | awk 'NR==1{for(i=1;i<NF;i++) if(\$i==\"src\"){print \$(i+1); exit}}' || \
         hostname -I 2>/dev/null | awk '{print \$1}'" 2>/dev/null || true)
    if [[ -z "${BACKUP_IP}" ]]; then
        echo "[ERROR] Could not determine backup server's outgoing IP for from= restriction." >&2
        echo "        Set BACKUP_IP=<ip> in the environment to override." >&2
        exit 1
    fi
    echo "[INFO] Backup server IP for from= restriction: ${BACKUP_IP}"
fi

# ── 3. Build authorized_keys entry with from= source-IP restriction ───────────
# No command= restriction: sshd executes commands via the user's shell, and
# /usr/sbin/nologin (the security shell) would ignore -c and block everything.
# Security comes from: restrict (no forwarding/pty), from= IP, and key-only auth.
# Base64-encode to avoid quoting issues when embedded in the remote heredoc.
AUTH_ENTRY="restrict,from=\"${BACKUP_IP}\" ${PUB_KEY}"
AUTH_ENTRY_B64=$(printf '%s' "${AUTH_ENTRY}" | base64 -w0)

# ── 4. Push public key to each production server via SSH ──────────────────────
for i in "${!PROD_SERVERS[@]}"; do
    HOST="${PROD_SERVERS[$i]}"
    REMOTE_ADMIN_USER="${PROD_USERS[$i]}"
    echo ""
    echo "[INFO] Deploying key to ${SEND_USER}@${HOST} (connecting as ${REMOTE_ADMIN_USER})..."

    ssh -T "${SSH_CTL[@]}" "${REMOTE_ADMIN_USER}@${HOST}" bash -s \
        2> >(sed "s/^/[${HOST}] /" >&2) \
        << REMOTEEOF
set -euo pipefail
command -v bash > /dev/null || { echo "[ERROR] bash not found on ${HOST}"; exit 1; }

_SUDO_B64="${SUDO_B64}"
_sudo() {
    if [[ -n "\${_SUDO_B64}" ]]; then
        printf '%s\n' "\$(printf '%s' "\${_SUDO_B64}" | base64 -d)" | sudo -S -p '' "\$@"
    else
        sudo "\$@"
    fi
}

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
    _sudo useradd --system --no-create-home --shell /bin/sh "${SEND_USER}"
    SEND_HOME=\$(getent passwd "${SEND_USER}" | cut -d: -f6)
fi
SSH_DIR="\${SEND_HOME}/.ssh"
AUTH_FILE="\${SSH_DIR}/authorized_keys"

_sudo mkdir -p "\${SSH_DIR}"
_sudo chmod 700 "\${SSH_DIR}"
_sudo chown "${SEND_USER}:${SEND_USER}" "\${SSH_DIR}"

# Avoid duplicate entries by comparing SSH fingerprints
TMPKEY=\$(mktemp)
printf '%s\n' "${PUB_KEY}" > "\${TMPKEY}"
NEW_FP=\$(ssh-keygen -lf "\${TMPKEY}" | awk '{print \$2}')
rm -f "\${TMPKEY}"

ALREADY_PRESENT=false
if _sudo test -f "\${AUTH_FILE}"; then
    if _sudo ssh-keygen -lf "\${AUTH_FILE}" 2>/dev/null | awk '{print \$2}' | grep -qF "\${NEW_FP}"; then
        ALREADY_PRESENT=true
    fi
fi

if \${ALREADY_PRESENT}; then
    echo "[INFO] Key already present in \${AUTH_FILE} (fingerprint match), skipping."
else
    # Write to a temp file first — avoids stdin conflict where _sudo's password
    # pipe consumes stdin before tee can read the auth entry from it.
    # \$1 / \$2 are escaped so the local shell doesn't expand them; they are
    # passed as positional args to bash -c on the remote.
    TMPAUTH=\$(mktemp)
    printf '%s\n' "\$(printf '%s' "${AUTH_ENTRY_B64}" | base64 -d)" > "\${TMPAUTH}"
    _sudo bash -c 'cat "\$1" >> "\$2"' -- "\${TMPAUTH}" "\${AUTH_FILE}"
    rm -f "\${TMPAUTH}"
    echo "[OK] Key appended to \${AUTH_FILE}"
fi

_sudo chmod 600 "\${AUTH_FILE}"
_sudo chown "${SEND_USER}:${SEND_USER}" "\${AUTH_FILE}"

# Harden remote sendsyncoid account
# Shell must be /bin/sh (not nologin) — sshd runs commands via the shell,
# and nologin ignores -c, blocking all SSH command execution.
# Security is enforced by the authorized_keys restrict+from= restrictions.
if command -v usermod > /dev/null; then
    _sudo usermod -s /bin/sh "${SEND_USER}"
else
    echo "[WARN] usermod not found — set shell for ${SEND_USER} to /bin/sh manually."
fi
if command -v passwd > /dev/null; then
    _sudo passwd -l "${SEND_USER}" > /dev/null
else
    echo "[WARN] passwd not found — lock account for ${SEND_USER} manually."
fi

# Grant ZFS delegation on every pool root so sendsyncoid can send snapshots.
# Permissions propagate to all child datasets; zfs allow is idempotent.
for _pool in \$(zfs list -H -o name -d 0 2>/dev/null || true); do
    _sudo zfs allow -u "${SEND_USER}" send,snapshot,hold,destroy "\${_pool}"
    echo "[OK] ZFS permissions (send,snapshot,hold,destroy) granted to ${SEND_USER} on \${_pool}"
done

echo "[OK] ${SEND_USER} hardened on \$(hostname)"
REMOTEEOF

    echo "[OK] Done with ${HOST}"
done

# ── 5. Summary ────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo " Setup complete for site: ${SITE_NAME}"
echo " Key (this machine): ${KEY_PATH}"
echo " Key (backup server ${BACKUP_HOST}): ${REC_KEY_PATH}"
echo " Deployed to: ${PROD_SERVERS[*]}"
echo ""
echo " Generic syncoid template (run on ${BACKUP_HOST}):"
echo "   sudo -H -u ${REC_USER} bash -c \\"
echo "     'syncoid --no-privilege-elevation --sshkey=${REC_KEY_PATH} ${SEND_USER}@<prod-host>:pool/dataset pool/backup/${SITE_NAME}/dataset'"
echo "════════════════════════════════════════════════════════"

# ── 6. Interactive wizard — generate ready-to-use syncoid commands ────────────
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

# Collect ZFS datasets from the backup server for the destination picker
LOCAL_DATASETS=()
mapfile -t LOCAL_DATASETS < <(
    ssh "${SSH_CTL[@]}" -o ConnectTimeout=10 "${BACKUP_USER}@${BACKUP_HOST}" \
        "zfs list -H -o name" 2>/dev/null || true
)

ALL_CMDS=()  # accumulates all generated commands across hosts

for i in "${!PROD_SERVERS[@]}"; do
    HOST="${PROD_SERVERS[$i]}"
    REMOTE_ADMIN_USER="${PROD_USERS[$i]}"

    echo ""
    echo "┌─ Host: ${HOST} ──────────────────────────────────────────"

    # Fetch remote dataset list via admin SSH (sendsyncoid key has command= restriction)
    mapfile -t REMOTE_LINES < <(
        ssh "${SSH_CTL[@]}" -o ConnectTimeout=5 "${REMOTE_ADMIN_USER}@${HOST}" \
            "zfs list -H -r -o name,encryption,keystatus" 2>/dev/null || true
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
    for ((j=0; j<${#DS_NAMES[@]}; j++)); do
        enc_label=""
        [[ "${DS_ENCS[$j]}" != "off" && "${DS_ENCS[$j]}" != "-" ]] && enc_label="  [encrypted]"
        printf "│    [%2d] %s%s\n" "$((j+1))" "${DS_NAMES[$j]}" "${enc_label}"
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
        for ((j=0; j<${#DS_NAMES[@]}; j++)); do
            if [[ "${DS_NAMES[$j]}" == "${ds}" && \
                  "${DS_ENCS[$j]}" != "off" && "${DS_ENCS[$j]}" != "-" && "${DS_ENCS[$j]}" != "unknown" ]]; then
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

    # Destination parent on the backup server
    echo "│"
    if [[ ${#LOCAL_DATASETS[@]} -gt 0 ]]; then
        echo "│  ZFS datasets on backup server ${BACKUP_HOST} (select destination parent):"
        for ((j=0; j<${#LOCAL_DATASETS[@]}; j++)); do
            printf "│    [%2d] %s\n" "$((j+1))" "${LOCAL_DATASETS[$j]}"
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
        read -r -p "│  > Destination parent dataset on ${BACKUP_HOST} (e.g. tank/backup): " LOCAL_PARENT || true
    fi

    if [[ -z "${LOCAL_PARENT}" ]]; then
        echo "│ [WARN] No destination specified — skipping ${HOST}."
        echo "└──────────────────────────────────────────────────────────"
        continue
    fi

    # Ask once per host for the middle path component used in default destinations
    echo "│"
    read -r -p "│  > Middle path component for destinations [backup]: " DEST_MIDDLE || true
    [[ -z "${DEST_MIDDLE}" ]] && DEST_MIDDLE="backup"

    # Ensure the parent path exists on the backup server before first receive
    DEST_PARENT="${LOCAL_PARENT}/${DEST_MIDDLE}"
    echo "│"
    if ssh "${SSH_CTL[@]}" -o ConnectTimeout=10 "${BACKUP_USER}@${BACKUP_HOST}" \
            "zfs list -H -o name '${DEST_PARENT}' > /dev/null 2>&1"; then
        echo "│  [INFO] Destination parent ${DEST_PARENT} already exists."
    else
        if ssh "${SSH_CTL[@]}" -o ConnectTimeout=10 "${BACKUP_USER}@${BACKUP_HOST}" \
                "sudo zfs create -p '${DEST_PARENT}'" 2>/dev/null; then
            echo "│  [OK] Created destination parent: ${DEST_PARENT}"
        else
            echo "│  [WARN] Could not create ${DEST_PARENT} — create it manually before running syncoid."
        fi
    fi

    # Build commands per selected dataset
    HOST_CMDS=("# ── syncoid commands for site: ${SITE_NAME} / host: ${HOST}")
    echo "│"
    echo "│  Confirm destinations (press Enter to accept default, or type full path to override):"

    for ds in "${FILTERED_NAMES[@]}"; do
        LEAF="${ds##*/}"
        DEFAULT_DEST="${LOCAL_PARENT}/${DEST_MIDDLE}/${LEAF}"
        read -r -p "│    '${ds}' → [${DEFAULT_DEST}]: " CUSTOM_DEST || true
        DEST="${DEFAULT_DEST}"
        if [[ -n "${CUSTOM_DEST}" ]]; then
            if [[ "${CUSTOM_DEST}" == */* ]]; then
                DEST="${CUSTOM_DEST}"                              # full path override
            else
                DEST="${LOCAL_PARENT}/${DEST_MIDDLE}/${CUSTOM_DEST}"  # leaf rename only
            fi
        fi

        # Check encryption for this specific dataset
        DS_IS_ENC=false
        for ((j=0; j<${#DS_NAMES[@]}; j++)); do
            if [[ "${DS_NAMES[$j]}" == "${ds}" && \
                  "${DS_ENCS[$j]}" != "off" && "${DS_ENCS[$j]}" != "-" && "${DS_ENCS[$j]}" != "unknown" ]]; then
                DS_IS_ENC=true
                break
            fi
        done

        CMD="sudo -H -u ${REC_USER} bash -c \\"$'\n'
        CMD+="  'syncoid --no-privilege-elevation"
        CMD+=" --sshkey=${REC_KEY_PATH}"
        CMD+=" --recvoptions=p"
        if ${DS_IS_ENC} && [[ "${ENC_POLICY}" == "raw" ]]; then
            CMD+=" --sendoptions=w"
        fi
        CMD+=" ${SEND_USER}@${HOST}:${ds}"
        CMD+=" ${DEST}'"

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

# Final clean printout of all commands + write inventory file
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

    # Write inventory file — a ready-to-run shell script saved locally
    INVENTORY_DIR="${HOME}/.syncoid"
    INVENTORY_FILE="${INVENTORY_DIR}/${SITE_NAME}.sh"
    mkdir -p "${INVENTORY_DIR}"
    {
        echo "#!/usr/bin/env bash"
        echo "# Syncoid replication commands for site: ${SITE_NAME}"
        echo "# Backup server:      ${BACKUP_USER}@${BACKUP_HOST}"
        echo "# Production servers: ${PROD_SERVERS[*]}"
        echo "# Generated:          $(date '+%Y-%m-%d')"
        echo "#"
        echo "# Run these commands on the backup server (${BACKUP_HOST})."
        echo "# Each command uses 'sudo -H -u ${REC_USER} bash -c ...' so it can be"
        echo "# executed by any admin user, or scheduled via cron/systemd on the backup server."
        echo ""
        for cmd in "${ALL_CMDS[@]}"; do
            echo "${cmd}"
            echo ""
        done
    } > "${INVENTORY_FILE}"
    chmod 755 "${INVENTORY_FILE}"
    echo ""
    echo "[OK] Commands saved to: ${INVENTORY_FILE}"
fi
