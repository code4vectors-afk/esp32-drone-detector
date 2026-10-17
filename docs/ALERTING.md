# Alerting — Getting Detections to a Phone

> **Status: dispatcher implemented and tested. Channel credentials not yet configured.**
> `scripts/alert.py` is working code — the ntfy delivery path and the rate limiter are verified end-to-end. The Twilio, Pushover, gateway, and email paths are implemented but untested against live credentials.

---

## 1. The Short Answer

**Carrier email-to-SMS gateways are dead or dying. Use a push service for the primary channel and a paid SMS API for the redundant one.**

The old trick — send an email to `phonenumber@carrier.net` and it arrives as a text — has been shut down by most US carriers. Silent failures are the norm: the message is accepted upstream and dropped with no bounce.

---

## 2. Carrier Email-to-SMS Gateway Status

| Carrier | Gateway address | Status |
|---------|----------------|--------|
| **T-Mobile** | `@tmomail.net` | ❌ **Dead** — retired ~Dec 2024, silently dropped |
| **AT&T** | `@txt.att.net` | ❌ **Dead** — shut down ~17 Jun 2025 |
| **Verizon** | `@vtext.com` | ⚠️ **Working but retiring** — shutdown scheduled 31 Mar 2027 |
| **Verizon (MMS)** | `@vzwpix.com` | ⚠️ Working, same retirement date |
| **Google Fi** | `@msg.fi.google.com` | ⚠️ Still documented, unverified here |

**Do not build a detection system on this path.** If you are on T-Mobile or AT&T it simply does not work, and the failure is silent — your alert system will look fine while delivering nothing. Verizon gives you a hard deadline of March 2027.

The dispatcher still supports it (`ALERT_GATEWAY_ADDRESS`) as a last-resort extra channel, and prints a warning every time it is used.

---

## 3. Channel Comparison

| Channel | Cost | Reliability | Ack / Escalation | Needs internet? |
|---------|------|-------------|------------------|-----------------|
| **Aircard (modem)** | Free (uses your plan) | High, if SIM permits SMS | No | **❌ No** — carrier signalling channel |
| **ntfy** | Free | High | No | Yes |
| **Pushover** | $5 one-time | High | ✅ **Priority 2 repeats until acknowledged** | Yes |
| **Twilio SMS** | ~$0.0079/msg US + $1.15/mo number | High | No | Yes (API call) |
| **Carrier gateway** | Free | ❌ Low | No | Yes (email) |
| **Email (himalaya)** | Free | High | No | Yes |

### Why push beats SMS for this use case

An SMS is a *notification*. It arrives, it makes a sound, and that is the end of it. If the phone is face-down, in Do Not Disturb, or the operator is asleep, nothing further happens.

**Pushover priority 2 is different: it bypasses Do Not Disturb and re-alerts every 60 seconds until someone taps Acknowledge.** For a system whose entire purpose is "wake me up because a drone is inbound," that is the difference between an alert and a notification.

Keep SMS as the **redundant path** — it travels a different network than an IP push, so a push-service outage or an internet problem does not silence both.

---

## 3b. The Aircard Path — SMS Without a Third Party

If you have a cellular modem (aircard) with an active SIM and a phone number, you can send SMS **directly**. No Twilio account, no API, no per-message cost.

This may be the **best** option for this project, for one reason:

> **It does not need the internet.**

SMS travels the carrier's *signalling* channel, not the data channel. If the site's internet connection is cut — which is exactly what an adversary does before an incursion — every internet-dependent alert path goes silent at once. An aircard path keeps working as long as there is cell coverage.

For perimeter and critical-infrastructure monitoring, that is the difference between an alert system and a false sense of security. It also means the aircard channel should sit on a **separate power and network path** from the rest of the node.

### What you need

1. A cellular modem that exposes an AT command interface (nearly all do)
2. A SIM with a phone number
3. **A plan that permits SMS** ← this is where most attempts die

### The gotcha: data-only SIMs

Many WWAN / aircard / IoT plans are provisioned **data-only**. The modem works, the SIM registers, data flows normally — and SMS returns `CMS ERROR`. In the worst case the modem reports "sent" while the carrier silently drops it.

You cannot tell from the modem alone. Ask the carrier directly:

> "Does this SIM's provisioning permit **MO-SMS** (mobile-originated SMS)?"

### Linux setup (on the node)

```bash
sudo apt install modemmanager

# Confirm the modem is visible
mmcli -L

# Send a message
MODEM=$(mmcli -L | grep -o 'Modem/[0-9]*' | head -1 | cut -d/ -f2)
mmcli -m "$MODEM" --messaging-create-sms="text='hello',number='+15551234567'"
mmcli -s 0 --send
```

