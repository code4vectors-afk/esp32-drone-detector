#!/usr/bin/env python3
"""
gmail-to-ntfy.py — Turn incoming alert emails into high-priority ntfy pushes.

WHY THIS EXISTS
---------------
DroneAware (and most SaaS alerting) delivers notifications by email. Email is
easy to miss. ntfy push is not.

ntfy has a built-in email-to-topic bridge, so the simplest fix is a Gmail filter
that forwards to `ntfy-<topic>@ntfy.sh`. That works, but it has a hard limit:
**email publishing cannot set priority** — ntfy only reads the subject line.
Everything arrives at default priority, which will not break through Do Not
Disturb.

This script is the upgrade path. It reads the mailbox over IMAP and publishes
over the HTTP API instead, which supports priority, tags, click-through URLs
and delayed delivery.

  Email forward   → 5 minutes, zero code, default priority only
  This script     → full control: priority 5, tags, deep-link, dedupe

USAGE
-----
  ./gmail-to-ntfy.py --once                  # check mailbox, push, exit
  ./gmail-to-ntfy.py --loop 60               # poll every 60 seconds
  ./gmail-to-ntfy.py --once --dry-run        # show what would match
  ./gmail-to-ntfy.py --once --since-all      # ignore the seen-UID state

TYPICAL CRON / systemd timer
----------------------------
  */2 * * * *  /opt/drone/gmail-to-ntfy.py --once

ENV VARS
--------
  GMAIL_USER              code4vectors@gmail.com
  GMAIL_APP_PASSWORD      app password; if unset, read from the macOS keychain
  GMAIL_KEYCHAIN_SERVICE  default himalaya-gmail-app-password
  GMAIL_MAILBOX           default "[Gmail]/All Mail" (alert mail is often
                          auto-archived by a filter, so INBOX-only misses it)
  MATCH_FROM              substring match on From,  e.g. droneaware
  MATCH_SUBJECT           substring match on Subject, e.g. drone
  MATCH_REQUIRE_ALL       "1" = both must match (default), "0" = either
  NTFY_TOPIC              required to send
  NTFY_SERVER             default https://ntfy.sh
  NTFY_PRIORITY           default 5 (max) — this is the reason for the script
  NTFY_TAGS               default rotating_light
  ALERT_STATE_FILE        default ~/.gmail-to-ntfy-state.json
"""

from __future__ import annotations

import argparse
import email
import email.utils
import imaplib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from email.header import decode_header
from pathlib import Path

TIMEOUT = 20


# ── Helpers ──────────────────────────────────────────────────────────────────

def ok(m):
    print(f"  \033[32m✓\033[0m {m}")


def warn(m):
    print(f"  \033[33m!\033[0m {m}", file=sys.stderr)


def fail(m):
    print(f"  \033[31m✗\033[0m {m}", file=sys.stderr)


def get_password() -> str | None:
    pw = os.environ.get("GMAIL_APP_PASSWORD")
    if pw:
        return pw
    service = os.environ.get("GMAIL_KEYCHAIN_SERVICE", "himalaya-gmail-app-password")
    user = os.environ.get("GMAIL_USER", "code4vectors@gmail.com")
    try:
        r = subprocess.run(
            ["security", "find-generic-password", "-a", user, "-s", service, "-w"],
            capture_output=True, timeout=10,
        )
        if r.returncode == 0:
            return r.stdout.decode().strip()
    except (FileNotFoundError, subprocess.TimeoutExpired):
        pass
    return None


def decode_hdr(raw) -> str:
    if not raw:
        return ""
    parts = []
    for chunk, enc in decode_header(raw):
        if isinstance(chunk, bytes):
            parts.append(chunk.decode(enc or "utf-8", errors="replace"))
        else:
            parts.append(chunk)
    return " ".join(parts).strip()


def plain_body(msg) -> str:
    """Extract the first text/plain part, falling back to a stripped HTML part."""
    if msg.is_multipart():
        for part in msg.walk():
            if part.get_content_type() == "text/plain" and not part.get_filename():
                try:
                    return part.get_payload(decode=True).decode(
                        part.get_content_charset() or "utf-8", errors="replace"
                    )
                except Exception:
                    continue
        for part in msg.walk():
            if part.get_content_type() == "text/html" and not part.get_filename():
                try:
                    html = part.get_payload(decode=True).decode(
                        part.get_content_charset() or "utf-8", errors="replace"
                    )
                    text = re.sub(r"<[^>]+>", " ", html)
                    return re.sub(r"\s+", " ", text).strip()
                except Exception:
                    continue
        return ""
    try:
        return msg.get_payload(decode=True).decode(
            msg.get_content_charset() or "utf-8", errors="replace"
        )
    except Exception:
        return ""


