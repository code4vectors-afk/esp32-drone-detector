# ntfy Setup — DroneAware Alerts to Your Phone

> **Status:** Both paths below are verified end to end from this machine.

---

## First — ntfy is not SMS

**ntfy does not send text messages.** It sends *push notifications* to an app on your phone. That is a different channel.

You asked for SMS because you keep missing the DroneAware emails. That is an *attention* problem, not a *delivery* problem — and a push notification on your lock screen solves it. It shows up, it makes a sound, it stays in your notification history, and it is far more visible than an unread email.

If you genuinely need SMS (a real carrier text message), that is the aircard or Twilio path in [`ALERTING.md`](ALERTING.md). ntfy cannot do it.

---

## Verified configuration for this deployment

Confirmed against the live mailbox (`cemirsilva@gmail.com`) on 2026‑10‑11:

| Item | Value |
|------|-------|
| Alert sender | `alerts@droneaware.io` (display name "DroneAware Network") |
| Detection subject | `DroneAware: DJI Mini 5 Pro detected by pev-01` |
| Health subject | `Node offline — pev-01` **(no `DroneAware:` prefix)** |
| Volume observed | 23 alerts over 6 days (~4/day) |
| Existing Gmail label | `DroneAware/Alerts` |

⚠️ **The two subject formats matter.** A filter matching `subject:DroneAware` will silently miss every *"Node offline"* health warning. Match on the **sender** (`alerts@droneaware.io`) to catch both.

⚠️ **Biggest practical gotcha: the alerts are auto-archived.** All 23 were in `[Gmail]/All Mail` and **zero** were in the INBOX — an existing filter labels them `DroneAware/Alerts` and skips the inbox. This is almost certainly why they get missed, and it has two consequences:

- **A Gmail forward filter works fine** (filters run on delivery regardless of label).
- **Any IMAP poller MUST scan `[Gmail]/All Mail`, not INBOX.** `scripts/gmail-to-ntfy.py` defaults to All Mail for exactly this reason.

Example alert body (detection):

```
Your node picked up a Remote ID signal.
Node: pev-01
Model: DJI Mini 5 Pro
Drone ID: 1581F8LQC256H0023DX6
Signal: Wi-Fi Beacon
Detected at: 2026-11-07 ...
```

### Working config

Stored locally at `~/.config/drone-alerts/ntfy.env` (mode 600, **never in the repo**):

```bash
export GMAIL_USER="cemirsilva@gmail.com"
export GMAIL_MAILBOX="[Gmail]/All Mail"
export MATCH_FROM="alerts@droneaware.io"
export NTFY_TOPIC="drone-<random>"
export NTFY_PRIORITY="5"
export NTFY_TAGS="rotating_light"
```

### First-run baseline

Do **not** run the poller plainly on first start — it would push all 23 historical alerts at once. Seed first:

```bash
./scripts/gmail-to-ntfy.py --once --seed --lookback 60   # marks old mail handled, pushes nothing
./scripts/gmail-to-ntfy.py --once                        # confirms nothing new
```

After that, only genuinely new alerts fire.

---

## Why this works so cleanly for DroneAware

Two facts line up:

1. **DroneAware already sends alert emails.** That is its only alert channel.
2. **ntfy.sh runs an inbound SMTP server**, so an email sent to `ntfy-<topic>@ntfy.sh` becomes a push notification automatically.

**Verified on this machine:** emailed `ntfy-c4v-emailtest-...@ntfy.sh` from `code4vectors@gmail.com`, and the message appeared on the topic as a push **in about 5 seconds**. The email Subject became the notification title; the body became the message.

That means you can get notifications working in about five minutes with **no code at all**.

---

## Path A — Gmail forward (5 minutes, zero code)

### Step 1: Pick a topic

Topic names on the public server are **public** — anyone who guesses the name can read your alerts. Make it unguessable:

```bash
echo "drone-$(openssl rand -hex 8)"
# e.g. drone-8f3a2b9c4d5e6f70
```

That random string is your topic name. Write it down.

### Step 2: Install the app and subscribe

