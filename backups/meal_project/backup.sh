
#!/usr/bin/env bash
#
# Create a weekly PostgreSQL backup of Meal_Project.
#
# Run from anywhere:
#   ./backups/meal_project/backup.sh
#
# Backups are stored outside the infrastructure repository.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../../meal_project" && pwd)"

readonly COMPOSE_BASE="${PROJECT_DIR}/compose/docker-compose.yml"
readonly COMPOSE_PROD="${PROJECT_DIR}/compose/docker-compose.prod.yml"
readonly ENV_FILE="${PROJECT_DIR}/compose/.env.prod"

readonly BACKUP_DIR="${MEAL_PROJECT_BACKUP_DIR:-${HOME}/backups/meal_project}"
readonly RETENTION_COUNT=12

readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
readonly BACKUP_FILE="${BACKUP_DIR}/meal_project_weekly_${TIMESTAMP}.dump"

TEMP_BACKUP=""

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    if [[ -n "${TEMP_BACKUP}" && -f "${TEMP_BACKUP}" ]]; then
        rm -f -- "${TEMP_BACKUP}"
    fi
}

trap cleanup EXIT

# Prevent overlapping backups.
mkdir -p -- "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

exec 9>"${BACKUP_DIR}/backup.lock"

if ! flock -n 9; then
    die "Another Meal_Project backup is already running."
fi

# Validate required configuration.
for file in "${COMPOSE_BASE}" "${COMPOSE_PROD}" "${ENV_FILE}"; do
    [[ -f "${file}" ]] || die "Required file not found: ${file}"
done

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

# Use the same Compose configuration as deploy.sh.
readonly COMPOSE_PROJECT_NAME="compose"

COMPOSE=(
    docker compose
    --project-directory "${PROJECT_DIR}"
    --env-file "${ENV_FILE}"
    -p "${COMPOSE_PROJECT_NAME}"
    -f "${COMPOSE_BASE}"
    -f "${COMPOSE_PROD}"
)

log "Starting Meal_Project weekly PostgreSQL backup."
log "Project directory: ${PROJECT_DIR}"
log "Backup directory: ${BACKUP_DIR}"

# Confirm PostgreSQL is running.
DB_ID="$("${COMPOSE[@]}" ps --status running -q db)"
[[ -n "${DB_ID}" ]] || die "PostgreSQL service (db) is not running."

# Create backup in a temporary file.
TEMP_BACKUP="$(mktemp "${BACKUP_DIR}/.meal_project_weekly.XXXXXX")"
chmod 600 "${TEMP_BACKUP}"

log "Creating PostgreSQL custom-format archive."

"${COMPOSE[@]}" exec -T db sh -ec '
    pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc
' > "${TEMP_BACKUP}" || die "PostgreSQL backup failed."

[[ -s "${TEMP_BACKUP}" ]] || die "Backup archive is empty."

# Verify the archive can be read.
log "Validating backup archive."

"${COMPOSE[@]}" exec -T db pg_restore --list \
    < "${TEMP_BACKUP}" > /dev/null \
    || die "Backup archive validation failed."

# Finalize backup.
mv -- "${TEMP_BACKUP}" "${BACKUP_FILE}"
TEMP_BACKUP=""

log "Backup successfully created: ${BACKUP_FILE}"
log "Backup size: $(du -h "${BACKUP_FILE}" | cut -f1)"

# Apply weekly retention policy.
log "Applying retention policy: keeping ${RETENTION_COUNT} weekly backups."

find "${BACKUP_DIR}" -maxdepth 1 -type f \
    -name 'meal_project_weekly_*.dump' \
    -printf '%T@ %p\n' |
    sort -rn |
    tail -n +$((RETENTION_COUNT + 1)) |
    cut -d' ' -f2- |
    while IFS= read -r old_backup; do
        [[ -n "${old_backup}" ]] || continue
        rm -f -- "${old_backup}"
        log "Removed expired weekly backup: ${old_backup}"
    done

log "Meal_Project weekly backup completed successfully."
