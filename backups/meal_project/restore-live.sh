#!/usr/bin/env bash
#
# Restore a Meal_Project PostgreSQL backup to production.
#
# Usage:
#   ./restore-live.sh /path/to/backup.dump
#
# The script:
#   - Requires explicit confirmation.
#   - Creates an emergency backup.
#   - Stops the web service.
#   - Preserves the existing production database.
#   - Restores into a fresh production database.
#   - Validates the restored database.
#   - Restarts and checks the web service.
#   - Attempts rollback if anything fails.
#
# The preserved database is never automatically deleted.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/../../meal_project" && pwd)"

readonly COMPOSE_BASE="${PROJECT_DIR}/compose/docker-compose.yml"
readonly COMPOSE_PROD="${PROJECT_DIR}/compose/docker-compose.prod.yml"
readonly ENV_FILE="${PROJECT_DIR}/compose/.env.prod"

readonly IMAGE_REPOSITORY="ghcr.io/sshoemake/meal_project"
readonly BACKUP_DIR="${MEAL_PROJECT_BACKUP_DIR:-${HOME}/backups/meal_project}"
readonly HEALTHCHECK_URL="${MEAL_PROJECT_HEALTHCHECK_URL:-https://sshoemake.com/}"

readonly TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
readonly COMPOSE_PROJECT_NAME="compose"

DB_NAME=""
DB_OWNER=""
TEST_DB=""
PRESERVED_DB=""

TEMP_BACKUP=""
EMERGENCY_BACKUP=""

WEB_STOPPED=false
DB_CONNECTIONS_DISABLED=false
OLD_DB_RENAMED=false
NEW_DB_CREATED=false

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
    log "ERROR: $*"
    exit 1
}

docker_compose() {
    docker compose \
        --project-directory "${PROJECT_DIR}" \
        --env-file "${ENV_FILE}" \
        -p "${COMPOSE_PROJECT_NAME}" \
        -f "${COMPOSE_BASE}" \
        -f "${COMPOSE_PROD}" \
        "$@"
}

