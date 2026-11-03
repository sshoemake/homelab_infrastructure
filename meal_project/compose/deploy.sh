#!/usr/bin/env bash
#
# Deploy a versioned Meal_Project release to the Odroid host.
#
# Run from the infrastructure repository root:
#   ./meal_project/compose/deploy.sh v2.2.6
#
# Optional public HTTPS check:
#   MEAL_PROJECT_HEALTHCHECK_URL="https://your-domain.example/" \
#     ./meal_project/compose/deploy.sh v2.2.6
#
# Optional backup location:
#   MEAL_PROJECT_BACKUP_DIR="$HOME/backups/meal_project" \
#     ./meal_project/compose/deploy.sh v2.2.6
#
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly COMPOSE_BASE="${PROJECT_DIR}/compose/docker-compose.yml"
readonly COMPOSE_PROD="${PROJECT_DIR}/compose/docker-compose.prod.yml"
readonly ENV_FILE="${PROJECT_DIR}/compose/.env.prod"
readonly IMAGE_REPOSITORY="ghcr.io/sshoemake/meal_project"
readonly BACKUP_DIR="${MEAL_PROJECT_BACKUP_DIR:-${HOME}/backups/meal_project}"
readonly HEALTHCHECK_URL="${MEAL_PROJECT_HEALTHCHECK_URL:-https://sshoemake.com/}"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARNING: $*"; }

usage() {
    cat <<'EOF'
Usage:
  ./meal_project/compose/deploy.sh <release-tag>

Example:
  ./meal_project/compose/deploy.sh v2.2.6

Optional environment variables:
  MEAL_PROJECT_BACKUP_DIR       Backup directory (default: ~/backups/meal_project)
  MEAL_PROJECT_HEALTHCHECK_URL  Public HTTPS URL to check after deployment
EOF
}

