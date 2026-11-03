#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
[[ $# -eq 0 ]] || shift

COMMAND="${1:-migrate}"
[[ $# -eq 0 ]] || shift

ARGS=("$@")

ENV_FILE="${SCRIPT_DIR}/.env.${ENV}"

case "$ENV" in
    dev|uat|prod) ;;
    *)
        echo "Invalid environment: $ENV"
        exit 1
        ;;
esac

[[ -f "$ENV_FILE" ]] || {
    echo "Environment file not found: $ENV_FILE"
    exit 1
}

cd "$PROJECT_DIR"

if [[ "$ENV" == "dev" ]]; then

    echo "[DEV] Running Django locally: $COMMAND"

    # Environment file must use shell-compatible KEY=value syntax.
    set -a
    source "$ENV_FILE"
    set +a

    python manage.py "$COMMAND" "${ARGS[@]}"

else

    COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.${ENV}.yml"

    [[ -f "$COMPOSE_FILE" ]] || {
        echo "Compose file not found: $COMPOSE_FILE"
        exit 1
    }

    echo "[$ENV] Running Django in Docker: $COMMAND"

    docker compose \
        --project-directory "$PROJECT_DIR" \
        --env-file "$ENV_FILE" \
        --profile "$ENV" \
        -f compose/docker-compose.yml \
        -f "$COMPOSE_FILE" \
        run --rm web python manage.py "$COMMAND" "${ARGS[@]}"

fi