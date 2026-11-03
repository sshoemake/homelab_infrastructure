#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ENV="${1:-dev}"
ENV_FILE="${SCRIPT_DIR}/.env.${ENV}"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.${ENV}.yml"

case "$ENV" in
    dev|uat|prod) ;;
    *) echo "Invalid environment: $ENV"; exit 1 ;;
esac

[[ -f "$ENV_FILE" ]] || {
    echo "Environment file not found: $ENV_FILE"
    exit 1
}

[[ -f "$COMPOSE_FILE" ]] || {
    echo "Compose file not found: $COMPOSE_FILE"
    exit 1
}

cd "$PROJECT_DIR"

echo "Starting Meal_Project ($ENV)..."

docker compose \
    --project-directory "$PROJECT_DIR" \
    --env-file "$ENV_FILE" \
    --profile "$ENV" \
    -f compose/docker-compose.yml \
    -f "$COMPOSE_FILE" \
    up -d

echo "Meal_Project ($ENV) started."