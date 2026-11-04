#!/usr/bin/env bash
#
# Synchronize database backups and encrypted sensitive-file backups.
#
# Run from anywhere:
#   ./backups/remote/sync.sh
#
# Configuration:
#   backups/remote/.env
#   backups/remote/paths.conf
#
# Remote files are never automatically deleted.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly PATHS_FILE="${SCRIPT_DIR}/paths.conf"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

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
: "${AGE_RECIPIENT:?AGE_RECIPIENT is required (age public recipient)}"

SSH_PORT="${SSH_PORT:-22}"
LOCK_WAIT_SECONDS="${LOCK_WAIT_SECONDS:-300}"

REMOTE_BACKUP_DIR="${REMOTE_BASE_DIR%/}/meal_project"
REMOTE_ENCRYPTED_DIR="${REMOTE_BASE_DIR%/}/encrypted"
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

[[ -f "${PATHS_FILE}" ]] \
    || die "Sensitive-file list not found: ${PATHS_FILE}"

command -v rsync >/dev/null 2>&1 || die "rsync is not installed."
command -v ssh >/dev/null 2>&1 || die "ssh is not installed."
command -v flock >/dev/null 2>&1 || die "flock is not installed."
command -v age >/dev/null 2>&1 || die "age is not installed."
command -v tar >/dev/null 2>&1 || die "tar is not installed."

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

# Read a plain, one-path-per-line list. Paths are relative to the repository
# root; comments and blank lines are ignored. Reject traversal and absolute paths.
SENSITIVE_PATHS=()
while IFS= read -r entry || [[ -n "${entry}" ]]; do
    entry="${entry%%#*}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "${entry}" ]] || continue
    [[ "${entry}" != /* && "${entry}" != *..* ]] \
        || die "Invalid sensitive-file path in ${PATHS_FILE}: ${entry}"
    [[ -f "${PROJECT_DIR}/${entry}" ]] \
        || die "Sensitive file not found: ${PROJECT_DIR}/${entry}"
    SENSITIVE_PATHS+=("${entry}")
done < "${PATHS_FILE}"

((${#SENSITIVE_PATHS[@]} > 0)) \
    || die "No sensitive-file paths configured in ${PATHS_FILE}."

SENSITIVE_ARCHIVE="${LOCAL_BACKUP_DIR}/sensitive_files_$(date '+%Y%m%d_%H%M%S')_$$.tar.age"
TEMP_ENCRYPTED="$(mktemp "${LOCAL_BACKUP_DIR}/.sensitive_files.XXXXXX")"
cleanup() {
    rm -f -- "${TEMP_ENCRYPTED}"
}
trap cleanup EXIT

log "Creating encrypted archive of ${#SENSITIVE_PATHS[@]} sensitive file(s)."
tar -C "${PROJECT_DIR}" -cf - -- "${SENSITIVE_PATHS[@]}" \
    | age --encrypt --recipient "${AGE_RECIPIENT}" --output "${TEMP_ENCRYPTED}" \
    || die "Sensitive-file encryption failed."
chmod 600 "${TEMP_ENCRYPTED}"
mv -- "${TEMP_ENCRYPTED}" "${SENSITIVE_ARCHIVE}"
log "Encrypted sensitive-file archive created: ${SENSITIVE_ARCHIVE}"

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
    "mkdir -p -- '${REMOTE_BACKUP_DIR}' '${REMOTE_ENCRYPTED_DIR}' && chmod 700 -- '${REMOTE_BACKUP_DIR}' '${REMOTE_ENCRYPTED_DIR}'" \
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

log "Synchronizing encrypted sensitive-file archive to ${REMOTE_HOST}:${REMOTE_ENCRYPTED_DIR}"
rsync \
    --archive \
    --human-readable \
    --partial \
    --itemize-changes \
    -e "${RSYNC_RSH}" \
    "${SENSITIVE_ARCHIVE}" \
    "${SSH_TARGET}:${REMOTE_ENCRYPTED_DIR}/" \
    || die "Encrypted sensitive-file synchronization failed."

log "Remote synchronization completed successfully."
log "Synchronized ${#BACKUP_FILES[@]} backup(s)."
log "Synchronized one encrypted sensitive-file archive."

