#!/usr/bin/env bash
#
# modem-preflight.sh — Can this aircard actually send SMS?
#
# Walks the full chain from "is a modem present" to "did the carrier accept the
# message", so a failure tells you WHICH layer broke instead of just "SMS didn't
# work".
#
# The most common failure by far: a data-only SIM. Many WWAN/aircard plans are
# provisioned for data with SMS disabled at the carrier. The modem is fine, the
# SIM registers fine, data works fine — and SMS returns CMS ERROR.
#
# USAGE
#   ./modem-preflight.sh                 # diagnose, do not send
#   ./modem-preflight.sh --send +1555... # diagnose, then send a test SMS
#
# Exit codes: 0 = ready, 1 = a check failed, 2 = missing dependency

set -uo pipefail

PASS=0
FAIL=0
WARN=0
SEND_TO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --send) SEND_TO="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

c_pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS+1)); }
c_fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL+1)); }
c_warn() { printf "  \033[33m!\033[0m %s\n" "$1"; WARN=$((WARN+1)); }
c_skip() { printf "  \033[90m–\033[0m %s\n" "$1"; }
hdr()    { printf "\n\033[1m%s\033[0m\n" "$1"; }

echo ""
echo "=============================================="
echo " Aircard SMS Preflight"
echo "=============================================="

# ── 1. Dependencies ──────────────────────────────────────────────────────────
hdr "1. Tooling"

if command -v mmcli >/dev/null 2>&1; then
  c_pass "mmcli present ($(command -v mmcli))"
elif command -v gammu >/dev/null 2>&1; then
  c_warn "mmcli absent, but gammu present — this script targets mmcli"
else
  c_fail "neither mmcli nor gammu installed"
  echo ""
  echo "  Install ModemManager:"
  echo "    Debian/Ubuntu/Pi OS:  sudo apt install modemmanager"
  echo "    Fedora:               sudo dnf install ModemManager"
  exit 2
fi

if ! systemctl is-active --quiet ModemManager 2>/dev/null; then
  if pgrep -x ModemManager >/dev/null 2>&1; then
    c_pass "ModemManager running"
  else
    c_warn "ModemManager not running — try: sudo systemctl start ModemManager"
  fi
else
  c_pass "ModemManager service active"
fi

# ── 2. Modem detected ────────────────────────────────────────────────────────
hdr "2. Modem detection"

if ! MM_LIST=$(mmcli -L 2>&1); then
  c_fail "mmcli -L failed: ${MM_LIST}"
  exit 1
fi

if echo "$MM_LIST" | grep -q "No modems were found"; then
  c_fail "no modem detected"
  echo ""
  echo "  Troubleshooting:"
  echo "    • Is the aircard seated and powered? (check: lsusb)"
  echo "    • Did it bind as a serial device? (check: ls /dev/ttyUSB* /dev/ttyACM*)"
  echo "    • Some cards ship in CD-ROM/storage mode and need usb_modeswitch"
  echo "    • Some are MBIM/QMI only — ModemManager handles those, but the"
  echo "      card must not be bound to a competing driver (qmi_wwan, cdc_mbim)"
  exit 1
fi

MODEM_IDX=$(echo "$MM_LIST" | grep -o 'Modem/[0-9]*' | head -1 | cut -d/ -f2)
MODEM_COUNT=$(echo "$MM_LIST" | grep -c 'Modem/')
c_pass "modem detected: Modem/${MODEM_IDX}${MODEM_COUNT:+ (${MODEM_COUNT} total)}"

if [[ "$MODEM_COUNT" -gt 1 ]]; then
  c_warn "multiple modems — set ALERT_MODEM_INDEX to pick one explicitly"
fi

# ── 3. Modem state ───────────────────────────────────────────────────────────
hdr "3. Modem state"

MM_INFO=$(mmcli -m "$MODEM_IDX" 2>&1 || true)

STATE=$(echo "$MM_INFO" | grep -oP 'state:\s*\K\S+' | head -1 || echo "unknown")
case "$STATE" in
  registered|connected)
    c_pass "state: ${STATE}" ;;
  disabled)
    c_fail "state: disabled — try: sudo mmcli -m ${MODEM_IDX} --enable" ;;
  *)
    c_warn "state: ${STATE} (expected 'registered' or 'connected')" ;;
esac

ACCESS_TECH=$(echo "$MM_INFO" | grep -oP 'access tech:\s*\K.*' | head -1 | xargs || echo "")
[[ -n "$ACCESS_TECH" ]] && c_pass "access tech: ${ACCESS_TECH}"

OPERATOR=$(echo "$MM_INFO" | grep -oP 'operator name:\s*\K.*' | head -1 | xargs || echo "")
if [[ -n "$OPERATOR" ]]; then
  c_pass "operator: ${OPERATOR}"
else
  c_warn "operator unknown — SIM may not be registered on a network"
fi

SIGNAL=$(echo "$MM_INFO" | grep -oP 'signal quality:\s*\K.*' | head -1 | xargs || echo "")
[[ -n "$SIGNAL" ]] && c_pass "signal: ${SIGNAL}"

# ── 4. SIM ───────────────────────────────────────────────────────────────────
hdr "4. SIM"

