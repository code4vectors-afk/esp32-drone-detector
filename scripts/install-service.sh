#!/usr/bin/env bash
#
# install-service.sh — deploy the alert poller as a user LaunchAgent (macOS)
#
# Two things this gets right that a naive install does not:
#
# 1. SCRIPTS LIVE OUTSIDE ~/Documents.
#    macOS TCC protects ~/Documents. A launchd-spawned process that tries to
#    execute a script inside it fails with "Operation not permitted", and the
#    failure is silent unless you are watching launchd's stderr. Deploying to
#    ~/.local/bin avoids the permission dependency entirely.
#
# 2. launchd, NOT cron.
#    Writing a crontab non-interactively hangs on modern macOS because of TCC.
#    launchd is the native scheduler and needs no special grant for user agents.
#
# It is idempotent: re-running replaces the deployed copy and reloads.
#
# USAGE
#   ./install-service.sh              # deploy + load
#   ./install-service.sh --uninstall  # stop + remove

set -euo pipefail

LABEL="com.c4v.drone-alerts-poller"
DEPLOY_DIR="$HOME/.local/bin/drone-alerts"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
CONFIG_DIR="$HOME/.config/drone-alerts"
REPO_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$1" >&2; exit 1; }

UID_NUM="$(id -u)"

# ── Uninstall ────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || launchctl unload -w "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  ok "service stopped and plist removed"
  warn "deployed scripts left at $DEPLOY_DIR (remove manually if desired)"
  exit 0
fi

echo ""
echo "Installing drone alert poller"
echo "────────────────────────────────────────────"

# ── Preflight ────────────────────────────────────────────────────────────────
[[ -f "$CONFIG_DIR/ntfy.env" ]] || die "config missing: $CONFIG_DIR/ntfy.env (run the ntfy setup first)"
[[ -f "$REPO_SCRIPTS/gmail-to-ntfy.py" ]] || die "gmail-to-ntfy.py not found in $REPO_SCRIPTS"
[[ -f "$REPO_SCRIPTS/run-poller.sh" ]] || die "run-poller.sh not found in $REPO_SCRIPTS"

command -v python3 >/dev/null || die "python3 not on PATH"

# ── Deploy scripts outside TCC-protected paths ───────────────────────────────
mkdir -p "$DEPLOY_DIR" "$CONFIG_DIR"
chmod 755 "$DEPLOY_DIR"
chmod 700 "$CONFIG_DIR"

install -m 755 "$REPO_SCRIPTS/gmail-to-ntfy.py" "$DEPLOY_DIR/gmail-to-ntfy.py"
install -m 755 "$REPO_SCRIPTS/run-poller.sh"    "$DEPLOY_DIR/run-poller.sh"
ok "deployed to $DEPLOY_DIR"

# ── Write the LaunchAgent ────────────────────────────────────────────────────
mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${DEPLOY_DIR}/run-poller.sh</string>
    </array>

    <key>StartInterval</key>
    <integer>120</integer>

    <key>RunAtLoad</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>60</integer>

    <key>StandardOutPath</key>
    <string>${CONFIG_DIR}/launchd.out.log</string>

    <key>StandardErrorPath</key>
    <string>${CONFIG_DIR}/launchd.err.log</string>

    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>${HOME}</string>
        <key>CONFIG</key>
        <string>${CONFIG_DIR}/ntfy.env</string>
    </dict>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null || die "generated plist is invalid"
ok "plist written and validated"

# ── (Re)load ─────────────────────────────────────────────────────────────────
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null \
  || launchctl load -w "$PLIST" \
  || die "could not load the LaunchAgent"
ok "LaunchAgent loaded (gui/$UID_NUM)"

# ── Verify it actually runs ──────────────────────────────────────────────────
sleep 8
if launchctl list | grep -q "$LABEL"; then
  LINE=$(launchctl list | grep "$LABEL")
  PID=$(echo "$LINE" | awk '{print $1}')
  RC=$(echo "$LINE"  | awk '{print $2}')
  if [[ "$RC" == "0" ]]; then
    ok "service registered, last run exit 0"
  else
    warn "service registered but last exit code was $RC"
  fi
else
  warn "service not present in launchctl list"
fi

if [[ -s "$CONFIG_DIR/launchd.err.log" ]]; then
  warn "stderr present — inspect: tail $CONFIG_DIR/launchd.err.log"
  tail -3 "$CONFIG_DIR/launchd.err.log" | sed 's/^/      /'
else
  ok "clean stderr"
fi

echo ""
echo "────────────────────────────────────────────"
echo "  Polls every 120s for mail from:"
echo "    $(grep -E '^export MATCH_FROM' "$CONFIG_DIR/ntfy.env" | cut -d'"' -f2)"
echo ""
echo "  Logs:  $CONFIG_DIR/poller.log"
echo "  Stop:  $0 --uninstall"
echo "────────────────────────────────────────────"
echo ""
