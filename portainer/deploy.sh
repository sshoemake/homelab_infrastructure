#!/usr/bin/env bash
#
# Deploy a versioned Portainer CE release.
#
# Usage:
#   ./portainer/deploy.sh
#   ./portainer/deploy.sh status
#   ./portainer/deploy.sh versions
#   ./portainer/deploy.sh 2.46.0
#
# The live version is stored in portainer/compose/.env.
# The external portainer_data volume is never removed.

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_DIR="${SCRIPT_DIR}/compose"
readonly COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
readonly ENV_FILE="${COMPOSE_DIR}/.env"
readonly IMAGE_REPOSITORY="portainer/portainer-ce"
readonly IMAGE_TAGS_URL="https://hub.docker.com/v2/repositories/portainer/portainer-ce/tags?page_size=100&ordering=last_updated"
readonly LOCK_DIR="${PORTAINER_LOCK_DIR:-${HOME}/backups/portainer}"

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARNING: $*"; }

usage() {
    cat <<'USAGE'
Usage:
  ./portainer/deploy.sh             Interactive version selection
  ./portainer/deploy.sh status      Show configured and running versions
  ./portainer/deploy.sh versions    Show available stable versions
  ./portainer/deploy.sh <version>   Deploy a specific version
  ./portainer/deploy.sh --help      Show this help

Examples:
  ./portainer/deploy.sh
  ./portainer/deploy.sh 2.46.0

Only stable X.Y.Z release tags are offered.
The existing portainer_data volume is preserved.
USAGE
}

require_commands() {
    local command
    for command in docker curl jq sort flock grep sed tail tac seq mktemp; do
        command -v "${command}" >/dev/null 2>&1 \
            || die "Required command not found: ${command}"
    done

    docker compose version >/dev/null 2>&1 \
        || die "Docker Compose v2 is required."
}

read_configured_version() {
    [[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}"

    local version
    version="$(sed -n 's/^PORTAINER_VERSION=//p' "${ENV_FILE}" | tail -n 1)"
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "PORTAINER_VERSION is missing or invalid in ${ENV_FILE}"

    printf '%s\n' "${version}"
}

running_version() {
    if ! docker inspect portainer >/dev/null 2>&1; then
        printf '%s\n' "not running"
        return
    fi

    local image
    image="$(docker inspect --format '{{.Config.Image}}' portainer)"
    printf '%s\n' "${image##*:}"
}

compose() {
    docker compose \
        --project-directory "${COMPOSE_DIR}" \
        --env-file "${ENV_FILE}" \
        -f "${COMPOSE_FILE}" \
        "$@"
}

get_available_versions() {
    local response
    response="$(curl --fail --silent --show-error --location \
        --max-time 30 "${IMAGE_TAGS_URL}")" \
        || die "Could not retrieve Portainer tags from Docker Hub."

    jq -r '
        .results[].name
        | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))
    ' <<< "${response}" | sort -Vu
}

show_status() {
    local configured running
    configured="$(read_configured_version)"
    running="$(running_version)"

    echo "Portainer status"
    echo "----------------"
    printf 'Configured version: %s\n' "${configured}"
    printf 'Running version:    %s\n' "${running}"

    if [[ "${running}" != "not running" && "${running}" != "${configured}" ]]; then
        warn "Configured and running versions do not match."
    fi
}