if echo "$MM_INFO" | grep -qE '^\s*SIM\s*\|'; then
  SIM_PATH=$(echo "$MM_INFO" | grep -oP 'SIM\s*\|\s*path:\s*\K\S+' | head -1 || echo "")
  c_pass "SIM present${SIM_PATH:+ (${SIM_PATH})}"

  SIM_IDX=$(echo "$SIM_PATH" | grep -o '[0-9]*$' || echo "0")
  SIM_INFO=$(mmcli -i "$SIM_IDX" 2>&1 || true)

  IMSI=$(echo "$SIM_INFO" | grep -oP 'imsi:\s*\K[0-9]+' | head -1 || echo "")
  if [[ -n "$IMSI" ]]; then
    # Show only the MCC/MNC prefix — the rest identifies the subscriber.
    c_pass "IMSI prefix: ${IMSI:0:6}... (MCC/MNC)"
    case "${IMSI:0:3}" in
      310|311|312|313|314|315|316) c_pass "home network: US (MCC ${IMSI:0:3})" ;;
      *) c_warn "MCC ${IMSI:0:3} is not a US network" ;;
    esac
  else
    c_warn "IMSI not readable (SIM may be PIN-locked or absent)"
  fi

  if echo "$SIM_INFO" | grep -qi "PIN"; then
    PIN_STATE=$(echo "$SIM_INFO" | grep -oP 'pin.*?lock:\s*\K\S+' | head -1 || echo "")
    [[ "$PIN_STATE" == "disabled" ]] && c_pass "SIM not PIN-locked" \
      || c_warn "SIM lock state: ${PIN_STATE:-unknown}"
  fi
else
  c_fail "no SIM detected — insert the SIM and re-run"
fi

# ── 5. SMS capability ────────────────────────────────────────────────────────
hdr "5. SMS capability"
echo "     (a data-only SIM passes every check above and still fails here)"
echo ""

# Query messaging capability via raw AT through ModemManager.
# AT+CSMS? reports which message services are available.
if AT_OUT=$(mmcli -m "$MODEM_IDX" --command='AT+CSMS?' 2>&1); then
  if echo "$AT_OUT" | grep -q "response:"; then
    RESP=$(echo "$AT_OUT" | sed -n 's/.*response: *//p')
    c_pass "AT+CSMS? → ${RESP}"
    case "$RESP" in
      *"+CSMS: 1"*) c_pass "modem reports SMS service available" ;;
      *"+CSMS: 0"*) c_warn "modem reports SMS service NOT available on this SIM" ;;
    esac
  else
    c_warn "could not parse AT+CSMS? response"
  fi
else
  c_warn "AT command channel unavailable"
  echo "       If the modem holds an active data connection, the AT port may be"
  echo "       locked. Try: sudo mmcli -m ${MODEM_IDX} --simple-disconnect"
fi

# Service centre number — if this is empty, SMS will not send.
if SC_OUT=$(mmcli -m "$MODEM_IDX" --command='AT+CSCA?' 2>&1); then
  SC=$(echo "$SC_OUT" | sed -n 's/.*response: *//p')
  if echo "$SC" | grep -qE '\+[0-9]{6,}'; then
    c_pass "SMSC configured: ${SC}"
  else
    c_fail "no SMS service centre number set — SMS cannot send"
    echo "       Set it with your carrier's SMSC, e.g. sudo mmcli -m ${MODEM_IDX} \\"
    echo "         --command='AT+CSCA=\"+1XXXXXXXXXX\",145'"
  fi
fi

# ── 6. Live send ─────────────────────────────────────────────────────────────
if [[ -n "$SEND_TO" ]]; then
  hdr "6. Test send → ${SEND_TO}"
  BODY="Aircard preflight test $(date '+%H:%M:%S')"

  if CREATE_OUT=$(mmcli -m "$MODEM_IDX" \
        --messaging-create-sms="text='${BODY}',number='${SEND_TO}'" 2>&1); then
    SMS_ID=$(echo "$CREATE_OUT" | grep -o '/SMS/[0-9]*' | tail -1 | cut -d/ -f3)
    if [[ -z "$SMS_ID" ]]; then
      c_fail "could not create SMS: ${CREATE_OUT}"
    else
      c_pass "SMS staged as /SMS/${SMS_ID}"
      if SEND_OUT=$(mmcli -s "$SMS_ID" --send 2>&1); then
        c_pass "send command accepted"
        sleep 5
        STATUS=$(mmcli -s "$SMS_ID" 2>&1 | grep -oP 'state:\s*\K.*' | xargs || echo "unknown")
        case "$STATUS" in
          sent)      c_pass "delivery state: sent — CHECK YOUR PHONE NOW" ;;
          pending)   c_warn "delivery state: pending (network may still be processing)" ;;
          failed)    c_fail "delivery state: failed" ;;
          *)         c_warn "delivery state: ${STATUS}" ;;
        esac
        echo ""
        echo "  If the modem reports 'sent' but no text arrives, the carrier is"
        echo "  dropping it — that is a plan/provisioning issue, not a modem issue."
      else
        c_fail "send failed: ${SEND_OUT}"
        echo ""
        echo "  A CMS ERROR here almost always means the SIM plan does not allow"
        echo "  SMS. Call the carrier and ask specifically:"
        echo "    \"Does this SIM's provisioning permit MO-SMS (mobile-originated SMS)?\""
      fi
    fi
  else
    c_fail "create failed: ${CREATE_OUT}"
  fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=============================================="
printf " passed: %d   warnings: %d   failed: %d\n" "$PASS" "$WARN" "$FAIL"
echo "=============================================="

if [[ "$FAIL" -gt 0 ]]; then
  echo ""
  echo "NOT READY — resolve the failures above."
  exit 1
fi

echo ""
if [[ -z "$SEND_TO" ]]; then
  echo "Structure looks good. To prove it end to end:"
  echo "  $0 --send +1YOURMOBILE"
else
  echo "Aircard SMS path is working."
  echo ""
  echo "Wire it into the dispatcher:"
  echo "  export ALERT_SMS_TO='+1YOURMOBILE'"
  echo "  ./scripts/alert.py --severity critical \\"
  echo "    --title 'Non-cooperative drone' --message 'CONF 92%' --channels modem"
fi
echo ""