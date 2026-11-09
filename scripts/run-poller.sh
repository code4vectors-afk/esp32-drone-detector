#!/usr/bin/env bash
#
# run-poller.sh — cron-safe wrapper around gmail-to-ntfy.py
#
# Cron runs with a minimal environment and nobody watching. This wrapper:
#   1. loads the alert config (cron does not inherit your shell exports)
#   2. runs one poll
#   3. logs the result
#   4. ALERTS YOU if the poll fails
#
# Step 4 is the point. The original problem was alerts failing silently —
# an email you never noticed. A bridge that breaks silently would reproduce
# exactly that failure, just one layer deeper.
#
# USAGE
#   ./run-poller.sh                  # normal cron invocation
#   CONFIG=/path/to.env ./run-poller.sh
#
# CRONTAB
#   */2 * * * *  ~/Documents/esp32-drone-detector/scripts/run-poller.sh

set -uo pipefail

CONFIG="${CONFIG:-$HOME/.config/drone-alerts/ntfy.env}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLLER="$SCRIPT_DIR/gmail-to-ntfy.py"
LOG="${POLLER_LOG:-$HOME/.config/drone-alerts/poller.log}"
LOCK="/tmp/gmail-to-ntfy.lock"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# ── Config ────────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
  # Cannot even load config — nothing to alert with. Log and bail.
  log "FATAL: config not found at $CONFIG"
  exit 78   # EX_CONFIG
fi
# shellcheck disable=SC1090
source "$CONFIG"

if [[ -z "${NTFY_TOPIC:-}" ]]; then
  log "FATAL: NTFY_TOPIC unset after sourcing $CONFIG"
  exit 78
fi

# ── Single instance ───────────────────────────────────────────────────────────
# A slow IMAP run must not overlap with the next cron tick.
if ! mkdir "$LOCK" 2>/dev/null; then
  log "previous run still active, skipping"
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT

# ── Run ───────────────────────────────────────────────────────────────────────
OUTPUT=$("$POLLER" --once 2>&1)
RC=$?

if [[ $RC -eq 0 ]]; then
  # Only log when something actually happened, to keep the file readable.
  if echo "$OUTPUT" | grep -q "notification(s) published"; then
    log "$(echo "$OUTPUT" | grep -E 'pushed|published' | tr '\n' ' ')"
  fi
  exit 0
fi

# ── Failure: tell the user ────────────────────────────────────────────────────
log "FAILED rc=$RC: $(echo "$OUTPUT" | tr '\n' ' ' | cut -c1-400)"

# Exit 2 is "no password / cannot authenticate" — the most likely cron breakage
# (locked keychain after reboot before first login).
case $RC in
  2) REASON="cannot reach mailbox (auth/keychain?)" ;;
  *) REASON="poller exited $RC" ;;
esac

SERVER="${NTFY_SERVER:-https://ntfy.sh}"
curl -s -m 15 -X POST "${SERVER}/${NTFY_TOPIC}" \
  -H "Title: Drone alert pipe is DOWN" \
  -H "Priority: 5" \
  -H "Tags: warning" \
  -d "The Gmail to ntfy bridge failed on $(hostname -s).

Reason: ${REASON}

This means drone alerts may not reach you. Check:
  tail -20 ${LOG}

Last output:
$(echo "$OUTPUT" | tail -5)" >/dev/null 2>&1

exit $RC
