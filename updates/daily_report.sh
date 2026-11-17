#!/usr/bin/env bash
#
# Run consolidated infrastructure monitoring and email the report.
#

set -Eeuo pipefail
IFS=$'\n\t'

# --------------------------------------------------
# Configuration
# --------------------------------------------------

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly MONITOR_SCRIPT="${SCRIPT_DIR}/monitor.sh"
readonly RENDERER="${SCRIPT_DIR}/email_report.py"
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

for file in "${MONITOR_SCRIPT}" "${RENDERER}" "${NOTIFY_SCRIPT}"; do
    [[ -f "${file}" ]] || {
        log "ERROR: Required file not found: ${file}"
        exit 1
    }
done

[[ -x "${MONITOR_SCRIPT}" && -x "${NOTIFY_SCRIPT}" ]] || {
    log "ERROR: Monitor or notification script is not executable."
    exit 1
}

command -v python3 >/dev/null 2>&1 || {
    log "ERROR: python3 is not installed."
    exit 1
}

# --------------------------------------------------
# Temporary report files
# --------------------------------------------------

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TEMP_DIR}"' EXIT

readonly JSON_REPORT="${TEMP_DIR}/monitor.json"
readonly HTML_REPORT="${TEMP_DIR}/report.html"
readonly TEXT_REPORT="${TEMP_DIR}/report.txt"

# --------------------------------------------------
# Run monitoring
# --------------------------------------------------

log "Starting daily infrastructure monitoring."

if "${MONITOR_SCRIPT}" --json > "${JSON_REPORT}" 2> "${TEMP_DIR}/monitor.stderr"; then
    MONITOR_RC=0
else
    MONITOR_RC=$?
fi

if [[ -s "${TEMP_DIR}/monitor.stderr" ]]; then
    while IFS= read -r line; do
        log "Monitor: ${line}"
    done < "${TEMP_DIR}/monitor.stderr"
fi

if [[ "${MONITOR_RC}" -eq 0 ]]; then
    EMAIL_STATUS="success"
    log "Monitoring completed successfully."
else
    EMAIL_STATUS="failure"
    log "WARNING: Monitoring returned exit code ${MONITOR_RC}."
fi

# --------------------------------------------------
# Render email
# --------------------------------------------------

if ! python3 "${RENDERER}" \
    --input "${JSON_REPORT}" \
    --html-out "${HTML_REPORT}" \
    --text-out "${TEXT_REPORT}"; then

    log "ERROR: Email report rendering failed."
    exit 1
fi

[[ -s "${HTML_REPORT}" && -s "${TEXT_REPORT}" ]] || {
    log "ERROR: Renderer did not produce both report files."
    exit 1
}

MESSAGE="$(cat "${TEXT_REPORT}")"
SUBJECT="Daily Infrastructure Monitor Report"

# --------------------------------------------------
# Send HTML + plain-text email
# --------------------------------------------------

if "${NOTIFY_SCRIPT}" \
    "${EMAIL_STATUS}" \
    "${SUBJECT}" \
    "${MESSAGE}" \
    "${HTML_REPORT}"; then

    log "Daily HTML monitoring email sent successfully."
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
