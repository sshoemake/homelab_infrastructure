#!/usr/bin/env bash
#
# Deploy a versioned Portainer CE release.
#
# Usage:
#   ./portainer/deploy.sh
#   ./portainer/deploy.sh upgrade
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

  ./portainer/deploy.sh upgrade     Check latest stable release and prompt
  ./portainer/deploy.sh             Interactive version selection
  ./portainer/deploy.sh status      Show configured and running versions
  ./portainer/deploy.sh versions    Show available stable versions
  ./portainer/deploy.sh <version>   Deploy a specific version
  ./portainer/deploy.sh --help      Show this help

Examples:

  ./portainer/deploy.sh upgrade
  ./portainer/deploy.sh 2.46.0

Only stable X.Y.Z release tags are offered.
A failed deployment automatically attempts to restore the previous version.
The existing portainer_data volume is preserved.
USAGE
}

require_commands() {
    local command
    for command in docker curl jq sort flock grep sed tail tac seq mktemp awk cp; do
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

latest_stable_version() {
    local -a versions
    mapfile -t versions < <(get_available_versions)
    [[ ${#versions[@]} -gt 0 ]] || die "No stable versions were returned by Docker Hub."
    printf '%s\n' "${versions[-1]}"
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

wait_for_version() {
    local expected_version="$1"
    local container_id=""
    local actual_image=""
    local api_version=""
    local attempt

    for attempt in $(seq 1 30); do
        container_id="$(compose ps -q portainer 2>/dev/null || true)"
        if [[ -n "${container_id}" ]] \
            && [[ "$(docker inspect --format '{{.State.Running}}' "${container_id}" 2>/dev/null || true)" == "true" ]]; then
            actual_image="$(docker inspect --format '{{.Config.Image}}' "${container_id}" 2>/dev/null || true)"
            if [[ "${actual_image}" == "${IMAGE_REPOSITORY}:${expected_version}" ]]; then
                # The container can be running before the Portainer application is ready.
                # Verify the unauthenticated status endpoint and its reported version.
                api_version="$(curl --insecure --fail --silent --show-error \
                    --max-time 5 https://127.0.0.1:9443/api/status 2>/dev/null \
                    | jq -er '.Version // empty' 2>/dev/null || true)"
                if [[ "${api_version}" == "${expected_version}" ]]; then
                    printf '%s\n' "${actual_image} (API version ${api_version})"
                    return 0
                fi
            fi
        fi
        sleep 2
    done

    return 1
}

restore_previous_version() {
    local previous_version="$1"
    local env_backup="$2"
    local restore_temp

    warn "Attempting automatic rollback to Portainer ${previous_version}."

    restore_temp="$(mktemp "${COMPOSE_DIR}/.env.rollback.XXXXXX")" || {
        warn "Could not create a temporary environment file for rollback."
        return 1
    }

    if ! cp -p -- "${env_backup}" "${restore_temp}"; then
        rm -f -- "${restore_temp}"
        warn "Could not copy the previous environment file for rollback."
        return 1
    fi

    if ! mv -f -- "${restore_temp}" "${ENV_FILE}"; then
        rm -f -- "${restore_temp}"
        warn "Could not restore the previous environment file."
        return 1
    fi

    if ! docker image inspect "${IMAGE_REPOSITORY}:${previous_version}" >/dev/null 2>&1; then
        if ! docker pull "${IMAGE_REPOSITORY}:${previous_version}"; then
            warn "Could not retrieve the previous Portainer image for rollback."
            return 1
        fi
    fi

    compose up -d --no-deps --force-recreate portainer \
        || warn "Compose reported an error during rollback; checking container state anyway."

    local restored_image
    if restored_image="$(wait_for_version "${previous_version}")"; then
        log "Rollback verified successfully: ${restored_image}"
        return 0
    fi

    warn "Rollback could not be verified. Portainer may require manual recovery."
    return 1
}

deploy_version() {
    local selected_version="$1"

    [[ "${selected_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "Invalid version: ${selected_version}. Expected X.Y.Z."

    mkdir -p -- "${LOCK_DIR}"
    chmod 700 "${LOCK_DIR}"

    exec 9>"${LOCK_DIR}/portainer-deploy.lock"
    flock -n 9 || die "Another Portainer deployment is already running."

    local old_version old_running_version
    old_version="$(read_configured_version)"

    docker inspect portainer >/dev/null 2>&1 \
        || die "The existing Portainer container was not found."

    [[ "$(docker inspect --format '{{.State.Running}}' portainer)" == "true" ]] \
        || die "The existing Portainer container is not running."

    old_running_version="$(running_version)"
    [[ "${old_running_version}" == "${old_version}" ]] \
        || die "Configured version (${old_version}) and running version (${old_running_version}) differ. Investigate before deploying."

    if [[ "${selected_version}" == "${old_version}" ]]; then
        log "Version ${selected_version} is already configured. Nothing to do."
        return
    fi

    echo
    echo "Portainer deployment"
    echo "--------------------"
    printf 'Currently configured and running: %s\n' "${old_version}"
    printf 'Selected version:                  %s\n' "${selected_version}"
    echo
    read -r -p "Deploy Portainer ${selected_version}? [y/N] " answer

    [[ "${answer}" =~ ^[Yy]([Ee][Ss])?$ ]] || {
        log "Deployment cancelled."
        return
    }

    log "Validating Compose configuration."
    compose config --quiet || die "Compose configuration validation failed."

    log "Ensuring the current image is available for rollback."
    if ! docker image inspect "${IMAGE_REPOSITORY}:${old_version}" >/dev/null 2>&1; then
        docker pull "${IMAGE_REPOSITORY}:${old_version}" \
            || die "Could not ensure the previous image is available. No changes were made."
    fi

    log "Pulling ${IMAGE_REPOSITORY}:${selected_version}"
    docker pull "${IMAGE_REPOSITORY}:${selected_version}" \
        || die "Image pull failed. The running Portainer was not changed."

    local env_backup temp_env
    env_backup="$(mktemp "${COMPOSE_DIR}/.env.backup.XXXXXX")"
    cp -p -- "${ENV_FILE}" "${env_backup}"

    temp_env="$(mktemp "${COMPOSE_DIR}/.env.XXXXXX")"
    chmod 600 "${temp_env}"
    if ! awk -v version="${selected_version}" '
        BEGIN { updated = 0 }
        /^PORTAINER_VERSION=/ {
            if (!updated) print "PORTAINER_VERSION=" version
            updated = 1
            next
        }
        { print }
        END {
            if (!updated) print "PORTAINER_VERSION=" version
        }
    ' "${ENV_FILE}" > "${temp_env}"; then
        rm -f -- "${temp_env}" "${env_backup}"
        die "Could not prepare the updated environment file."
    fi

    log "Updating local Portainer version configuration."
    if ! mv -f -- "${temp_env}" "${ENV_FILE}"; then
        rm -f -- "${temp_env}" "${env_backup}"
        die "Could not install the updated environment file. No deployment was attempted."
    fi

    log "Recreating Portainer container."
    if ! compose up -d --no-deps --force-recreate portainer; then
        warn "Compose deployment command failed."
        if restore_previous_version "${old_version}" "${env_backup}"; then
            rm -f -- "${env_backup}"
            die "Upgrade failed; previous version ${old_version} was restored."
        else
            rm -f -- "${env_backup}"
            die "Upgrade failed and automatic rollback could not be verified. Manual recovery is required."
        fi
    fi

    log "Verifying the new Portainer container."
    local actual_image
    if ! actual_image="$(wait_for_version "${selected_version}")"; then
        warn "New Portainer version did not pass container startup/image verification."
        if restore_previous_version "${old_version}" "${env_backup}"; then
            rm -f -- "${env_backup}"
            die "Upgrade verification failed; previous version ${old_version} was restored."
        else
            rm -f -- "${env_backup}"
            die "Upgrade verification and automatic rollback both failed. Manual recovery is required."
        fi
    fi

    rm -f -- "${env_backup}"
    log "Portainer deployment completed successfully."
    log "Running image: ${actual_image}"
    log "Persistent volume portainer_data was preserved."
}

upgrade_latest() {
    local configured running latest
    configured="$(read_configured_version)"
    running="$(running_version)"

    [[ "${running}" == "${configured}" ]] \
        || die "Configured version (${configured}) and running version (${running}) differ. Investigate before upgrading."

    log "Checking Docker Hub for the latest stable Portainer CE release."
    latest="$(latest_stable_version)"

    echo
    echo "Portainer update check"
    echo "----------------------"
    printf 'Currently installed: %s\n' "${configured}"
    printf 'Latest stable:       %s\n' "${latest}"

    if [[ "${latest}" == "${configured}" ]]; then
        log "Portainer is already on the latest stable version."
        return
    fi

    local newest
    newest="$(printf '%s\n' "${configured}" "${latest}" | sort -V | tail -n 1)"
    if [[ "${newest}" != "${latest}" ]]; then
        log "The latest tag returned is not newer than the installed version. No upgrade is needed."
        return
    fi

    deploy_version "${latest}"
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
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        return 0
    fi

    require_commands

    [[ -f "${COMPOSE_FILE}" ]] || die "Compose file not found: ${COMPOSE_FILE}"
    [[ -f "${ENV_FILE}" ]] || die "Environment file not found: ${ENV_FILE}"

    case "${1:-}" in
        --help|-h)
            usage
            ;;
        upgrade)
            [[ $# -eq 1 ]] || { usage; exit 2; }
            upgrade_latest
            ;;
        status)
            [[ $# -eq 1 ]] || { usage; exit 2; }
            show_status
            ;;
        versions)
            [[ $# -eq 1 ]] || { usage; exit 2; }
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
