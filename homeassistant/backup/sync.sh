#!/usr/bin/env bash
#
# Synchronize completed Home Assistant backup archives to the C5.
#
# Run from anywhere:
#   ./homeassistant/backup/sync.sh
#
# Remote files are never automatically deleted.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly ENV_FILE="${PROJECT_DIR}/backups/remote/.env"
readonly NOTIFY_SCRIPT="${PROJECT_DIR}/notifications/notify.sh"

readonly HA_BACKUP_DIR="${HOME}/homeassistant/config/backups"
readonly LOG_DIR="${HOME}/backups/homeassistant"
readonly LOG_FILE="${LOG_DIR}/remote_sync.log"
readonly LOCK_FILE="${LOG_DIR}/sync.lock"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

notify() {
    local status="$1"
    local subject="$2"
    local message="$3"

    if ! "${NOTIFY_SCRIPT}" "${status}" "${subject}" "${message}"; then
        log "WARNING: Email notification failed."
        return 1
    fi
}

die() {
    local message="$1"
    log "ERROR: ${message}"
    notify failure "Home Assistant backup sync failed" "${message}" || true
    exit 1
}

# --------------------------------------------------
# Prepare logging and configuration
# --------------------------------------------------

umask 077
mkdir -p "${LOG_DIR}"
chmod 700 "${LOG_DIR}"

exec >> "${LOG_FILE}" 2>&1

log "Starting Home Assistant backup synchronization."

[[ -f "${ENV_FILE}" ]] || die "Remote configuration not found: ${ENV_FILE}"
[[ -x "${NOTIFY_SCRIPT}" ]] || die "Notification script missing or not executable."
[[ -d "${HA_BACKUP_DIR}" ]] || die "Home Assistant backup directory not found: ${HA_BACKUP_DIR}"

# This is a trusted, locally maintained configuration file.
source "${ENV_FILE}"

: "${REMOTE_HOST:?REMOTE_HOST is required}"
: "${REMOTE_USER:?REMOTE_USER is required}"
: "${REMOTE_BASE_DIR:?REMOTE_BASE_DIR is required}"
: "${SSH_KEY:?SSH_KEY is required}"

SSH_PORT="${SSH_PORT:-22}"
LOCK_WAIT_SECONDS=300

REMOTE_BACKUP_DIR="${REMOTE_BASE_DIR%/}/homeassistant"
SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

# --------------------------------------------------
# Validate configuration
# --------------------------------------------------

[[ "${REMOTE_HOST}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "Invalid REMOTE_HOST."

[[ "${REMOTE_USER}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "Invalid REMOTE_USER."

[[ "${SSH_PORT}" =~ ^[0-9]+$ ]] \
    || die "Invalid SSH_PORT."

[[ "${REMOTE_BASE_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "REMOTE_BASE_DIR must be an absolute path without spaces."

[[ -f "${SSH_KEY}" ]] || die "SSH private key not found: ${SSH_KEY}"

command -v rsync >/dev/null 2>&1 || die "rsync is not installed."
command -v ssh >/dev/null 2>&1 || die "ssh is not installed."
command -v flock >/dev/null 2>&1 || die "flock is not installed."
command -v tar >/dev/null 2>&1 || die "tar is not installed."
command -v sha256sum >/dev/null 2>&1 || die "sha256sum is not installed."

# --------------------------------------------------
# Acquire a dedicated sync lock
# --------------------------------------------------

exec 9>"${LOCK_FILE}"

if ! flock -w "${LOCK_WAIT_SECONDS}" 9; then
    die "Timed out waiting for another Home Assistant sync to finish."
fi

log "Acquired Home Assistant sync lock."

# --------------------------------------------------
# Find completed backup archives
# --------------------------------------------------

# Ignore archives modified within the last 15 minutes.
mapfile -d '' -t BACKUP_FILES < <(
    find "${HA_BACKUP_DIR}" \
        -maxdepth 1 \
        -type f \
        -name '*.tar' \
        -mmin +15 \
        -print0
)

((${#BACKUP_FILES[@]} > 0)) \
    || die "No completed Home Assistant backup archives older than 15 minutes were found."

log "Found ${#BACKUP_FILES[@]} eligible backup archive(s)."

# --------------------------------------------------
# Validate archive integrity
# --------------------------------------------------

for backup in "${BACKUP_FILES[@]}"; do
    filename="$(basename "${backup}")"

    [[ "${filename}" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "Unexpected backup filename: ${filename}"

    log "Checking archive: ${filename}"

    tar -tf "${backup}" >/dev/null \
        || die "Archive integrity check failed: ${filename}"
done

log "All selected archive integrity checks passed."

# --------------------------------------------------
# Configure SSH and prepare remote destination
# --------------------------------------------------

SSH_ARGS=(
    -p "${SSH_PORT}"
    -i "${SSH_KEY}"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=2
)

log "Checking remote destination: ${SSH_TARGET}"

ssh "${SSH_ARGS[@]}" "${SSH_TARGET}" \
    "mkdir -p -- '${REMOTE_BACKUP_DIR}' && chmod 700 -- '${REMOTE_BACKUP_DIR}'" \
    || die "Unable to access or prepare the remote Home Assistant backup directory."

RSYNC_RSH="ssh -p ${SSH_PORT} -i ${SSH_KEY} -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"

# --------------------------------------------------
# Synchronize archives
# --------------------------------------------------

log "Synchronizing archives to ${REMOTE_HOST}:${REMOTE_BACKUP_DIR}"

rsync \
    --archive \
    --human-readable \
    --partial \
    --checksum \
    --itemize-changes \
    -e "${RSYNC_RSH}" \
    "${BACKUP_FILES[@]}" \
    "${SSH_TARGET}:${REMOTE_BACKUP_DIR}/" \
    || die "Home Assistant backup synchronization failed."

log "Rsync completed. Verifying remote SHA256 checksums."

# --------------------------------------------------
# Verify remote checksums
# --------------------------------------------------

for backup in "${BACKUP_FILES[@]}"; do
    filename="$(basename "${backup}")"

    local_hash="$(sha256sum "${backup}" | awk '{print $1}')"

    remote_hash="$(
        ssh "${SSH_ARGS[@]}" "${SSH_TARGET}" \
            "sha256sum -- '${REMOTE_BACKUP_DIR}/${filename}'" \
            | awk '{print $1}'
    )"

    [[ "${local_hash}" == "${remote_hash}" ]] \
        || die "SHA256 mismatch for ${filename}"

    log "Verified SHA256: ${filename}"
done

# --------------------------------------------------
# Complete
# --------------------------------------------------

log "Home Assistant backup synchronization completed successfully."
log "Verified ${#BACKUP_FILES[@]} archive(s) on the remote host."

notify success \
    "Home Assistant backup sync completed" \
    "Successfully synchronized and SHA256-verified ${#BACKUP_FILES[@]} Home Assistant backup archive(s) on ${REMOTE_HOST}:${REMOTE_BACKUP_DIR}."

log "Success notification sent."