def state_path() -> Path:
    return Path(os.environ.get("ALERT_STATE_FILE", Path.home() / ".gmail-to-ntfy-state.json"))


def load_state() -> dict:
    p = state_path()
    if not p.exists():
        return {"seen": []}
    try:
        d = json.loads(p.read_text())
        d.setdefault("seen", [])
        return d
    except (json.JSONDecodeError, OSError):
        return {"seen": []}


def save_state(state: dict) -> None:
    # Keep the seen list bounded so the file cannot grow without limit.
    state["seen"] = state["seen"][-500:]
    p = state_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(state, indent=2))
        p.chmod(0o600)
    except OSError as exc:
        warn(f"could not persist state: {exc}")


# ── ntfy publish ─────────────────────────────────────────────────────────────

def publish(title: str, body: str, dry: bool) -> bool:
    topic = os.environ.get("NTFY_TOPIC")
    if not topic:
        fail("NTFY_TOPIC not set")
        return False
    server = (os.environ.get("NTFY_SERVER") or "https://ntfy.sh").rstrip("/")
    url = f"{server}/{urllib.parse.quote(topic)}"

    if len(body) > 3800:
        body = body[:3800] + "\n…(truncated)"

    priority = os.environ.get("NTFY_PRIORITY", "5")
    tags = os.environ.get("NTFY_TAGS", "rotating_light")

    if dry:
        ok(f"would push to {url}  priority={priority}  title={title!r}")
        print(f"     body: {body[:160]!r}")
        return True

    req = urllib.request.Request(
        url,
        data=body.encode("utf-8"),
        method="POST",
        headers={
            "Title": title.encode("ascii", "ignore").decode() or "Alert",
            "Priority": priority,
            "Tags": tags,
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            if 200 <= resp.status < 300:
                ok(f"pushed (priority {priority}): {title}")
                return True
            fail(f"ntfy HTTP {resp.status}")
            return False
    except urllib.error.URLError as exc:
        fail(f"ntfy: {exc}")
        return False


# ── Mailbox scan ─────────────────────────────────────────────────────────────

def matches(msg, mfrom: str, msubject: str, require_all: bool) -> bool:
    frm = decode_hdr(msg.get("From", "")).lower()
    sub = decode_hdr(msg.get("Subject", "")).lower()

    # Only evaluate criteria that were actually configured. Applying
    # require_all across an unset criterion would make a subject-only
    # match impossible.
    checks = []
    if mfrom:
        checks.append(mfrom.lower() in frm)
    if msubject:
        checks.append(msubject.lower() in sub)
    if not checks:
        return True
    return all(checks) if require_all else any(checks)


def scan(dry: bool, since_all: bool, lookback: int = 3, seed: bool = False) -> int:
    user = os.environ.get("GMAIL_USER", "code4vectors@gmail.com")
    pw = get_password()
    if not pw:
        fail("no password: set GMAIL_APP_PASSWORD or store one in the keychain")
        return 2

    # Default to All Mail: alert mail is frequently auto-archived by a
    # filter, in which case INBOX-only scanning silently sees nothing.
    mailbox = os.environ.get("GMAIL_MAILBOX") or "[Gmail]/All Mail"
    mfrom = os.environ.get("MATCH_FROM", "").strip()
    msubject = os.environ.get("MATCH_SUBJECT", "").strip()
    require_all = os.environ.get("MATCH_REQUIRE_ALL", "1") != "0"

    if not mfrom and not msubject:
        warn("neither MATCH_FROM nor MATCH_SUBJECT set — every new mail will match")

    state = load_state()
    seen = set(state["seen"])

    try:
        M = imaplib.IMAP4_SSL("imap.gmail.com", 993)
        M.login(user, pw)
    except Exception as exc:
        fail(f"IMAP login failed: {type(exc).__name__}: {exc}")
        return 2

    try:
        # imaplib does not quote mailbox names; "[Gmail]/All Mail" contains
        # a space and will fail to parse unless quoted explicitly.
        sel = mailbox if mailbox.startswith('"') else f'"{mailbox}"'
        typ, _ = M.select(sel, readonly=True)
        if typ != "OK":
            fail(f"cannot open mailbox {mailbox!r}")
            return 2

        # Build the narrowest server-side search we can.
        # Server-side pre-filter: deliberately broad, because Gmail's IMAP
        # search tokenizes rather than doing substring matching. A narrow
        # server query can silently return zero and we would never fetch the
        # message to test it locally. So: bound by date, optionally narrow by
        # FROM (a stable token), and let the local match be authoritative.
        since = (datetime.now(timezone.utc) - timedelta(days=lookback)
                 ).strftime("%d-%b-%Y")
        parts = [f"SINCE {since}"]
        if mfrom:
            parts.append(f'FROM "{mfrom}"')
        query = " ".join(parts)

        typ, data = M.search(None, query)
        if typ != "OK":
            fail(f"IMAP search failed: {data}")
            return 2

        uids = data[0].split() if data and data[0] else []
        new = [u for u in uids if since_all or u.decode() not in seen]

        print(f"  matched {len(uids)} message(s) server-side, "
              f"{len(new)} not yet processed")

        pushed = 0
        for uid in new:
            uid_s = uid.decode()
            typ, msg_data = M.fetch(uid, "(RFC822)")
            if typ != "OK" or not msg_data or not msg_data[0]:
                warn(f"could not fetch uid {uid_s}")
                continue
            raw = msg_data[0][1]
            if not isinstance(raw, (bytes, bytearray)):
                warn(f"unexpected fetch payload for uid {uid_s} "
                     f"(got {type(raw).__name__})")
                continue
            msg = email.message_from_bytes(raw)

            if not matches(msg, mfrom, msubject, require_all):
                # The server pre-filter is deliberately broad; the real match
                # happens here. Record it so it is not fetched again.
                state["seen"].append(uid_s)
                continue

            subject = decode_hdr(msg.get("Subject", "")) or "Alert"

            if seed:
                # Baseline mode: record existing mail as already-handled so
                # only FUTURE alerts fire. Avoids a historical flood of
                # notifications on first run.
                state["seen"].append(uid_s)
                continue
            sender = decode_hdr(msg.get("From", ""))
            body = plain_body(msg)
            date_hdr = decode_hdr(msg.get("Date", ""))

            print()
            print(f"  ── {subject}")
            print(f"     from: {sender}")
            if date_hdr:
                print(f"     date: {date_hdr}")

            # Trim the body: notification previews do not need full footers.
            snippet = re.sub(r"\n{3,}", "\n\n", body).strip()
            if len(snippet) > 900:
                snippet = snippet[:900] + "…"

            if publish(subject, snippet, dry):
                pushed += 1
            else:
                # Do not mark as seen on failure, so the next run retries it.
                continue
            # Always record. --since-all only widens the initial filter; it
            # must not cause duplicate pushes on the following run.
            state["seen"].append(uid_s)

        if not dry:
            save_state(state)
        print()
        ok(f"{pushed} notification(s) published" if pushed else "nothing new to publish")
        return 0
    finally:
        try:
            M.logout()
        except Exception:
            pass


# ── Main ─────────────────────────────────────────────────────────────────────

def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="Push alert emails to ntfy at high priority.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--once", action="store_true", help="scan once and exit")
    ap.add_argument("--loop", type=int, metavar="SECONDS",
                    help="poll repeatedly with this interval")
    ap.add_argument("--dry-run", action="store_true", help="match but do not publish")
    ap.add_argument("--since-all", action="store_true",
                    help="ignore seen-UID state (reprocess everything)")
    ap.add_argument("--seed", action="store_true",
                    help="baseline mode: mark current mail as already-handled "
                         "WITHOUT pushing. Run once before enabling alerts so "
                         "you do not get a flood of historical notifications.")
    ap.add_argument("--lookback", type=int, default=3, metavar="DAYS",
                    help="how many days back to scan server-side (default 3). "
                         "Gmail tokenizes search, so the server query is kept "
                         "broad and matching is done locally.")
    args = ap.parse_args(argv)

    if not args.once and not args.loop:
        args.once = True

    print()
    print("gmail-to-ntfy" + ("  [DRY RUN]" if args.dry_run else ""))
    print(f"  mailbox : {os.environ.get('GMAIL_USER', 'code4vectors@gmail.com')}"
          f"/{os.environ.get('GMAIL_MAILBOX') or '[Gmail]/All Mail'}")
    print(f"  match   : from={os.environ.get('MATCH_FROM', '(any)')!r} "
          f"subject={os.environ.get('MATCH_SUBJECT', '(any)')!r}")
    print(f"  target  : {os.environ.get('NTFY_SERVER', 'https://ntfy.sh')}"
          f"/{os.environ.get('NTFY_TOPIC', '(NTFY_TOPIC unset)')}")
    print(f"  priority: {os.environ.get('NTFY_PRIORITY', '5')}")
    print()

    if args.once:
        return scan(args.dry_run, args.since_all, args.lookback, args.seed)

    print(f"polling every {args.loop}s — Ctrl-C to stop\n")
    try:
        while True:
            scan(args.dry_run, args.since_all, args.lookback, args.seed)
            time.sleep(args.loop)
    except KeyboardInterrupt:
        print("\nstopped")
        return 0


if __name__ == "__main__":
    sys.exit(main())
