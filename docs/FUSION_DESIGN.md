# Fusion Design — Cooperative + Behavioral Detection

> **STATUS: WORK IN PROGRESS.** This document captures current thinking and verified findings. Nothing here is implemented yet. Items marked **[VERIFY]** are unconfirmed and must be tested before they are treated as fact.

**Date:** October 2026
**Repo:** `esp32-drone-detector`
**Related:** `SPEC.md` · `TECHNICAL_BRIEF.md` · `Drone_Traffic_Fingerprinting_Deep_Analysis.pdf`

---

## 1. The Question

Existing capability: a DroneAware node detects drones that broadcast Remote ID (ASTM F3411).

Gap: drones that do **not** broadcast Remote ID are invisible to that node.

Open design question: should non-RID detection be built as a **second parallel pipeline**, or should the whole system be rebuilt as **one fusion engine** where RID is simply one input?

**Answer: one fusion engine.** Reasoning in §3.

---

## 2. Verified Findings

### F1 — Remote ID is unauthenticated and trivially spoofable

RID is a broadcast, not an authenticated handshake. The `droneRemoteIDSpoofer` project generates raw 802.11 beacon frames and BLE advertisements carrying valid ASTM F3411 payloads, and those decoys appear as legitimate aircraft on DroneTag RIDER, DJI AeroScope, OpenDroneID apps, and any compliant receiver.

**Consequence:** a RID-only pipeline cannot distinguish a real drone from a spoofer. RID is evidence, not proof.

### F2 — Remote ID has three broadcast transports

| Transport | Notes |
|-----------|-------|
| BLE legacy advertising | 100–300 m range |
| BLE5 long-range / extended advertising | Longer range; needs BT 5.0+ |
| Wi-Fi Beacon | 2.4 GHz ch 6 · 5 GHz ch 149 |
| Wi-Fi NAN (Neighbor Awareness Networking) | No infrastructure needed |

LOCATION is broadcast at least once per second; the other message groups at least once per 3 seconds.

### F3 — There is a large range asymmetry between RID and traffic capture

- **Wi-Fi RID reach:** 1–5 miles depending on antenna
- **BLE RID reach:** 100–300 m
- **Behavioral traffic capture reach:** ~50–150 m (802.11 data frames at usable SNR)

**This is the single most important operational finding.** A RID detection with no accompanying traffic pattern is *overwhelmingly* more likely to mean "the drone is 2 miles away" than "someone is spoofing." Spoofer detection only becomes credible when the RID signal is strong enough to imply local presence.

**Consequence:** the traffic layer's primary near-term value is **proximity validation** — telling you which RID contacts are actually nearby — not spoof detection.

### F4 — The traffic-fingerprint layer works on encrypted traffic

Published work on encrypted drone traffic classification shows high accuracy from side-channel features alone: packet size distribution, inter-arrival timing, and directionality. Reported detection from as few as 170 packets over 820 ms.

### F5 — DJI's Wi-Fi payload has no application-layer encryption

The Christof 2021 thesis established that the DUML payload is plaintext once WPA2 is decrypted — fixed `0x55` delimiters, CRC-16 Kermit trailers, deterministic field offsets. Full telemetry and H.264 video were recovered from passive capture.

**Caveat:** this was established on a Mavic Pro 1 (2021 firmware). Newer chipsets (OcuSync 3.0+, O4) differ, and O4 DroneID is now SM2-wrapped AES-128.

### F6 — FPV drones emit zero 802.11 frames

ELRS / Crossfire / CRSF control links use FHSS on 900 MHz or 2.4 GHz. Video is analog or digital on 5.8 GHz. **No Wi-Fi component exists to fingerprint.** Detection requires SDR or a 5.8 GHz RF energy detector.

### F7 — MAVLink drones announce themselves unambiguously

A drone running MAVLink over Wi-Fi broadcasts a 1 Hz heartbeat (message ID 0) with system ID, component ID, and flight mode — in plaintext UDP. A single packet identifies it with certainty.

### F8 — The existing DroneAware node already has the right radio architecture

From the published build and the node release repo:

| Element | Detail |
|---------|--------|
| Compute | Raspberry Pi 4 (2 GB) |
| Wi-Fi | ALFA AWUS036ACS (RTL8821AU) or Panda PAU0B (MT7610U) — **both in monitor mode** |
| Bluetooth | Sena UD100-G03 (separate dongle) |
| Separate services | `droneaware-wifi-2g`, `droneaware-wifi-5g`, `droneaware-ble`, `droneaware-web` |
| Integration point | `api.py` present in the release repo |
| Build integrity | Binaries Sigstore-attested via GitHub Actions |

**Key consequence:** the node already runs a monitor-mode Wi-Fi adapter. RID beacons are just one frame type among all 802.11 frames that adapter sees. **No new radio is strictly required to add the traffic layer** — the constraint is channel dwell time, not hardware.

### F9 — Channel dwell is the real constraint

The node's Wi-Fi adapter hops channels hunting for RID beacons. Traffic-statistics building requires sustained observation on the drone's channel. Hopping across 13 channels means seeing roughly 1/13 of any given drone's traffic.

Retune cost matters and varies sharply by adapter:

| Adapter | Chipset | Retune | Suitability |
|---------|---------|--------|-------------|
| ALFA AWUS036ACS | RTL8821AU | 22 ms | Good scanner |
| Panda PAU0B | MT7610U | 111 ms | Acceptable |
| ALFA AWUS036ACM | MT7612U | 1007 ms | Fixed channel only |

Community bench result: swapping only the adapter moved RID capture from **51% → 72%**.

### F10 — Skydio broadcasts exclusively on 5 GHz

24 detected airframes across 9 distinct 5 GHz channels, six of which are DFS channels a basic adapter cannot tune. A 2.4 GHz-only receiver never hears a Skydio. This is why the project's own recommendation is dual-band only.

### F11 — The node software is licensed, with a defined collection scope

The feeder software is under the DroneAware Feeder Node Software License, and the Contributor Agreement commits it to a specific data-collection scope (Section 3.1). Sigstore attestation exists so users can confirm a running binary matches published source.

**Design constraint:** extend by **consuming the local API**, not by modifying their feeders. This keeps the node stock, keeps the license clean, and keeps attestation valid.

---

## 3. Why Fusion, Not Two Pipelines

RID and traffic fingerprinting are not two modes of the same thing. They are two *categories of evidence*:

| | Remote ID | Traffic Fingerprint |
|---|---|---|
| Evidence type | **Declarative** — self-reported | **Behavioral** — inferred |
| Time to answer | ~1 packet (instant) | 50–170 packets (~1–3 s) |
| Coverage | Cooperative drones only | Cooperative **and** non-cooperative |
| Spoofable | **Trivially** | Requires emulating a drone RF profile |
| Metadata | Rich: ID, operator location | Rich post-WPA2: telemetry, video |

Two parallel pipelines produce three failures:

1. **Double reporting.** One drone generates two alerts — one per pipeline — with no way to know they are the same aircraft.
2. **No spoof detection.** A disconnected RID pipeline has nothing to compare against.
3. **Inconsistent confidence.** Two scoring scales that cannot be merged after the fact.

A fusion engine avoids all three: correlate by MAC within a sliding window, resolve to a single classification, emit one alert.

---

## 4. The Classification Matrix

![Fusion architecture](../assets/fusion_architecture.png)

| | **Traffic signature present** | **No traffic signature** |
|---|---|---|
| **RID present** | ✅ **Confirmed cooperative drone** — identified, near. Log and track. | ⚠️ **Suspect** — most likely *out of behavioral range* (see F3), or a spoofer. Flag, do not alert. |
| **RID absent** | 🔴 **Non-cooperative drone** — highest priority. RID disabled, pre-RID, homebrew, or FPV-on-Wi-Fi. | 🔕 Ambient. No action. |

**The bottom-left cell is the reason for this project.** It is the drone that does not wish to be seen, and it is precisely what a RID-only system cannot detect.

**The top-right cell is the bonus.** Two disconnected pipelines can never produce it.

### Temperature on the top-right cell

Per F3, expect this cell to be *dominated* by distant cooperative drones rather than spoofers. Credible spoofer indication requires the RID signal to be **strong** (implying local origin) while the traffic layer shows nothing — a spoofer broadcasting from your own location. This refinement is **[VERIFY]** pending field data.