cleanup() {
    local exit_code=$?
    local rollback_ok=true

    trap - EXIT INT TERM
    set +e

    if (( exit_code != 0 )); then
        log "Restore failed. Attempting rollback."

        if [[ "${OLD_DB_RENAMED}" == true ]]; then

            # Ensure the web service cannot connect during rollback.
            docker_compose stop web >/dev/null 2>&1
            WEB_STOPPED=true

            # Remove the partially restored production database.
            if [[ "${NEW_DB_CREATED}" == true ]]; then
                log "Removing partially restored production database."

                docker_compose exec -T db \
                    dropdb --if-exists --force \
                    -U "${DB_OWNER}" "${DB_NAME}"

                if (( $? != 0 )); then
                    log "ERROR: Could not remove the failed production database."
                    rollback_ok=false
                fi
            fi

            # Restore the original database name.
            if [[ "${rollback_ok}" == true ]]; then
                log "Restoring original database name."

                docker_compose exec -T db \
                    psql -X -v ON_ERROR_STOP=1 \
                    -U "${DB_OWNER}" -d postgres \
                    -c "ALTER DATABASE \"${PRESERVED_DB}\" RENAME TO \"${DB_NAME}\";"

                if (( $? != 0 )); then
                    log "ERROR: Could not rename the preserved database."
                    rollback_ok=false
                else
                    docker_compose exec -T db \
                        psql -X -v ON_ERROR_STOP=1 \
                        -U "${DB_OWNER}" -d postgres \
                        -c "ALTER DATABASE \"${DB_NAME}\" WITH ALLOW_CONNECTIONS true;"

                    if (( $? != 0 )); then
                        log "ERROR: Could not re-enable database connections."
                        rollback_ok=false
                    fi
                fi
            fi

        elif [[ "${DB_CONNECTIONS_DISABLED}" == true ]]; then

            # Database was disabled but not renamed.
            docker_compose exec -T db \
                psql -X -v ON_ERROR_STOP=1 \
                -U "${DB_OWNER}" -d postgres \
                -c "ALTER DATABASE \"${DB_NAME}\" WITH ALLOW_CONNECTIONS true;"

            if (( $? != 0 )); then
                log "ERROR: Could not re-enable database connections."
                rollback_ok=false
            fi
        fi

        # Restart the web service only if rollback is safe.
        if [[ "${WEB_STOPPED}" == true || "${OLD_DB_RENAMED}" == true ]]; then
            if [[ "${rollback_ok}" == true ]]; then
                log "Starting web service after rollback."

                docker_compose start web

                if (( $? != 0 )); then
                    log "ERROR: Could not restart web service."
                    rollback_ok=false
                fi
            else
                log "WARNING: Web service has been left stopped."
                log "Manual recovery is required."
            fi
        fi

        if [[ "${rollback_ok}" == true ]]; then
            log "Rollback completed."
        else
            log "WARNING: Rollback was incomplete. Manual intervention is required."
        fi
    fi

    if [[ -n "${TEMP_BACKUP}" && -f "${TEMP_BACKUP}" ]]; then
        rm -f -- "${TEMP_BACKUP}"
    fi

    exit "${exit_code}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Require an explicitly selected backup.
[[ $# -eq 1 ]] || die "Usage: $0 /path/to/backup.dump"

BACKUP_FILE="$1"

[[ -f "${BACKUP_FILE}" && -r "${BACKUP_FILE}" ]] \
    || die "Backup file not found or unreadable: ${BACKUP_FILE}"

BACKUP_FILE="$(cd -- "$(dirname -- "${BACKUP_FILE}")" && pwd)/$(basename -- "${BACKUP_FILE}")"

# Validate configuration.
for file in "${COMPOSE_BASE}" "${COMPOSE_PROD}" "${ENV_FILE}"; do
    [[ -f "${file}" ]] || die "Required file not found: ${file}"
done

for command in docker curl flock; do
    command -v "${command}" >/dev/null 2>&1 \
        || die "Required command not found: ${command}"
done

docker compose version >/dev/null 2>&1 \
    || die "Docker Compose v2 is required."

# Prevent overlap with the weekly backup script.
mkdir -p -- "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"

exec 9>"${BACKUP_DIR}/backup.lock"

flock -n 9 \
    || die "Another Meal_Project backup operation is running."

# Initial Compose interpolation. The actual running image is identified below.
export MEAL_PROJECT_IMAGE="${IMAGE_REPOSITORY}"
export MEAL_PROJECT_VERSION="restore-live"

# Confirm the existing production services are running.
DB_ID="$(docker_compose ps --status running -q db)"
WEB_ID="$(docker_compose ps --status running -q web)"

[[ -n "${DB_ID}" ]] || die "PostgreSQL service is not running."
[[ -n "${WEB_ID}" ]] || die "Web service is not running."

# Use the currently deployed image tag for subsequent Compose commands.
WEB_IMAGE="$(docker inspect --format '{{.Config.Image}}' "${WEB_ID}")"

[[ "${WEB_IMAGE}" == "${IMAGE_REPOSITORY}:"* ]] \
    || die "Unexpected web image: ${WEB_IMAGE}"

export MEAL_PROJECT_VERSION="${WEB_IMAGE#${IMAGE_REPOSITORY}:}"

docker_compose config --quiet \
    || die "Docker Compose configuration validation failed."

# Read database configuration from the running PostgreSQL container.
DB_NAME="$(docker_compose exec -T db sh -ec 'printf "%s" "$POSTGRES_DB"')"
DB_OWNER="$(docker_compose exec -T db sh -ec 'printf "%s" "$POSTGRES_USER"')"

[[ -n "${DB_NAME}" ]] || die "POSTGRES_DB is not configured."
[[ -n "${DB_OWNER}" ]] || die "POSTGRES_USER is not configured."

# Restrict database identifiers to safe characters for SQL commands.
[[ "${DB_NAME}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$ ]] \
    || die "Unexpected or unsupported PostgreSQL database name: ${DB_NAME}"

# Generate a unique name for the preserved production database.
readonly PRESERVED_SUFFIX="_pre_restore_${TIMESTAMP}"
readonly PRESERVED_PREFIX="${DB_NAME:0:$((63 - ${#PRESERVED_SUFFIX}))}"
PRESERVED_DB="${PRESERVED_PREFIX}${PRESERVED_SUFFIX}"

# Check the selected archive before making changes.
log "Validating selected backup archive."

docker_compose exec -T db pg_restore --list \
    < "${BACKUP_FILE}" > /dev/null \
    || die "Selected backup archive is invalid."

# Confirm the preserved database name is not already in use.
EXISTING_DB="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d postgres \
        -c "SELECT 1 FROM pg_database WHERE datname = '${PRESERVED_DB}';"
)"

[[ -z "${EXISTING_DB}" ]] \
    || die "Preserved database name already exists: ${PRESERVED_DB}"

# Check that the expected production database exists.
EXISTING_DB="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d postgres \
        -c "SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}';"
)"

[[ "${EXISTING_DB}" == "1" ]] \
    || die "Configured production database does not exist: ${DB_NAME}"

# Prepare emergency backup destination.
EMERGENCY_BACKUP="${BACKUP_DIR}/meal_project_pre_restore_${TIMESTAMP}.dump"

[[ ! -e "${EMERGENCY_BACKUP}" ]] \
    || die "Emergency backup destination already exists."

TEMP_BACKUP="$(mktemp "${BACKUP_DIR}/.meal_project_restore.XXXXXX")"
chmod 600 "${TEMP_BACKUP}"

# Explicit confirmation.
log "PRODUCTION DATABASE RESTORE"
log "Selected backup: ${BACKUP_FILE}"
log "Production database: ${DB_NAME}"
log "Database owner: ${DB_OWNER}"
log "Preserved database name: ${PRESERVED_DB}"
log "Emergency backup: ${EMERGENCY_BACKUP}"
log "Currently deployed web image: ${WEB_IMAGE}"

printf '\n'
printf 'This operation will replace the production database.\n'
printf 'The existing database will be preserved, not deleted.\n'
printf 'Type RESTORE to continue: '

read -r CONFIRMATION

[[ "${CONFIRMATION}" == "RESTORE" ]] \
    || die "Confirmation not received. No production changes made."

# Stop application writes.
log "Stopping Meal_Project web service."

WEB_STOPPED=true
docker_compose stop web \
    || die "Could not stop web service."

# Create an emergency backup of the current production database.
log "Creating emergency production backup."

docker_compose exec -T db sh -ec '
    pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc
' > "${TEMP_BACKUP}" \
    || die "Emergency database backup failed."

[[ -s "${TEMP_BACKUP}" ]] \
    || die "Emergency backup is empty."

docker_compose exec -T db pg_restore --list \
    < "${TEMP_BACKUP}" > /dev/null \
    || die "Emergency backup validation failed."

mv -- "${TEMP_BACKUP}" "${EMERGENCY_BACKUP}"
TEMP_BACKUP=""

log "Emergency backup created: ${EMERGENCY_BACKUP}"

# Prevent new connections to the original production database.
log "Disabling connections to the original production database."

DB_CONNECTIONS_DISABLED=true

docker_compose exec -T db \
    psql -X -v ON_ERROR_STOP=1 \
    -U "${DB_OWNER}" -d postgres \
    -c "ALTER DATABASE \"${DB_NAME}\" WITH ALLOW_CONNECTIONS false;" \
    || die "Could not disable production database connections."

# Disconnect remaining sessions.
log "Terminating remaining production database connections."

docker_compose exec -T db \
    psql -X -v ON_ERROR_STOP=1 \
    -U "${DB_OWNER}" -d postgres \
    -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DB_NAME}' AND pid <> pg_backend_pid();" \
    || die "Could not terminate existing database connections."

# Preserve the original database.
log "Preserving original production database: ${PRESERVED_DB}"

docker_compose exec -T db \
    psql -X -v ON_ERROR_STOP=1 \
    -U "${DB_OWNER}" -d postgres \
    -c "ALTER DATABASE \"${DB_NAME}\" RENAME TO \"${PRESERVED_DB}\";" \
    || die "Could not rename original production database."

OLD_DB_RENAMED=true
DB_CONNECTIONS_DISABLED=false

# Create the replacement production database.
log "Creating fresh production database."

docker_compose exec -T db \
    createdb -U "${DB_OWNER}" -T template0 -O "${DB_OWNER}" "${DB_NAME}" \
    || die "Could not create replacement production database."

NEW_DB_CREATED=true

# Restore the selected archive.
log "Restoring selected backup into production database."

docker_compose exec -T db \
    pg_restore \
        --exit-on-error \
        --no-owner \
        --no-privileges \
        -U "${DB_OWNER}" \
        -d "${DB_NAME}" \
    < "${BACKUP_FILE}" \
    || die "Production database restoration failed."

# Validate restored database.
log "Validating restored production database."

TABLE_COUNT="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d "${DB_NAME}" \
        -c "SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';"
)"

