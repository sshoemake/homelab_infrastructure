#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
source "$SCRIPT_DIR/.env"
set +a

exec "$SCRIPT_DIR/.venv/bin/python" \
    "$SCRIPT_DIR/cloudflare_ddns.py"