### Run the preflight first

`scripts/modem-preflight.sh` walks every layer — tooling, modem detection, registration, SIM, SMSC, SMS capability — so a failure tells you *which* layer broke rather than just "SMS didn't work":

```bash
./scripts/modem-preflight.sh                      # diagnose only
./scripts/modem-preflight.sh --send +15551111111  # diagnose + live test
```

### Common failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| `No modems were found` | Card stuck in storage/CD-ROM mode | Needs `usb_modeswitch`, or try another USB port |
| No AT response | Modem held by an active data connection | `sudo mmcli -m <idx> --simple-disconnect`, or use the dedicated AT port |
| `CMS ERROR: 500` | SIM plan does not allow SMS | Call the carrier — this is provisioning, not hardware |
| Reports "sent", nothing arrives | Carrier dropped it | Also provisioning |
| No SMSC configured | Service centre number unset | `mmcli -m <idx> --command='AT+CSCA="+1XXXXXXXXXX",145'` |

### Wiring it in

```bash
export ALERT_SMS_TO="+15551111111"
./scripts/alert.py --severity critical \
  --title "Non-cooperative drone" --message "CONF 92%" --channels modem
```

The dispatcher prefers `mmcli` when present and falls back to raw AT commands over a serial port (`ALERT_MODEM_DEVICE`, requires `pyserial`).

### Recommended channel posture

| Role | Channel | Why |
|------|---------|-----|
| Primary | **ntfy** | Free, instant, self-hostable, good UX |
| Escalation | **Pushover** | Only channel that repeats until acknowledged |
| **Out-of-band backup** | **Aircard SMS** | **Survives internet loss** — different network path entirely |
| Audit trail | Email | Searchable record |

Twilio becomes redundant if the aircard works — you already have a number that is not dependent on a third-party API.

---

## 4. Severity Model

Three levels, mapped from the fusion classification (§5). Cooldowns prevent an alert storm from a detector that re-fires every scan cycle.

| Severity | Cooldown | ntfy priority | Pushover priority | SMS |
|----------|----------|---------------|-------------------|-----|
| `info` | 3600 s | 2 (low) | −1 (quiet) | ✗ |
| `alert` | 900 s | 4 (high) | 1 (high) | ✓ |
| `critical` | 120 s | 5 (urgent) | **2 (emergency, repeats)** | ✓ |

**Escalation always breaks the cooldown.** Re-alerting the same key at a *higher* severity bypasses the rate limiter — a contact escalating from suspicious to confirmed must not be swallowed by a 15-minute cooldown. Re-alerting at the same or lower severity is suppressed.

---

## 5. Wiring Alerts to the Fusion Matrix

Severity should be driven by the fusion classification, not by raw confidence. This connects to [`FUSION_DESIGN.md`](FUSION_DESIGN.md) §4:

| Fusion cell | Severity | Rationale |
|-------------|----------|-----------|
| RID present **+** traffic signature | `info` | Confirmed, identified, cooperative. Log it — do not wake anyone. |
| RID present, **no** traffic signature | **none** | Per the range asymmetry finding, this mostly means *distant* (Wi-Fi RID reaches miles, behavioral capture reaches ~150 m). Alerting here produces constant noise. |
| **No** RID **+** traffic signature | `critical` | **The non-cooperative drone.** This is the threat case and the reason the project exists. |
| Neither | none | — |

Plus operational alerts, which are separate from detection:

| Event | Severity |
|-------|----------|
| Node offline / no heartbeat > 300 s | `alert` |
| SDR or adapter failure | `alert` |
| Disk > 90% | `alert` |
| Fusion engine crash / restart | `alert` |

---

## 6. Setup

### ntfy (recommended primary — free)

```bash
# Pick an unguessable topic name. Anyone who knows it can read it
# on the public server, or you can self-host.
export NTFY_TOPIC="drone-alerts-$(openssl rand -hex 6)"
export NTFY_SERVER="https://ntfy.sh"     # or your own instance

# Install the ntfy app on iOS, subscribe to the same topic, done.
```

Self-hosting keeps alerts off a third party's server:

```bash
docker run -p 80:80 -it binwiederhier/ntfy serve
export NTFY_SERVER="http://your-host"
```

### Pushover (recommended for critical escalation — $5)

1. Create an account at pushover.net, note your **User Key**.
2. Register an application, note its **API Token**.
3. Install the iOS app and sign in.

```bash
export PUSHOVER_TOKEN="your-app-token"
export PUSHOVER_USER="your-user-key"
```

### Twilio (real SMS — paid)

