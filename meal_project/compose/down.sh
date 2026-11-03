#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
shift || true

case "$ENV" in
    dev|uat) ;;
    prod)
        echo "ERROR: down.sh cannot stop production."
        echo "Use an intentional maintenance procedure instead."
        exit 1
        ;;
    *)
        echo "Invalid environment: $ENV"
        exit 1
        ;;
esac

ARGS=("$@")

for arg in "${ARGS[@]}"; do
    case "$arg" in
        -v|--volumes)
            echo "ERROR: Volume deletion is not permitted through down.sh."
            exit 1
            ;;
    esac
done

ENV_FILE="${SCRIPT_DIR}/.env.${ENV}"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.${ENV}.yml"

[[ -f "$ENV_FILE" ]] || {
    echo "Environment file not found: $ENV_FILE"
    exit 1
}

[[ -f "$COMPOSE_FILE" ]] || {
    echo "Compose file not found: $COMPOSE_FILE"
    exit 1
}

cd "$PROJECT_DIR"

echo "Stopping Meal_Project ($ENV)..."

docker compose \
    --project-directory "$PROJECT_DIR" \
    --env-file "$ENV_FILE" \
    --profile "$ENV" \
    -f compose/docker-compose.yml \
    -f "$COMPOSE_FILE" \
    down "${ARGS[@]}"

echo "Meal_Project ($ENV) stopped."