show_versions() {
    local configured running
    configured="$(read_configured_version)"
    running="$(running_version)"

    echo "Portainer versions"
    echo "------------------"
    printf 'Configured: %s\n' "${configured}"
    printf 'Running:    %s\n\n' "${running}"

    local -a versions
    mapfile -t versions < <(get_available_versions)

    [[ ${#versions[@]} -gt 0 ]] || die "No stable versions were returned by Docker Hub."

    echo "Latest stable versions (up to 15):"
    printf '%s\n' "${versions[@]}" | tail -n 15 | tac

    if ! printf '%s\n' "${versions[@]}" | grep -Fxq "${configured}"; then
        printf '\nConfigured version %s is not in the returned tag list.\n' "${configured}"
    fi
}

deploy_version() {
    local selected_version="$1"

    [[ "${selected_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Invalid version: ${selected_version}. Expected X.Y.Z."

    mkdir -p -- "${LOCK_DIR}"
    chmod 700 "${LOCK_DIR}"

    exec 9>"${LOCK_DIR}/portainer-deploy.lock"
    flock -n 9 || die "Another Portainer deployment is already running."

    local old_version
    old_version="$(read_configured_version)"

    docker inspect portainer >/dev/null 2>&1 \
        || die "The existing Portainer container was not found."

    [[ "$(docker inspect --format '{{.State.Running}}' portainer)" == "true" ]] \
        || die "The existing Portainer container is not running."

    if [[ "${selected_version}" == "${old_version}" ]]; then
        log "Version ${selected_version} is already configured. Nothing to do."
        return
    fi

    echo
    echo "Portainer upgrade"
    echo "-----------------"
    printf 'Currently configured: %s\n' "${old_version}"
    printf 'Currently running:    %s\n' "$(running_version)"
    printf 'Selected version:     %s\n' "${selected_version}"
    echo
    read -r -p "Deploy Portainer ${selected_version}? [y/N] " answer

    [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]] || {
        log "Deployment cancelled."
        return
    }

    log "Validating Compose configuration."
    compose config --quiet || die "Compose configuration validation failed."

    log "Pulling ${IMAGE_REPOSITORY}:${selected_version}"
    docker pull "${IMAGE_REPOSITORY}:${selected_version}" \
        || die "Image pull failed. The running Portainer was not changed."

    local temp_env
    temp_env="$(mktemp "${COMPOSE_DIR}/.env.XXXXXX")"
    chmod 600 "${temp_env}"
    printf 'PORTAINER_VERSION=%s\n' "${selected_version}" > "${temp_env}"

    log "Updating local Portainer version configuration."
    mv -- "${temp_env}" "${ENV_FILE}"

    log "Recreating Portainer container."
    if ! compose up -d --no-deps --force-recreate portainer; then
        warn "Compose deployment failed."
        printf 'PORTAINER_VERSION=%s\n' "${old_version}" > "${ENV_FILE}"
        chmod 600 "${ENV_FILE}"
        die "Restored the previous version setting (${old_version}). Check Portainer before retrying."
    fi

    log "Checking the new Portainer container."
    local container_id=""
    local attempt

    for attempt in $(seq 1 30); do
        container_id="$(compose ps -q portainer)"
        if [[ -n "${container_id}" ]] \
            && [[ "$(docker inspect --format '{{.State.Running}}' "${container_id}" 2>/dev/null || true)" == "true" ]]; then
            break
        fi
        sleep 2
    done

    if [[ -z "${container_id}" ]] \
        || [[ "$(docker inspect --format '{{.State.Running}}' "${container_id}" 2>/dev/null || true)" != "true" ]]; then
        die "Portainer did not reach the running state. Inspect logs and container status."
    fi

    local actual_image
    actual_image="$(docker inspect --format '{{.Config.Image}}' "${container_id}")"

    [[ "${actual_image}" == "${IMAGE_REPOSITORY}:${selected_version}" ]] \
        || die "Unexpected running image: ${actual_image}"

    log "Portainer deployment completed successfully."
    log "Running image: ${actual_image}"
    log "Persistent volume portainer_data was preserved."
}

interactive_deploy() {
    local configured
    configured="$(read_configured_version)"

    local -a versions
    mapfile -t versions < <(get_available_versions | sort -Vr | head -n 15)

    [[ ${#versions[@]} -gt 0 ]] || die "No stable versions were returned by Docker Hub."

    echo
    echo "Portainer Deployment"
    echo "===================="
    printf 'Currently configured: %s\n\n' "${configured}"
    echo "Available stable releases:"

    local i
    for i in "${!versions[@]}"; do
        printf '  %2d) %s\n' "$((i + 1))" "${versions[$i]}"
    done

    echo
    read -r -p "Select a version number (or q to quit): " selection

    [[ "${selection}" =~ ^[Qq]$ ]] && {
        log "Deployment cancelled."
        return
    }

    [[ "${selection}" =~ ^[0-9]+$ ]] \
        || die "Please enter a number from the list or q."

    (( selection >= 1 && selection <= ${#versions[@]} )) \
        || die "Selection is outside the displayed list."

    deploy_version "${versions[$((selection - 1))]}"
}

main() {
    require_commands

    [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
    [[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}"

    case "${1:-}" in
        --help|-h)
            usage
            ;;
        status)
            show_status
            ;;
        versions)
            show_versions
            ;;
        "")
            [[ $# -eq 0 ]] || die "Unexpected arguments."
            interactive_deploy
            ;;
        *)
            [[ $# -eq 1 ]] || { usage; exit 2; }
            deploy_version "$1"
            ;;
    esac
}

main "$@"