1. Create a Twilio account and buy a number (~$1.15/mo).
2. Note the Account SID and Auth Token.
3. Verify your destination number (required on trial accounts).

```bash
export TWILIO_ACCOUNT_SID="ACxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
export TWILIO_AUTH_TOKEN="your-auth-token"
export TWILIO_FROM="+15550000000"      # your Twilio number
export ALERT_SMS_TO="+15551111111"     # your mobile
```

Package is already installed on this machine (`twilio` 9.10.5).

### Email (audit trail)

Uses the existing `himalaya` SMTP configuration.

```bash
export ALERT_EMAIL_TO="you@example.com"
```

---

## 7. Usage

```bash
# Non-cooperative drone — the critical case
./scripts/alert.py --severity critical \
  --title "Non-cooperative drone" \
  --message "CONF 92% | MAC A4:12:6D:xx | ch 6 | -58 dBm | bearing 041"

# Confirmed cooperative — informational only
./scripts/alert.py --severity info \
  --title "Cooperative drone logged" \
  --message "RID: FA3EXAMPLE | DJI Mini 3 | 400ft | operator 0.3mi NE"

# Node health
./scripts/alert.py --severity alert --key "node-PE01-offline" \
  --title "Node PE-01 offline" --message "No heartbeat for 300s"

# Test without sending anything
./scripts/alert.py --dry-run --severity critical --title T --message M

# Test the real delivery path
ALERT_STATE_FILE=/tmp/t.json ./scripts/alert.py --severity critical \
  --title "Self-test" --message "Alert path check" --channels ntfy
```

### Useful flags

| Flag | Purpose |
|------|---------|
| `--key` | Rate-limit bucket. Defaults to the title. Use a stable key per *condition*, not per message, or the cooldown never engages. |
| `--channels` | Restrict to a subset, e.g. `--channels twilio` |
| `--dry-run` | Print what would be sent; no network calls, no state write |
| `--force` | Bypass the rate limiter |

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Delivered (or suppressed by cooldown — not an error) |
| 1 | Every attempted channel failed |
| 2 | No channels configured |

---

## 8. Verification Status

| Component | Status |
|-----------|--------|
| ntfy delivery (HTTP 200 + message read back) | ✅ **Verified** |
| Rate limiter — same severity suppressed | ✅ **Verified** |
| Rate limiter — escalation breaks through | ✅ **Verified** |
| Rate limiter — `--force` bypass | ✅ **Verified** |
| Exit codes and dry-run behaviour | ✅ **Verified** |
| `modem-preflight.sh` — bash syntax, clean failure with no modem present | ✅ **Verified** |
| alert.py — compiles clean, modem channel dry-run | ✅ **Verified** |
| Aircard SMS delivery | ⚠️ **Untested — no modem attached to this machine.** Run `modem-preflight.sh` on the node |
| Twilio SMS delivery | ⚠️ Implemented, untested — no credentials |
| Pushover emergency escalation | ⚠️ Implemented, untested — no credentials |
| Email via himalaya | ⚠️ Implemented, untested |
| Carrier gateway | ⚠️ Implemented; path is largely dead (§2) |

---

## 9. Integration Notes

**From the detection node.** The script is self-contained (stdlib only, plus an optional lazy `twilio` import). Copy it to the node and call it from the detector:

```python
subprocess.run([
    "/opt/drone/alert.py", "--severity", "critical",
    "--key", f"nocoop-{mac}",
    "--title", "Non-cooperative drone",
    "--message", f"CONF {conf}% | MAC {mac} | ch {ch} | {rssi} dBm",
])
```

**From a Hermes session.** Same thing via the terminal tool, or schedule a health check as a cron job and let it fire the script.

**Secrets.** Keep credentials in the environment or a `chmod 600` env file — never in the repo. The state file is written `0600`.

---

## 10. Open Items

| # | Item | Notes |
|---|------|-------|
| A1 | **Does the aircard's SIM permit SMS?** | Run `modem-preflight.sh --send`. This is the highest-leverage unknown. |
| A2 | Decide primary channel: ntfy only, or ntfy + Pushover | Pushover costs $5 but is the only escalating option |
| A3 | Choose topic name and whether to self-host ntfy | Self-hosting suits the on-premises posture |
| A4 | **Confirm aircard is on a separate power/network path** | The whole point is out-of-band. Sharing a switch defeats it. |
| A5 | Provision Twilio number — only if the aircard fails | Redundant if the aircard works |
| A6 | Add node-health checks to the detector | Offline nodes currently alert on nothing |
| A7 | Decide whether SMS needs status-report tracking | `AT+CSMP` can request delivery confirmation; adds complexity |
