#!/usr/bin/env python3
"""
alert.py — Multi-channel alert dispatcher for the drone detection node.

Sends a detection alert to one or more delivery channels with severity-based
escalation and rate limiting.

WHY THIS EXISTS
---------------
Carrier email-to-SMS gateways are largely dead (see docs/ALERTING.md). SMS now
requires a paid API. This script abstracts the delivery channels so the
detection logic does not care how the alert travels.

CHANNELS (all optional — enable by setting the relevant env vars)
-----------------------------------------------------------------
  ntfy      Free, self-hostable push. Best primary channel.
  pushover  Paid (one-time $5). Supports priority-2 emergency: repeats
            every 60s until the alert is acknowledged. SMS cannot do this.
  twilio    Real SMS via API (~$0.0079/msg US).
  gateway   Legacy carrier email-to-SMS gateway. DEGRADED — see docs.
  email     Plain email via himalaya. Useful as a last-resort audit trail.

SEVERITY → CHANNEL BEHAVIOUR
----------------------------
  info      ntfy normal  ·  pushover quiet       ·  (no SMS)
  alert     ntfy high    ·  pushover high        ·  SMS
  critical  ntfy urgent  ·  pushover EMERGENCY   ·  SMS
            (pushover emergency bypasses Do-Not-Disturb and repeats
             until acknowledged)

USAGE
-----
  ./alert.py --severity critical --title "Non-cooperative drone" \
             --message "CONF 92% | MAC A4:12:6D:xx | ch 6 | -58 dBm"

  ./alert.py --severity alert --title "Hybrid node offline" \
             --message "Node PE-01 no heartbeat for 300s"

  ./alert.py --dry-run --severity critical --title T --message M

ENV VARS
--------
  NTFY_TOPIC                 e.g. drone-alerts-8f3a2b
  NTFY_SERVER                default https://ntfy.sh
  PUSHOVER_TOKEN             app token
  PUSHOVER_USER              user key
  TWILIO_ACCOUNT_SID         ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
  TWILIO_AUTH_TOKEN
  TWILIO_FROM                +1XXXXXXXXXX (your Twilio number)
  ALERT_SMS_TO               +1XXXXXXXXXX (your mobile)
  ALERT_GATEWAY_ADDRESS      15551234567@vtext.com  (legacy, optional)
  ALERT_EMAIL_TO             you@example.com
  ALERT_STATE_FILE           default ~/.drone-alert-state.json
  ALERT_DRY_RUN              set to 1 to force dry-run

Dedup keys: pass --key to control the rate-limit bucket. Alerts with the same
key inside the cooldown window are suppressed. Default key is the title.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# ── Severity definitions ─────────────────────────────────────────────────────

SEVERITIES = ("info", "alert", "critical")

# Cooldown in seconds per severity. Prevents alert storms from a detection
# system that re-fires every scan cycle. Critical is short but non-zero so a
# sustained contact does not generate thousands of messages.
COOLDOWN = {"info": 3600, "alert": 900, "critical": 120}

NTFY_PRIORITY = {"info": "2", "alert": "4", "critical": "5"}
NTFY_TAGS = {
    "info": "information_source",
    "alert": "warning",
    "critical": "rotating_light",
}

PUSHOVER_PRIORITY = {"info": "-1", "alert": "1", "critical": "2"}
# Emergency repeat window, only used when priority == 2
PUSHOVER_RETRY = "60"    # seconds between repeats
PUSHOVER_EXPIRE = "3600"  # stop repeating after 1 hour

SMS_ENABLED = {"info": False, "alert": True, "critical": True}

TIMEOUT = 15


# ── State / rate limiting ────────────────────────────────────────────────────

def state_path() -> Path:
    return Path(os.environ.get("ALERT_STATE_FILE", Path.home() / ".drone-alert-state.json"))


def load_state() -> dict:
    p = state_path()
    if not p.exists():
        return {}
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def save_state(state: dict) -> None:
    p = state_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(state, indent=2))
        p.chmod(0o600)
    except OSError as exc:
        warn(f"could not persist alert state to {p}: {exc}")


def suppressed(key: str, severity: str, state: dict) -> int:
    """Return remaining cooldown seconds if suppressed, else 0."""
    entry = state.get(key)
    if not entry:
        return 0
    elapsed = time.time() - float(entry.get("ts", 0))
    remaining = COOLDOWN[severity] - elapsed
    # Only suppress if the previous alert was at the same or higher severity.
    # A severity escalation always breaks through.
    prev_rank = SEVERITIES.index(entry.get("severity", "info"))
    if SEVERITIES.index(severity) > prev_rank:
        return 0
    return int(remaining) if remaining > 0 else 0


# ── Output helpers ───────────────────────────────────────────────────────────

def ok(msg: str) -> None:
    print(f"  \033[32m✓\033[0m {msg}")


def warn(msg: str) -> None:
    print(f"  \033[33m!\033[0m {msg}", file=sys.stderr)


def fail(msg: str) -> None:
    print(f"  \033[31m✗\033[0m {msg}", file=sys.stderr)


def skipped(msg: str) -> None:
    print(f"  \033[90m–\033[0m {msg}")


# ── Channels ─────────────────────────────────────────────────────────────────

def send_ntfy(title: str, message: str, severity: str, dry: bool) -> bool:
    topic = os.environ.get("NTFY_TOPIC")
    if not topic:
        skipped("ntfy: NTFY_TOPIC not set")
        return False
    server = os.environ.get("NTFY_SERVER", "https://ntfy.sh").rstrip("/")
    url = f"{server}/{urllib.parse.quote(topic)}"
    if dry:
        ok(f"ntfy: would POST to {url} (priority {NTFY_PRIORITY[severity]})")
        return True
    req = urllib.request.Request(
        url,
        data=message.encode("utf-8"),
        method="POST",
        headers={
            "Title": title.encode("ascii", "ignore").decode(),
            "Priority": NTFY_PRIORITY[severity],
            "Tags": NTFY_TAGS[severity],
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            if 200 <= resp.status < 300:
                ok(f"ntfy: delivered (HTTP {resp.status})")
                return True
            fail(f"ntfy: HTTP {resp.status}")
            return False
    except urllib.error.URLError as exc:
        fail(f"ntfy: {exc}")
        return False


def send_pushover(title: str, message: str, severity: str, dry: bool) -> bool:
    token = os.environ.get("PUSHOVER_TOKEN")
    user = os.environ.get("PUSHOVER_USER")
    if not (token and user):
        skipped("pushover: PUSHOVER_TOKEN/PUSHOVER_USER not set")
        return False
    fields = {
        "token": token,
        "user": user,
        "title": title,
        "message": message,
        "priority": PUSHOVER_PRIORITY[severity],
    }
    if PUSHOVER_PRIORITY[severity] == "2":
        # Emergency: repeat until acknowledged.
        fields["retry"] = PUSHOVER_RETRY
        fields["expire"] = PUSHOVER_EXPIRE
    if dry:
        ok(f"pushover: would send priority {fields['priority']}"
           + (" (emergency, repeats until ack)" if fields["priority"] == "2" else ""))
        return True
    data = urllib.parse.urlencode(fields).encode()
    try:
        with urllib.request.urlopen(
            "https://api.pushover.net/1/messages.json", data=data, timeout=TIMEOUT
        ) as resp:
            if 200 <= resp.status < 300:
                ok(f"pushover: delivered (priority {fields['priority']})")
                return True
            fail(f"pushover: HTTP {resp.status}")
            return False
    except urllib.error.URLError as exc:
        fail(f"pushover: {exc}")
        return False


def send_twilio(title: str, message: str, severity: str, dry: bool) -> bool:
    if not SMS_ENABLED[severity]:
        skipped(f"twilio: SMS disabled for severity '{severity}' (cost control)")
        return False
    sid = os.environ.get("TWILIO_ACCOUNT_SID")
    token = os.environ.get("TWILIO_AUTH_TOKEN")
    sender = os.environ.get("TWILIO_FROM")
    to = os.environ.get("ALERT_SMS_TO")
    if not all((sid, token, sender, to)):
        skipped("twilio: TWILIO_ACCOUNT_SID/AUTH_TOKEN/FROM or ALERT_SMS_TO not set")
        return False

    body = f"[{severity.upper()}] {title}\n{message}"
    if len(body) > 1500:
        body = body[:1497] + "..."
    if dry:
        ok(f"twilio: would SMS {to} ({len(body)} chars)")
        return True
    try:
        from twilio.rest import Client  # imported lazily; optional dependency
    except ImportError:
        fail("twilio: python package not installed (pip install twilio)")
        return False
    try:
        client = Client(sid, token)
        msg = client.messages.create(body=body, from_=sender, to=to)
        ok(f"twilio: queued SMS sid={msg.sid} status={msg.status}")
        return True
    except Exception as exc:  # twilio raises a variety of errors
        fail(f"twilio: {type(exc).__name__}: {exc}")
        return False


def send_gateway(title: str, message: str, severity: str, dry: bool) -> bool:
    """Legacy carrier email-to-SMS gateway. Largely discontinued — see docs."""
    addr = os.environ.get("ALERT_GATEWAY_ADDRESS")
    if not addr:
        skipped("gateway: ALERT_GATEWAY_ADDRESS not set")
        return False
    warn("gateway: carrier gateways are degraded or dead for most US carriers "
         "(T-Mobile Dec 2024, AT&T Jun 2025, Verizon retiring 2027-03-31)")
    # SMS gateways truncate; keep it short and strip anything non-ASCII.
    body = f"{severity.upper()}: {title} | {message}"
    body = body.encode("ascii", "ignore").decode()[:300]
    return _send_email(addr, "", body, dry, label="gateway")


def send_email(title: str, message: str, severity: str, dry: bool) -> bool:
    addr = os.environ.get("ALERT_EMAIL_TO")
    if not addr:
        skipped("email: ALERT_EMAIL_TO not set")
        return False
    return _send_email(addr, f"[{severity.upper()}] {title}", message, dry, label="email")


def _send_email(to: str, subject: str, body: str, dry: bool, label: str) -> bool:
    if dry:
        ok(f"{label}: would email {to} (subject '{subject}')")
        return True
    try:
        proc = subprocess.run(
            ["himalaya", "message", "send"],
            input=f"To: {to}\nSubject: {subject}\n\n{body}\n".encode(),
            capture_output=True,
            timeout=TIMEOUT,
        )
        if proc.returncode == 0:
            ok(f"{label}: sent via himalaya to {to}")
            return True
        fail(f"{label}: himalaya exited {proc.returncode}: "
             f"{proc.stderr.decode(errors='replace').strip()[:200]}")
        return False
    except FileNotFoundError:
        fail(f"{label}: himalaya not found on PATH")
        return False
    except subprocess.TimeoutExpired:
        fail(f"{label}: himalaya timed out")
        return False


CHANNELS = {
    "ntfy": send_ntfy,
    "pushover": send_pushover,
    "twilio": send_twilio,
    "gateway": send_gateway,
    "email": send_email,
}


# ── Main ─────────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Dispatch a drone-detection alert across delivery channels.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--severity", required=True, choices=SEVERITIES)
    ap.add_argument("--title", required=True)
    ap.add_argument("--message", required=True)
    ap.add_argument("--key", help="rate-limit bucket key (default: the title)")
    ap.add_argument("--channels", default="ntfy,pushover,twilio,gateway,email",
                    help="comma-separated subset of channels to attempt")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="bypass the rate limiter")
    args = ap.parse_args(argv)

    dry = args.dry_run or os.environ.get("ALERT_DRY_RUN") == "1"
    key = args.key or args.title

    print(f"\n\033[1mALERT\033[0m  severity={args.severity}  key={key!r}")
    print(f"  title:   {args.title}")
    print(f"  message: {args.message}")
    print()

    # Rate limit (skipped in dry-run so testing is not blocked)
    if not dry and not args.force:
        state = load_state()
        remaining = suppressed(key, args.severity, state)
        if remaining:
            print(f"  \033[33mSUPPRESSED\033[0m — same key within cooldown, "
                  f"{remaining}s remaining\n")
            return 0

    attempted = 0
    delivered = 0
    for name in [c.strip() for c in args.channels.split(",") if c.strip()]:
        fn = CHANNELS.get(name)
        if fn is None:
            warn(f"unknown channel: {name}")
            continue
        attempted += 1
        if fn(args.title, args.message, args.severity, dry):
            delivered += 1

    # Record state on real sends only
    if not dry:
        state = load_state()
        state[key] = {"ts": time.time(), "severity": args.severity}
        save_state(state)

    print()
    if attempted == 0:
        print("  \033[31mno channels configured\033[0m — set env vars, see --help\n")
        return 2
    if delivered == 0:
        print("  \033[31mALL CHANNELS FAILED\033[0m — alert not delivered\n")
        return 1
    print(f"  \033[32m{delivered}/{attempted} channel(s) succeeded\033[0m\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