[[ "${TABLE_COUNT}" =~ ^[0-9]+$ ]] \
    || die "Could not determine restored table count."

(( TABLE_COUNT > 0 )) \
    || die "No public tables were restored."

MIGRATION_TABLE="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d "${DB_NAME}" \
        -c "SELECT to_regclass('public.django_migrations') IS NOT NULL;"
)"

[[ "${MIGRATION_TABLE}" == "t" ]] \
    || die "Django migration table is missing."

MIGRATION_COUNT="$(
    docker_compose exec -T db \
        psql -X -At -U "${DB_OWNER}" -d "${DB_NAME}" \
        -c "SELECT COUNT(*) FROM public.django_migrations;"
)"

[[ "${MIGRATION_COUNT}" =~ ^[0-9]+$ ]] \
    || die "Could not verify migration history."

(( MIGRATION_COUNT > 0 )) \
    || die "No Django migration records were restored."

log "Database validation passed."
log "Restored public tables: ${TABLE_COUNT}"
log "Restored Django migrations: ${MIGRATION_COUNT}"

# Restart the existing web container without recreating it.
log "Starting Meal_Project web service."

docker_compose start web \
    || die "Could not start web service."

WEB_STOPPED=false

# Wait for the web container and its Docker healthcheck.
log "Checking web container health."