[[ $# -eq 1 ]] || { usage; exit 2; }
readonly RELEASE_TAG="$1"

[[ "${RELEASE_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
    || die "Invalid release tag: ${RELEASE_TAG}"

for command in docker curl; do
    command -v "${command}" >/dev/null 2>&1 || die "Required command not found: ${command}"
done

docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."

[[ -f "${COMPOSE_BASE}" ]] || die "Compose file not found: ${COMPOSE_BASE}"
[[ -f "${COMPOSE_PROD}" ]] || die "Production Compose file not found: ${COMPOSE_PROD}"
[[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}"

# These names must match the image interpolation used in your Compose file.
export MEAL_PROJECT_IMAGE="${IMAGE_REPOSITORY}"
export MEAL_PROJECT_VERSION="${RELEASE_TAG}"

readonly COMPOSE_PROJECT_NAME="compose"

COMPOSE=(
    docker compose
    --project-directory "${PROJECT_DIR}"
    --env-file "${ENV_FILE}"
    -p "${COMPOSE_PROJECT_NAME}"
    -f "${COMPOSE_BASE}"
    -f "${COMPOSE_PROD}"
)

TEMP_BACKUP=""
cleanup() {
    if [[ -n "${TEMP_BACKUP}" && -f "${TEMP_BACKUP}" ]]; then
        rm -f -- "${TEMP_BACKUP}"
    fi
}
trap cleanup EXIT

log "Preparing Meal_Project deployment: ${RELEASE_TAG}"
log "Project directory: ${PROJECT_DIR}"

"${COMPOSE[@]}" config --quiet \
    || die "Docker Compose configuration validation failed."

EXPECTED_IMAGE="${IMAGE_REPOSITORY}:${RELEASE_TAG}"
RESOLVED_IMAGES="$("${COMPOSE[@]}" config --images)"
printf '%s\n' "${RESOLVED_IMAGES}" | grep -Fxq "${EXPECTED_IMAGE}" \
    || die "Compose does not resolve an image to ${EXPECTED_IMAGE}. Check the web image declaration and its variable names."

# Traefik is a separately managed stack. Verify its shared network only;
# this script does not restart or modify Traefik.
docker network inspect traefik_public >/dev/null 2>&1 \
    || die "Docker network traefik_public does not exist."

TRAEFIK_ON_NETWORK="$(
    docker network inspect traefik_public \
        --format '{{range .Containers}}{{println .Name}}{{end}}' |
        grep -i 'traefik' || true
)"
[[ -n "${TRAEFIK_ON_NETWORK}" ]] \
    || die "No Traefik container appears attached to traefik_public."

# Require an existing, running production stack. First deployment is
# intentionally not handled by this script.
DB_ID="$("${COMPOSE[@]}" ps --status running -q db)"
WEB_ID="$("${COMPOSE[@]}" ps --status running -q web)"
[[ -n "${DB_ID}" ]] || die "PostgreSQL service (db) is not running."
[[ -n "${WEB_ID}" ]] || die "Existing web service is not running; refusing an unattended first deployment."

log "Pre-deployment checks passed."
log "Pulling ${EXPECTED_IMAGE}"
"${COMPOSE[@]}" pull web || die "Image pull failed; the running deployment was not changed."

# Back up PostgreSQL before running any migrations.
mkdir -p -- "${BACKUP_DIR}"
chmod 700 "${BACKUP_DIR}"
BACKUP_FILE="${BACKUP_DIR}/meal_project_${RELEASE_TAG}_$(date '+%Y%m%d_%H%M%S').dump"
TEMP_BACKUP="$(mktemp "${BACKUP_DIR}/.meal_project_backup.XXXXXX")"
chmod 600 "${TEMP_BACKUP}"

log "Creating PostgreSQL backup"
"${COMPOSE[@]}" exec -T db sh -ec '
    pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null
    pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc
' > "${TEMP_BACKUP}" || die "Database backup failed; deployment stopped."

[[ -s "${TEMP_BACKUP}" ]] || die "Database backup is empty; deployment stopped."

# Confirm that PostgreSQL can read the custom-format archive.
"${COMPOSE[@]}" exec -T db pg_restore --list < "${TEMP_BACKUP}" >/dev/null \
    || die "Database backup validation failed; deployment stopped."

mv -- "${TEMP_BACKUP}" "${BACKUP_FILE}"
TEMP_BACKUP=""
log "Backup created and validated: ${BACKUP_FILE}"

# Run migrations with the new image, without replacing the running web service.
log "Running Django migrations with ${RELEASE_TAG}"
"${COMPOSE[@]}" run --rm --no-deps web python manage.py migrate --noinput \
    || die "Django migrations failed. The current web container has not been replaced. Review the migration failure and backup before proceeding."

# Recreate only the web service. Do not run compose down or restart the DB.
log "Recreating web service"
"${COMPOSE[@]}" up -d --no-deps --force-recreate web \
    || die "Web service recreation failed. Database backup: ${BACKUP_FILE}"

# Wait for the container to be running and for its Docker healthcheck,
# if one is defined, to pass.
log "Checking new web container"
NEW_WEB_ID=""
for attempt in $(seq 1 30); do
    NEW_WEB_ID="$("${COMPOSE[@]}" ps -q web)"
    if [[ -n "${NEW_WEB_ID}" ]] &&
       [[ "$(docker inspect --format '{{.State.Running}}' "${NEW_WEB_ID}" 2>/dev/null || true)" == "true" ]]; then
        HEALTH_STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${NEW_WEB_ID}")"
        [[ "${HEALTH_STATUS}" != "unhealthy" ]] \
            || die "Web container reports unhealthy. Database backup: ${BACKUP_FILE}"
        [[ "${HEALTH_STATUS}" != "starting" ]] && break
    fi
    sleep 2
done

[[ -n "${NEW_WEB_ID}" ]] || die "Could not find the recreated web container."
[[ "$(docker inspect --format '{{.State.Running}}' "${NEW_WEB_ID}")" == "true" ]] \
    || die "New web container is not running. Database backup: ${BACKUP_FILE}"

HEALTH_STATUS="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' "${NEW_WEB_ID}")"
[[ "${HEALTH_STATUS}" != "unhealthy" && "${HEALTH_STATUS}" != "starting" ]] \
    || die "Web container did not become healthy (status: ${HEALTH_STATUS}). Database backup: ${BACKUP_FILE}"

if [[ -n "${HEALTHCHECK_URL}" ]]; then
    [[ "${HEALTHCHECK_URL}" == https://* ]] \
        || die "MEAL_PROJECT_HEALTHCHECK_URL must use HTTPS."
    log "Checking public HTTPS endpoint"

    curl --fail --silent --show-error --location \
        --retry 12 --retry-delay 5 --retry-connrefused \
        --max-time 15 "${HEALTHCHECK_URL}" >/dev/null \
        || die "HTTPS health check failed. Database backup: ${BACKUP_FILE}"

    log "Public HTTPS health check passed."
else
    warn "MEAL_PROJECT_HEALTHCHECK_URL is not set; public HTTPS verification was skipped."
fi

log "Deployment completed successfully."
log "Release:  ${RELEASE_TAG}"
log "Image:    ${EXPECTED_IMAGE}"
log "Web ID:   ${NEW_WEB_ID}"
log "Backup:   ${BACKUP_FILE}"
log "PostgreSQL and the independently managed Traefik service were left running."
