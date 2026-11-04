#!/usr/bin/env bash
#
# Run the weekly Meal_Project backup cycle.
#
# Workflow:
#   1. Create and validate the PostgreSQL backup.
#   2. Synchronize completed backups to the remote host.
#   3. Send one success or failure notification.
#
# Run from anywhere:
#   ./backups/run_weekly_backup.sh

set -Eeuo pipefail

IFS=$'\n\t'

# --------------------------------------------------
# Configuration
# --------------------------------------------------

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly BACKUP_SCRIPT="${SCRIPT_DIR}/meal_project/backup.sh"
readonly SYNC_SCRIPT="${SCRIPT_DIR}/remote/sync.sh"
readonly NOTIFY_SCRIPT="${SCRIPT_DIR}/../notifications/notify.sh"

readonly LOG_DIR="${HOME}/backups/meal_project"
readonly BACKUP_LOG="${LOG_DIR}/backup.log"
readonly SYNC_LOG="${LOG_DIR}/remote_sync.log"
readonly CYCLE_LOG="${LOG_DIR}/backup_cycle.log"

# --------------------------------------------------
# Functions
# --------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        | tee -a "${CYCLE_LOG}"
}

notify() {
    local status="$1"
    local subject="$2"
    local message="$3"

    if "${NOTIFY_SCRIPT}" "${status}" "${subject}" "${message}"; then
        log "Notification sent: ${subject}"
    else
        local rc=$?
        log "ERROR: Notification delivery failed (exit code ${rc})."
        return "${rc}"
    fi
}

# --------------------------------------------------
# Initial validation
# --------------------------------------------------

umask 077

mkdir -p -- "${LOG_DIR}"

for file in "${BACKUP_SCRIPT}" "${SYNC_SCRIPT}" "${NOTIFY_SCRIPT}"; do
    [[ -x "${file}" ]] || {
        log "ERROR: Required executable not found or not executable: ${file}"
        exit 1
    }
done

log "=================================================="
log "Starting weekly Meal_Project backup cycle."

# --------------------------------------------------
# Step 1: Database backup
# --------------------------------------------------

log "Starting PostgreSQL backup."

if "${BACKUP_SCRIPT}" >> "${BACKUP_LOG}" 2>&1; then
    log "PostgreSQL backup completed successfully."
else
    rc=$?

    log "ERROR: PostgreSQL backup failed (exit code ${rc})."

    notify failure \
        "Meal_Project Backup Failed" \
        "The PostgreSQL backup failed on $(hostname).

Exit code: ${rc}

Review the backup log:
${BACKUP_LOG}

Review the cycle log:
${CYCLE_LOG}" || true

    exit "${rc}"
fi

# --------------------------------------------------
# Step 2: Remote synchronization
# --------------------------------------------------

log "Starting remote backup synchronization."

if "${SYNC_SCRIPT}" >> "${SYNC_LOG}" 2>&1; then
    log "Remote synchronization completed successfully."
else
    rc=$?

    log "ERROR: Remote synchronization failed (exit code ${rc})."

    notify failure \
        "Meal_Project Remote Sync Failed" \
        "The PostgreSQL backup succeeded, but remote synchronization failed on $(hostname).

Exit code: ${rc}

Review the synchronization log:
${SYNC_LOG}

Review the cycle log:
${CYCLE_LOG}" || true

    exit "${rc}"
fi

# --------------------------------------------------
# Step 3: Success notification
# --------------------------------------------------

log "Weekly Meal_Project backup cycle completed successfully."

notify success \
    "Meal_Project Backup Completed" \
    "The weekly Meal_Project backup cycle completed successfully on $(hostname).

PostgreSQL backup: SUCCESS
Remote synchronization: SUCCESS

Backup log:
${BACKUP_LOG}

Synchronization log:
${SYNC_LOG}

Cycle log:
${CYCLE_LOG}" || exit 1

log "Weekly backup cycle finished."
exit 0