NEW_WEB_ID=""

for attempt in $(seq 1 30); do
    NEW_WEB_ID="$(docker_compose ps -q web)"

    if [[ -n "${NEW_WEB_ID}" ]] &&
        [[ "$(docker inspect --format '{{.State.Running}}' "${NEW_WEB_ID}" 2>/dev/null || true)" == "true" ]]; then

        HEALTH_STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${NEW_WEB_ID}")"

        [[ "${HEALTH_STATUS}" != "unhealthy" ]] \
            || die "Web container reports unhealthy."

        [[ "${HEALTH_STATUS}" != "starting" ]] && break
    fi

    sleep 2
done

[[ -n "${NEW_WEB_ID}" ]] || die "Could not find the web container."

[[ "$(docker inspect --format '{{.State.Running}}' "${NEW_WEB_ID}")" == "true" ]] \
    || die "Web container is not running."

HEALTH_STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${NEW_WEB_ID}")"

[[ "${HEALTH_STATUS}" != "unhealthy" && "${HEALTH_STATUS}" != "starting" ]] \
    || die "Web container did not become healthy."

# Verify the public HTTPS endpoint, if configured.
if [[ -n "${HEALTHCHECK_URL}" ]]; then
    [[ "${HEALTHCHECK_URL}" == https://* ]] \
        || die "Healthcheck URL must use HTTPS."

    log "Checking public HTTPS endpoint."

    curl --fail --silent --show-error --location \
        --retry 12 --retry-delay 5 --retry-connrefused \
        --max-time 15 "${HEALTHCHECK_URL}" >/dev/null \
        || die "Public HTTPS health check failed."

    log "Public HTTPS health check passed."
fi

# Successful completion. The old database remains preserved.
log "LIVE RESTORE COMPLETED SUCCESSFULLY."
log "Production database: ${DB_NAME}"
log "Preserved original database: ${PRESERVED_DB}"
log "Emergency backup: ${EMERGENCY_BACKUP}"
log "Restored public tables: ${TABLE_COUNT}"
log "Restored Django migrations: ${MIGRATION_COUNT}"
log "Web container: ${NEW_WEB_ID}"
log "The preserved database has not been deleted."