---

## 5. Architecture — Fast Path + Slow Path, One Fusion Layer

```
┌─ FAST PATH (existing) ────┐   ┌─ SLOW PATH (new) ────────┐
│ RID: BLE + Wi-Fi          │   │ Traffic fingerprint      │
│ existing DroneAware node  │   │ monitor-mode capture     │
│ answer in ~1 packet       │   │ 50-170 pkts, ~1-3 s      │
└──────────┬────────────────┘   └──────────┬───────────────┘
           │  local api.py                 │  new analysis
           └────────────┬──────────────────┘
                        ▼
              ┌──────────────────────┐
              │    FUSION ENGINE     │
              │ correlate by MAC     │
              │ sliding window       │
              │ → 2×2 classification │
              │ → single alert path  │
              └──────────────────────┘
```

**Why not serialize them:** RID resolves in one packet. Traffic fingerprinting needs seconds of accumulated statistics. Gating the RID alert behind behavioral scoring would slow down the one detection that is already definitive. Keep RID as the instant fast path; let behavioral confidence accumulate in parallel; correlate in the fusion layer.

### Integration approach

**[VERIFY]** the shape of `api.py` in the node release. The intent is to consume the node's local detection feed as the fast-path input, and run the traffic analyzer as a separate process that publishes into the same fusion state. No modification to DroneAware's own binaries.

---

## 6. Hardware

The radio architecture already exists (F8). Two options for the traffic layer:

| Option | Change | Trade-off |
|--------|--------|-----------|
| **A — Second adapter** | Add a dedicated monitor-mode USB Wi-Fi adapter for traffic analysis | +$25. RID capture untouched. No channel contention. Cleanest. |
| **B — Share the adapter** | Tap the existing monitor stream for traffic stats | No new hardware. But suffers the 1/13 hop penalty (F9), and risks degrading the node's own RID capture — the very metric the community bench moved 51% → 72%. |

**Recommendation: Option A.** The node's RID capture rate is a shared community asset; do not degrade it to save $25.

Option B remains worth testing on the bench and is cheap to evaluate.

---

## 7. Open Questions

| # | Question | How to resolve |
|---|----------|----------------|
| Q1 | What does `api.py` actually expose — real-time detections, history, or web-UI only? | Read the node release source |
| Q2 | Can the RID adapter's stream be tapped without degrading capture rate? | Bench test, compare before/after capture % |
| Q3 | What is the correct correlation window? RID is 1 Hz; behavioral needs 1–3 s. | Propose 5 s, tune against recorded data |
| Q4 | Does a RID detection carry enough data to pin the drone's Wi-Fi channel? | Inspect RID payload fields — channel is not in the standard |
| Q5 | Real field rate of "RID strong + no traffic" — spoofer or something else? | Record RID RSSI alongside traffic layer, look for correlation |
| Q6 | What is the honest false-positive rate of the behavioral layer in RF-dense urban space? | Field trial with known-negative traffic |
| Q7 | Which 5 GHz channels need DFS support to match Skydio coverage (F10)? | Confirm DFS tuning on the chosen adapter |
| Q8 | Does adding a second adapter require any change to the licensed feeder's collection scope (F11)? | Review the Contributor Agreement terms |

---

## 8. Next Steps

1. Read `api.py` from the node release repo — resolve Q1. **Blocking for integration design.**
2. Bench test Option B — resolve Q2. Cheap, informs whether $25 is actually needed.
3. Build the traffic analyzer as a standalone process against recorded pcap — no live integration yet.
4. Record a ground-truth flight set: one RID-on drone, one RID-off drone, one non-drone high-bandwidth device.
5. Calibrate the 2×2 thresholds against that set — resolve Q5, Q6.
6. Only then wire fusion.

---

## 9. Standing Constraints

- **Legal framing unchanged.** The system remains passive receive-only airspace awareness. Nothing in this design transmits, jams, or interferes.
- **Do not modify licensed binaries.** Integrate at the API boundary (F11).
- **Distinguish verified from assumed.** Findings F1–F11 are sourced. Items marked **[VERIFY]** are not.
- **Respect the range asymmetry.** Do not let the fusion matrix imply spoofer detection at distances where the behavioral layer simply cannot see (F3).
