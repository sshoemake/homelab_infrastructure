#!/usr/bin/env bash

#
# Run consolidated infrastructure monitoring and email the report.
#
# Usage:
#   ./updates/daily_report.sh
#

set -Eeuo pipefail

IFS=$'\n\t'

# --------------------------------------------------
# Configuration
# --------------------------------------------------

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly MONITOR_SCRIPT="${SCRIPT_DIR}/monitor.sh"
readonly NOTIFY_SCRIPT="${SCRIPT_DIR}/../notifications/notify.sh"

readonly LOG_DIR="${HOME}/.local/state/homelab"
readonly LOG_FILE="${LOG_DIR}/daily_report.log"

# --------------------------------------------------
# Functions
# --------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        | tee -a "${LOG_FILE}"
}

# --------------------------------------------------
# Initial validation
# --------------------------------------------------

umask 077
mkdir -p -- "${LOG_DIR}"

for file in "${MONITOR_SCRIPT}" "${NOTIFY_SCRIPT}"; do
    [[ -x "${file}" ]] || {
        log "ERROR: Required executable not found or not executable: ${file}"
        exit 1
    }
done

# --------------------------------------------------
# Run monitoring
# --------------------------------------------------

TEMP_REPORT="$(mktemp)"
trap 'rm -f -- "${TEMP_REPORT}"' EXIT

log "Starting daily infrastructure monitoring."

if "${MONITOR_SCRIPT}" > "${TEMP_REPORT}" 2>&1; then
    MONITOR_RC=0
else
    MONITOR_RC=$?
fi

REPORT="$(cat "${TEMP_REPORT}")"

if [[ "${MONITOR_RC}" -eq 0 ]]; then
    EMAIL_STATUS="success"
    log "Monitoring completed successfully."
else
    EMAIL_STATUS="failure"
    log "WARNING: Monitoring returned exit code ${MONITOR_RC}."
fi

# --------------------------------------------------
# Send report
# --------------------------------------------------

SUBJECT="Daily Infrastructure Monitor Report"

MESSAGE="Daily infrastructure monitoring report.

Monitor exit code: ${MONITOR_RC}

${REPORT}"

if "${NOTIFY_SCRIPT}" \
    "${EMAIL_STATUS}" \
    "${SUBJECT}" \
    "${MESSAGE}"; then

    log "Daily monitoring email sent successfully."

else
    NOTIFY_RC=$?
    log "ERROR: Email delivery failed (exit code ${NOTIFY_RC})."
    exit 1
fi

# Preserve monitoring status for scheduled execution.

if [[ "${MONITOR_RC}" -ne 0 ]]; then
    log "Daily report completed with monitoring problems."
    exit "${MONITOR_RC}"
fi

log "Daily report completed successfully."
exit 0
