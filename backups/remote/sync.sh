#!/usr/bin/env bash
#
# Synchronize completed Meal_Project backups to a remote host.
#
# Run from anywhere:
#   ./backups/remote/sync.sh
#
# Configuration:
#   backups/remote/.env
#
# Remote files are never automatically deleted.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

# Load configuration.
[[ -f "${ENV_FILE}" ]] || die "Configuration file not found: ${ENV_FILE}"

# .env is a trusted, locally maintained shell configuration file.
source "${ENV_FILE}"

# Validate required configuration.
: "${REMOTE_HOST:?REMOTE_HOST is required}"
: "${REMOTE_USER:?REMOTE_USER is required}"
: "${REMOTE_BASE_DIR:?REMOTE_BASE_DIR is required}"
: "${SSH_KEY:?SSH_KEY is required}"
: "${LOCAL_BACKUP_DIR:?LOCAL_BACKUP_DIR is required}"

SSH_PORT="${SSH_PORT:-22}"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-300}"

REMOTE_BACKUP_DIR="${REMOTE_BASE_DIR%/}/meal_project"
LOCK_FILE="${LOCAL_BACKUP_DIR}/operation.lock"

# Validate configuration.
[[ "${REMOTE_HOST}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "Invalid REMOTE_HOST."

[[ "${REMOTE_USER}" =~ ^[A-Za-z0-9._-]+$ ]] \
    || die "Invalid REMOTE_USER."

[[ "${SSH_PORT}" =~ ^[0-9]+$ ]] \
    || die "Invalid SSH_PORT."

[[ "${LOCK_WAIT_SECONDS}" =~ ^[0-9]+$ ]] \
    || die "Invalid LOCK_WAIT_SECONDS."

[[ "${REMOTE_BASE_DIR}" =~ ^/[A-Za-z0-9._/-]+$ ]] \
    || die "REMOTE_BASE_DIR must be an absolute path without spaces."

[[ -d "${LOCAL_BACKUP_DIR}" ]] \
    || die "Local backup directory not found: ${LOCAL_BACKUP_DIR}"

[[ -f "${LOCK_FILE}" ]] \
    || die "Operation lock file not found: ${LOCK_FILE}"

[[ -f "${SSH_KEY}" ]] \
    || die "SSH private key not found: ${SSH_KEY}"

command -v rsync >/dev/null 2>&1 || die "rsync is not installed."
command -v ssh >/dev/null 2>&1 || die "ssh is not installed."
command -v flock >/dev/null 2>&1 || die "flock is not installed."

# Acquire a shared lock.
# This prevents synchronization during a database backup and
# prevents a new backup from starting during synchronization.
exec 9<"${LOCK_FILE}"

log "Waiting for Meal_Project operations to finish."

if ! flock -s -w "${LOCK_WAIT_SECONDS}" 9; then
    die "Timed out waiting for the Meal_Project operation lock."
fi

log "Acquired shared operation lock."

# Find completed database dumps.
shopt -s nullglob
BACKUP_FILES=("${LOCAL_BACKUP_DIR}"/*.dump)

((${#BACKUP_FILES[@]} > 0)) \
    || die "No completed .dump files found."

log "Found ${#BACKUP_FILES[@]} completed backup(s)."

# Configure SSH.
SSH_ARGS=(
    -p "${SSH_PORT}"
    -i "${SSH_KEY}"
    -o BatchMode=yes
    -o IdentitiesOnly=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=2
)

SSH_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

log "Checking remote destination: ${SSH_TARGET}"

# Create the remote destination if necessary.
ssh "${SSH_ARGS[@]}" "${SSH_TARGET}" \
    "mkdir -p -- '${REMOTE_BACKUP_DIR}' && chmod 700 -- '${REMOTE_BACKUP_DIR}'" \
    || die "Unable to access or prepare remote destination."

# Synchronize completed dumps.
RSYNC_RSH="ssh -p ${SSH_PORT} -i ${SSH_KEY} -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=2"

log "Synchronizing backups to ${REMOTE_HOST}:${REMOTE_BACKUP_DIR}"

rsync \
    --archive \
    --human-readable \
    --partial \
    --itemize-changes \
    --include='*.dump' \
    --exclude='*' \
    -e "${RSYNC_RSH}" \
    "${LOCAL_BACKUP_DIR}/" \
    "${SSH_TARGET}:${REMOTE_BACKUP_DIR}/" \
    || die "Remote synchronization failed."

log "Remote synchronization completed successfully."
log "Synchronized ${#BACKUP_FILES[@]} backup(s)."

