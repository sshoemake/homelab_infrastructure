#!/usr/bin/env bash
#
# Send infrastructure email notifications.
#
# Usage:
#   notify.sh success "Subject" "Message"
#   notify.sh failure "Subject" "Message"
#   notify.sh success "Subject" "Plain text" "/path/to/report.html"
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
    echo "Usage: $0 <success|failure> <subject> <message> [html_file]" >&2
    exit 2
}

# --------------------------------------------------
# Validate arguments
# --------------------------------------------------

[[ $# -eq 3 || $# -eq 4 ]] || usage

STATUS="$1"
SUBJECT="$2"
MESSAGE="$3"
HTML_FILE="${4:-}"

case "$STATUS" in
    success|failure)
        ;;
    *)
        usage
        ;;
esac

[[ -n "$SUBJECT" && -n "$MESSAGE" && -n "$NOTIFY_TO" ]] || usage

if [[ -n "$HTML_FILE" && ! -r "$HTML_FILE" ]]; then
    echo "HTML report is not readable: $HTML_FILE" >&2
    exit 2
fi

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

    if [[ -n "$HTML_FILE" ]]; then
        BOUNDARY="=_homelab_${$}_$(date +%s)"

        printf 'MIME-Version: 1.0\n'
        printf 'Content-Type: multipart/alternative; boundary="%s"\n' "$BOUNDARY"
        printf '\n'

        printf '%s\n' "--$BOUNDARY"
        printf 'Content-Type: text/plain; charset=UTF-8\n'
        printf 'Content-Transfer-Encoding: 8bit\n'
        printf '\n'
        printf 'Infrastructure Notification\n'
        printf 'Host: %s\n' "$HOST"
        printf 'Time: %s\n' "$TIMESTAMP"
        printf 'Status: %s\n\n' "$STATUS"
        printf '%s\n' "$MESSAGE"

        printf '\n%s\n' "--$BOUNDARY"
        printf 'Content-Type: text/html; charset=UTF-8\n'
        printf 'Content-Transfer-Encoding: 8bit\n'
        printf '\n'
        cat "$HTML_FILE"
        printf '\n%s--\n' "--$BOUNDARY"
    else
        printf '\n'
        printf 'Infrastructure Notification\n'
        printf 'Host: %s\n' "$HOST"
        printf 'Time: %s\n' "$TIMESTAMP"
        printf 'Status: %s\n\n' "$STATUS"
        printf '%s\n' "$MESSAGE"
    fi
} | "$MSMTP_BIN" -a "$MSMTP_ACCOUNT" -t 2>>"$LOG_FILE"; then

    log "SUCCESS: Email delivered to $NOTIFY_TO: $EMAIL_SUBJECT"
else
    RC=$?
    log "ERROR: Email delivery failed (exit code $RC): $EMAIL_SUBJECT"
    exit "$RC"
fi