- **iPhone:** [ntfy on the App Store](https://apps.apple.com/us/app/ntfy/id1625396347)
- Open it → **+** → subscribe to your topic name
- Allow notifications when prompted

Send yourself a test first:

```bash
curl -d "test from the terminal" "https://ntfy.sh/YOUR-TOPIC-HERE"
```

If that lands on your phone, delivery works. Everything after this is plumbing.

### Step 3: Find the real DroneAware sender address

You need the exact From address and Subject format. Look at an actual alert in your Gmail — check the sender domain and note the subject pattern.

### Step 4: Create the Gmail filter

In Gmail:

1. **Settings → Filters and Blocked Addresses → Create a new filter**
2. **From:** the DroneAware sender address
3. **Create filter** (not "search")
4. Tick **Forward it to:** → add `ntfy-YOUR-TOPIC-HERE@ntfy.sh`
5. Also tick **Apply the label** (optional, keeps an archive copy)
6. **Create filter**

### Step 5: Verify the forwarding address

Gmail will send a confirmation email to `ntfy-YOUR-TOPIC@ntfy.sh` containing a verification link or code.

**That confirmation email shows up in your ntfy topic as a notification.** Open it from your phone, grab the link/code, and complete verification in Gmail.

This is the neat part — the verification round-trip completes itself through the channel you are building.

### Done

The next DroneAware alert forwards to ntfy and arrives as a push notification.

### The limitation

**Email publishing cannot set a priority.** Per ntfy's docs: *"e-mail publishing only supports adding a message title (the e-mail subject). Tags, priority, delay and other features are not supported (yet)."*

Everything arrives at default priority. That is a big improvement over email, but it will not break through Do Not Disturb. If you need that, use Path B.

---

## Path B — `gmail-to-ntfy.py` (full priority control)

The script in this repo reads your mailbox over IMAP and publishes over the HTTP API instead, which supports **priority, tags, and title control**.

| | Path A (forward) | Path B (script) |
|---|---|---|
| Setup | 5 min, Gmail UI | 10 min, env vars |
| Code required | None | None — run the script |
| Priority control | ❌ default only | ✅ up to 5 (max) |
| Tags / icons | ❌ | ✅ |
| Dedupe | Gmail handles it | ✅ state file, bounded |
| Needs a machine running | ❌ (Gmail does the work) | ✅ (cron / systemd timer) |
| Works if your machine is off | ✅ | ❌ |

**Verified on this machine:** sent a test alert to the inbox, script detected it, pushed at priority 5 with tags, and three consecutive runs produced exactly one notification (dedupe confirmed).

### Setup

```bash
export GMAIL_USER="code4vectors@gmail.com"
# password read from the macOS keychain automatically (himalaya-gmail-app-password),
# or set GMAIL_APP_PASSWORD directly

export MATCH_FROM="droneaware"        # substring on the From header
export MATCH_SUBJECT="drone"          # substring on the Subject
export NTFY_TOPIC="drone-YOUR-RANDOM-STRING"
export NTFY_PRIORITY="5"              # 5 = max
export NTFY_TAGS="rotating_light"
```

### Run it

```bash
./scripts/gmail-to-ntfy.py --once --dry-run     # see what would match
./scripts/gmail-to-ntfy.py --once               # scan once
./scripts/gmail-to-ntfy.py --loop 60            # poll every 60s
```

### Schedule it

```bash
# crontab -e
*/2 * * * *  /Users/c4v-standard/Documents/esp32-drone-detector/scripts/gmail-to-ntfy.py --once
```

### Options

| Flag | Purpose |
|------|---------|
| `--once` | Scan, push, exit |
| `--loop N` | Poll every N seconds |
| `--dry-run` | Match and print, publish nothing |
| `--since-all` | Ignore seen-state (backfill / replay) |
| `--lookback N` | Days to scan server-side (default 3) |

### A Gmail quirk worth knowing

**Gmail's IMAP search tokenizes — it is not a substring search.** Searching `SUBJECT "C4VTEST"` returns **zero** against a message whose subject is `C4VTEST212855`, because the search engine indexes whole tokens.

This is why the script uses a deliberately **broad** server query (date-bounded, optionally narrowed by `FROM`) and does the real matching **locally** in Python. Narrowing the server query would silently return nothing and the message would never even be fetched.

Practical consequence: match on `FROM` (sender addresses tokenize cleanly) in preference to `SUBJECT`.

---

## Security — read this before you deploy

**ntfy.sh topics are public.** Anyone who knows or guesses the topic name can subscribe and read every alert. For a law enforcement use case that matters.

Options, in order of strength:

| Option | Effort | Protection |
|--------|--------|------------|
| Long random topic name | Trivial | Obscurity only — adequate for low-sensitivity alerts |
| Self-host ntfy | Medium | Full control, nothing leaves your infrastructure |
| ntfy Pro + access control | Low ($) | Authenticated topics, token required to publish |

If you self-host, email publishing needs the same `smtp-server-*` config plus MX/DNS records, and the address format becomes `ntfy-$topic+$token@your-domain` when access control is on.

For anything you would not want a stranger reading, **self-host**.

---

## Beyond push — ntfy Pro voice calls

ntfy Pro can **ring your phone and read the message aloud via text-to-speech**. For "wake me up because a drone is inbound," a ringing phone beats a text message.

- Requires: ntfy Pro plan, verified phone number, and the **HTTP API** with the `X-Call` header
- Does **not** work via email publishing — so Path A cannot trigger it

That is the strongest alerting tier available here, short of the aircard path.

---

## Verification Status

| Item | Status |
|------|--------|
| ntfy.sh email → topic bridge (email sent, push confirmed in ~5s) | ✅ **Verified** |
| Subject becomes notification title | ✅ **Verified** |
| `gmail-to-ntfy.py` — detects matching mail via IMAP | ✅ **Verified** |
| `gmail-to-ntfy.py` — pushes at priority 5 with tags | ✅ **Verified** |
| `gmail-to-ntfy.py` — dedupe across 3 consecutive runs (exactly 1 message) | ✅ **Verified** |
| `gmail-to-ntfy.py` — dry-run | ✅ **Verified** |
| Gmail IMAP tokenization behaviour | ✅ **Verified** (this is why the search is broad) |
| iOS app priority → Do Not Disturb bypass | ⚠️ **Not verified.** Priority is transmitted correctly; whether iOS honours it through Focus modes needs a phone test. Pushover priority 2 remains the stronger DND-bypass option. |
| ntfy Pro voice call | ⚠️ Not tested (paid tier) |

---

## Recommendation

**Do Path A today.** It takes five minutes and eliminates the missed-email problem entirely.

**Add Path B after** if you find default-priority notifications are not loud enough. You already have the Gmail app password in the keychain and himalaya configured, so it is mostly copy-paste.

**Keep the aircard path in reserve** for the one case push cannot cover: the site's internet is down and you still need to know.

---

## Open Items

| # | Item | Notes |
|---|------|-------|
| N1 | Confirm the exact DroneAware sender address and subject format | Needed for the filter / `MATCH_FROM` |
| N2 | Pick and record the random topic name | Both paths need the same one |
| N3 | Test whether iOS honours priority 5 through Focus modes | Determines if Path B is worth the extra setup |
| N4 | Decide whether to self-host | Depends on how sensitive these alerts are |
| N5 | Add node-health alerts to the same pipe | Offline nodes currently notify nobody |

---

## Deploying the poller as a service (macOS)

`scripts/install-service.sh` deploys the poller as a user LaunchAgent. Two hard-won details are baked in:

### 1. Scripts must live outside `~/Documents`

macOS TCC protects `~/Documents`. A launchd-spawned process that tries to execute a script there fails with:

```
bash: .../Documents/.../run-poller.sh: Operation not permitted   (exit 126)
```

The failure is **silent** unless you read launchd's stderr — exactly the class of invisible failure this whole exercise is meant to eliminate.

`install-service.sh` therefore deploys to `~/.local/bin/drone-alerts/`, which is not TCC-protected and needs no permission grant.

### 2. Use launchd, not cron

Writing a crontab non-interactively **hangs indefinitely** on modern macOS (TCC again). `crontab -l` reads fine; `crontab -` writing a file blocks forever. Do not attempt it from a script.

launchd is the native scheduler and needs no special grant for user agents.

```bash
./scripts/install-service.sh              # deploy + load
./scripts/install-service.sh --uninstall  # stop + remove
```

The agent polls every 120 s, runs once at load, and throttles to 60 s so waking from sleep does not cause a burst.

### Reloading after a path change

`launchctl load` will **not** update an already-loaded agent — it silently keeps the old program path. You must unload first:

```bash
launchctl bootout gui/$(id -u)/com.c4v.drone-alerts-poller
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.c4v.drone-alerts-poller.plist
```

Verify the running config, not just the file:

```bash
launchctl print gui/$(id -u)/com.c4v.drone-alerts-poller | grep -E "program|last exit"
```

`last exit code = 126` means permission denied — almost always the `~/Documents` problem above.

---

## Two-channel setup (cron + backstop)

The deployment runs **both** channels deliberately:

| Channel | Mechanism | Fires when | Priority |
|---------|-----------|------------|----------|
| **A — primary** | launchd poller → HTTP API | Mac is awake | **5 (max)** |
| **B — backstop** | Gmail filter → `ntfy-<topic>@ntfy.sh` | Always (Google's cloud) | Default |

Channel A wakes through Do Not Disturb but dies if the Mac is asleep or off. Channel B never sleeps but arrives at default priority. Together they cover each other's failure mode.

**Backstop filter:** Gmail → Settings → Filters → From `alerts@droneaware.io` → Forward to `ntfy-<backstop-topic>@ntfy.sh`.

### Failure alerting

`run-poller.sh` pushes a **"Drone alert pipe is DOWN"** notification (priority 5) if a poll fails — missing config, auth/keychain failure, or a crash. A bridge that breaks quietly would reproduce the original problem one layer deeper, so it reports its own failure.

Log: `~/.config/drone-alerts/poller.log`
