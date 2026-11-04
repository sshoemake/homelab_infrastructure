#!/usr/bin/env bash
#
# Send infrastructure email notifications.
#
# Usage:
#   notify.sh success "Subject" "Message"
#   notify.sh failure "Subject" "Message"
#

set -Eeuo pipefail

# --------------------------------------------------
# Configuration
# --------------------------------------------------

NOTIFY_TO="${NOTIFY_TO:-sshoemake@centurylink.net}"
MSMTP_ACCOUNT="${MSMTP_ACCOUNT:-gmail}"
MSMTP_BIN="${MSMTP_BIN:-/usr/bin/msmtp}"

LOG_DIR="${HOME}/.local/state/homelab"
LOG_FILE="${LOG_DIR}/notifications.log"

# --------------------------------------------------
# Functions
# --------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" \
        >> "$LOG_FILE"
}

usage() {
    echo "Usage: $0 <success|failure> <subject> <message>" >&2
    exit 2
}

# --------------------------------------------------
# Validate arguments
# --------------------------------------------------

[[ $# -eq 3 ]] || usage

STATUS="$1"
SUBJECT="$2"
MESSAGE="$3"

case "$STATUS" in
    success|failure)
        ;;
    *)
        usage
        ;;
esac

[[ -n "$SUBJECT" && -n "$MESSAGE" && -n "$NOTIFY_TO" ]] || usage

# Prevent email header injection.
case "$SUBJECT$NOTIFY_TO" in
    *$'\n'*|*$'\r'*)
        echo "Invalid newline in email header." >&2
        exit 2
        ;;
esac

# --------------------------------------------------
# Prepare logging
# --------------------------------------------------

umask 077
mkdir -p "$LOG_DIR"

if [[ ! -x "$MSMTP_BIN" ]]; then
    log "ERROR: msmtp executable not found: $MSMTP_BIN"
    exit 1
fi

# --------------------------------------------------
# Build and send email
# --------------------------------------------------

HOST="$(hostname)"
TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"

EMAIL_SUBJECT="[$STATUS] $SUBJECT"

if {
    printf 'To: %s\n' "$NOTIFY_TO"
    printf 'Subject: %s\n' "$EMAIL_SUBJECT"
    printf 'Date: %s\n' "$(date -R)"
    printf '\n'
    printf 'Infrastructure Notification\n'
    printf 'Host: %s\n' "$HOST"
    printf 'Time: %s\n' "$TIMESTAMP"
    printf 'Status: %s\n\n' "$STATUS"
    printf '%s\n' "$MESSAGE"
} | "$MSMTP_BIN" -a "$MSMTP_ACCOUNT" -t 2>>"$LOG_FILE"; then

    log "SUCCESS: Email delivered to $NOTIFY_TO: $EMAIL_SUBJECT"

else
    RC=$?
    log "ERROR: Email delivery failed (exit code $RC): $EMAIL_SUBJECT"
    exit "$RC"
fi