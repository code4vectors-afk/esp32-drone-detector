#!/usr/bin/env bash
#
# status.sh — health check for the drone alert pipeline
#
# Shows both delivery channels, the poller schedule, and whether Gmail has
# anything queued that has not been pushed yet.
#
# USAGE
#   ./status.sh            # summary
#   ./status.sh --topics   # also list recent notifications on each topic
#
# Exit codes: 0 healthy, 1 something wrong

set -uo pipefail

CONFIG="${CONFIG:-$HOME/.config/drone-alerts/ntfy.env}"
LABEL="com.c4v.drone-alerts-poller"
SHOW_TOPICS=0
[[ "${1:-}" == "--topics" ]] && SHOW_TOPICS=1

GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; DIM=$'\033[90m'; RST=$'\033[0m'
pass() { printf "  ${GRN}✓${RST} %s\n" "$1"; }
warn() { printf "  ${YEL}!${RST} %s\n" "$1"; }
bad()  { printf "  ${RED}✗${RST} %s\n" "$1"; }
hdr()  { printf "\n${RST}\033[1m%s${RST}\n" "$1"; }

FAILED=0

echo ""
echo "══════════════════════════════════════════"
echo "  Drone Alert Pipeline — Status"
echo "══════════════════════════════════════════"

# ── Config ───────────────────────────────────────────────────────────────────
hdr "Config"
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
  pass "loaded $CONFIG"
else
  bad "missing $CONFIG"
  exit 1
fi

if [[ -n "${NTFY_TOPIC:-}" ]]; then
  pass "primary topic:  $NTFY_TOPIC"
else
  bad "NTFY_TOPIC unset"
  FAILED=1
fi
if [[ -n "${NTFY_BACKSTOP_TOPIC:-}" ]]; then
  pass "backstop topic: $NTFY_BACKSTOP_TOPIC"
else
  warn "NTFY_BACKSTOP_TOPIC unset (no always-on channel)"
fi
pass "matching From:  ${MATCH_FROM:-(none)}"
pass "lookback:       ${LOOKBACK:-14} days"

# ── Primary channel ──────────────────────────────────────────────────────────
hdr "Channel A — launchd poller (priority 5)"

STATE=$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)
if [[ -z "$STATE" ]]; then
  bad "LaunchAgent not loaded"
  warn "load it: launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/$LABEL.plist"
  FAILED=1
else
  PROG=$(echo "$STATE" | grep -oE "^\s+program = .*" | sed 's/.*= //')
  RUNS=$(echo "$STATE" | grep -oE "runs = [0-9]+" | head -1 | grep -oE "[0-9]+")
  RC=$(echo "$STATE" | grep -oE "last exit code = -?[0-9]+" | grep -oE "\-?[0-9]+$")

  pass "loaded (${RUNS:-0} runs)"
  if [[ "$PROG" == *"/Documents/"* ]]; then
    bad "running from ~/Documents — TCC will block it (exit 126)"
    warn "reinstall: ./install-service.sh"
    FAILED=1
  else
    pass "program: $PROG"
  fi
  if [[ "${RC:-0}" -eq 0 ]]; then
    pass "last exit code: 0"
  else
    bad "last exit code: $RC"
    FAILED=1
  fi
fi

LOG="$HOME/.config/drone-alerts/poller.log"
if [[ -f "$LOG" ]]; then
  LAST=$(tail -1 "$LOG" 2>/dev/null)
  [[ -n "$LAST" ]] && printf "  ${DIM}last log: %s${RST}\n" "$LAST"
fi

ERRLOG="$HOME/.config/drone-alerts/launchd.err.log"
if [[ -s "$ERRLOG" ]]; then
  NEWERR=$(grep -c "Operation not permitted" "$ERRLOG" 2>/dev/null || echo 0)
  [[ "$NEWERR" -gt 0 ]] && warn "$NEWERR TCC error(s) in stderr (may be historical)"
fi

# ── Backstop channel ─────────────────────────────────────────────────────────
hdr "Channel B — Gmail forward (always-on)"
echo "  ${DIM}Gmail filters cannot be inspected from here.${RST}"
echo "  ${DIM}Verify by confirming a real alert reaches the backstop topic.${RST}"

# ── Topic message counts ─────────────────────────────────────────────────────
hdr "Delivery"

count_topic() {
  curl -s -m 12 "https://ntfy.sh/$1/json?poll=1" 2>/dev/null \
    | grep -c '"event":"message"' 2>/dev/null || echo 0
}

if [[ -n "${NTFY_TOPIC:-}" ]]; then
  N=$(count_topic "$NTFY_TOPIC")
  pass "primary topic:  ${N} message(s)"
  if [[ "$SHOW_TOPICS" -eq 1 && "$N" -gt 0 ]]; then
    curl -s -m 12 "https://ntfy.sh/$NTFY_TOPIC/json?poll=1" | python3 -c "
import sys, json
msgs=[]
for line in sys.stdin:
    line=line.strip()
    if not line: continue
    try: d=json.loads(line)
    except Exception: continue
    if d.get('event')=='message': msgs.append(d)
for d in msgs[-5:]:
    print(f\"     [{d.get('priority')}] {str(d.get('title'))[:64]}\")
"
  fi
fi

if [[ -n "${NTFY_BACKSTOP_TOPIC:-}" ]]; then
  N=$(count_topic "$NTFY_BACKSTOP_TOPIC")
  pass "backstop topic: ${N} message(s)"
fi

# ── Mailbox ──────────────────────────────────────────────────────────────────
hdr "Mailbox"
PW=$(security find-generic-password -a "${GMAIL_USER:-cemirsilva@gmail.com}" \
       -s "${GMAIL_KEYCHAIN_SERVICE:-himalaya-gmail-app-password}" -w 2>/dev/null)
if [[ -z "$PW" ]]; then
  bad "cannot read app password from keychain"
  FAILED=1
else
  pass "keychain access OK"
  python3 - "${GMAIL_USER:-cemirsilva@gmail.com}" "$PW" "${MATCH_FROM:-}" <<'PY' 2>/dev/null || warn "IMAP check failed"
import imaplib, sys, json, os, pathlib
user, pw, mfrom = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    M = imaplib.IMAP4_SSL("imap.gmail.com", 993); M.login(user, pw)
    M.select('"[Gmail]/All Mail"', readonly=True)
    q = f'FROM "{mfrom}"' if mfrom else "ALL"
    typ, d = M.search(None, q)
    n = len(d[0].split()) if d and d[0] else 0
    print(f"  \033[32m✓\033[0m {n} matching message(s) in All Mail")
    # How many are untracked?
    sf = os.environ.get("ALERT_STATE_FILE", str(pathlib.Path.home()/".gmail-to-ntfy-state.json"))
    seen = set(json.load(open(sf)).get("seen", [])) if pathlib.Path(sf).exists() else set()
    uids = d[0].split() if d and d[0] else []
    pending = [u for u in uids if u.decode() not in seen]
    if pending:
        print(f"  \033[33m!\033[0m {len(pending)} not yet pushed (next poll will send)")
    else:
        print("  \033[32m✓\033[0m nothing pending")
    M.logout()
except Exception as e:
    print(f"  \033[31m✗\033[0m IMAP: {type(e).__name__}: {e}")
PY
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════"
if [[ "$FAILED" -eq 0 ]]; then
  printf "  ${GRN}HEALTHY${RST}\n"
else
  printf "  ${RED}ATTENTION NEEDED${RST}\n"
fi
echo "══════════════════════════════════════════"
echo ""
exit "$FAILED"
