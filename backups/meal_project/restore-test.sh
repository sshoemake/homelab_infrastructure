
#!/usr/bin/env bash
#
# Restore-test a Meal_Project PostgreSQL backup.
#
# Usage:
#   ./restore-test.sh
#   ./restore-test.sh /path/to/backup.dump
#
# Defaults to the newest weekly backup.
# Restores into an isolated temporary database.
# Never modifies the production database.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../../meal_project" && pwd)"

readonly COMPOSE_BASE="${PROJECT_DIR}/compose/docker-compose.yml"
readonly COMPOSE_PROD="${PROJECT_DIR}/compose/docker-compose.prod.yml"
readonly ENV_FILE="${PROJECT_DIR}/compose/.env.prod"

readonly BACKUP_DIR="${MEAL_PROJECT_BACKUP_DIR:-${HOME}/backups/meal_project}"

DB_NAME=""
DB_OWNER=""

readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
readonly TEST_DB="mealprojectdb_restore_test_${TIMESTAMP}_$$"

DB_CREATED=false

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

cleanup() {
    local exit_code=$?

    trap - EXIT

    if [[ "${DB_CREATED}" == true ]]; then
        log "Removing temporary database: ${TEST_DB}"

        if docker_compose exec -T db \
            dropdb --if-exists --force -U "${DB_OWNER}" "${TEST_DB}"; then
            log "Temporary database removed."
        else
            log "ERROR: Could not remove temporary database: ${TEST_DB}"
            log "Manual cleanup may be required."
            exit_code=1
        fi
    fi

    exit "${exit_code}"
}

trap cleanup EXIT

# Validate arguments.
[[ $# -le 1 ]] || die "Usage: $0 [backup-file]"

# Find the backup to test.
if [[ $# -eq 1 ]]; then
    BACKUP_FILE="$1"
else
    BACKUP_FILE="$(
        find "${BACKUP_DIR}" -maxdepth 1 -type f \
            -name 'meal_project_weekly_*.dump' \
            -printf '%T@ %p\n' |
            sort -rn |
            head -n 1 |
            cut -d' ' -f2-
    )"
fi

[[ -n "${BACKUP_FILE}" ]] || die "No weekly backup found."
[[ -f "${BACKUP_FILE}" ]] || die "Backup file not found: ${BACKUP_FILE}"

BACKUP_FILE="$(cd -- "$(dirname -- "${BACKUP_FILE}")" && pwd)/$(basename -- "${BACKUP_FILE}")"

# Validate configuration.
for file in "${COMPOSE_BASE}" "${COMPOSE_PROD}" "${ENV_FILE}"; do
    [[ -f "${file}" ]] || die "Required file not found: ${file}"
done

command -v docker >/dev/null 2>&1 || die "Docker is not installed."
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

# Match the Compose interpolation used by deploy.sh.
export MEAL_PROJECT_IMAGE="ghcr.io/sshoemake/meal_project"
export MEAL_PROJECT_VERSION="restore-test"

readonly COMPOSE_PROJECT_NAME="compose"

docker_compose() {
    docker compose \
        --project-directory "${PROJECT_DIR}" \
        --env-file "${ENV_FILE}" \
        -p "${COMPOSE_PROJECT_NAME}" \
        -f "${COMPOSE_BASE}" \
        -f "${COMPOSE_PROD}" \
        "$@"
}

DB_NAME="$(docker_compose exec -T db sh -ec 'printf "%s" "$POSTGRES_DB"')"
DB_OWNER="$(docker_compose exec -T db sh -ec 'printf "%s" "$POSTGRES_USER"')"

[[ -n "${DB_NAME}" ]] || die "POSTGRES_DB is not configured."
[[ -n "${DB_OWNER}" ]] || die "POSTGRES_USER is not configured."

log "Starting Meal_Project restore test."
log "Backup: ${BACKUP_FILE}"
log "Production database: ${DB_NAME}"
log "Temporary database: ${TEST_DB}"

# Confirm the production database container is running.
DB_ID="$(docker_compose ps --status running -q db)"
[[ -n "${DB_ID}" ]] || die "PostgreSQL service is not running."

# Verify the expected production database configuration.
ACTUAL_DB="$(docker_compose exec -T db sh -ec 'printf "%s" "$POSTGRES_DB"')"
ACTUAL_OWNER="$(docker_compose exec -T db sh -ec 'printf "%s" "$POSTGRES_USER"')"

[[ "${ACTUAL_DB}" == "${DB_NAME}" ]] || die "Unexpected production database name: ${ACTUAL_DB}"
[[ "${ACTUAL_OWNER}" == "${DB_OWNER}" ]] || die "Unexpected database owner: ${ACTUAL_OWNER}"

# Verify archive readability before creating a database.
log "Validating backup archive."

docker_compose exec -T db pg_restore --list \
    < "${BACKUP_FILE}" > /dev/null \
    || die "Backup archive is invalid."

# Confirm temporary database does not already exist.
EXISTING_DB="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d postgres \
        -c "SELECT 1 FROM pg_database WHERE datname = '${TEST_DB}';"
)"

[[ -z "${EXISTING_DB}" ]] || die "Temporary database already exists."

# Create an isolated database.
log "Creating temporary database."

docker_compose exec -T db \
    createdb -U "${DB_OWNER}" -T template0 -O "${DB_OWNER}" "${TEST_DB}"

DB_CREATED=true

# Restore the archive.
log "Restoring PostgreSQL archive."

docker_compose exec -T db \
    pg_restore \
        --exit-on-error \
        --no-owner \
        --no-privileges \
        -U "${DB_OWNER}" \
        -d "${TEST_DB}" \
    < "${BACKUP_FILE}" \
    || die "Database restoration failed."

log "Database restoration completed."

# Validate restored tables.
log "Checking restored database tables."

TABLE_COUNT="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d "${TEST_DB}" \
        -c "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';"
)"

[[ "${TABLE_COUNT}" =~ ^[0-9]+$ ]] || die "Could not determine restored table count."
(( TABLE_COUNT > 0 )) || die "No public tables were restored."

# Verify Django migration history.
MIGRATION_TABLE="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d "${TEST_DB}" \
        -c "SELECT to_regclass('public.django_migrations') IS NOT NULL;"
)"

[[ "${MIGRATION_TABLE}" == "t" ]] || die "Django migration table is missing."

MIGRATION_COUNT="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d "${TEST_DB}" \
        -c "SELECT COUNT(*) FROM public.django_migrations;"
)"

[[ "${MIGRATION_COUNT}" =~ ^[0-9]+$ ]] || die "Could not verify migration history."
(( MIGRATION_COUNT > 0 )) || die "No Django migration records were restored."

log "Restore validation passed."
log "Restored public tables: ${TABLE_COUNT}"
log "Restored Django migrations: ${MIGRATION_COUNT}"

log "RESTORE TEST SUCCESSFUL."
log "Production database was not modified."

# EXIT trap removes the temporary database.
