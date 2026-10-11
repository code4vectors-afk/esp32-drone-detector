# ESP32 Passive Wi-Fi Drone Detector — Reverse-Engineered Spec

**Source:** IJRPR Vol 7, Issue 4, pp 5962–5966, April 2026
**Title:** *ESP32-Based Passive Wi-Fi Drone Detection with Confidence-Weighted Fingerprinting*
**Authors:** Meet Patel, Tejas Patil, Jatin Solanki, Hrushikesh Vibhute — Atharva College of Engg., Mumbai

---

## TL;DR

This paper implements a **passive 802.11 sniffer on an ESP32** that detects consumer drones by analyzing their Wi-Fi emissions. No active transmission — purely listen. It uses four heuristic signals (MAC vendor OUI, packet rate, RSSI stability, SSID keywords) fused into a 0–100% confidence score via an additive weighted model. The Welford online variance algorithm eliminates the need for RSSI history buffers, keeping RAM at ~4.7 KB for 50 tracked devices.

---

## Architecture — 4 Modules

### 1. Promiscuous RX Callback (PHY Layer)
- **Trigger:** Every 802.11 management (WIFI_PKT_MGMT) or data (WIFI_PKT_DATA) frame received
- **Action:** Extract source MAC, RSSI from `wifi_promiscuous_pkt_t.rx_ctrl.rssi`
- **Constraint:** MUST complete fast — promiscuous mode drops frames if callback blocks

### 2. Frame Parser
- **802.11 header** — 24 bytes (Frame Control + Duration + DA + SA + BSSID + Seq Ctrl)
- **Beacon frame detection:** Frame Control byte 0 = 0x80 (subtype 8 = beacon, type 0 = management)
- **SSID extraction** from beacon body: tag at body[12], length at body[13], value at body[14]

### 3. Device Table
- **Static array** — 50 `DeviceStats` records pre-allocated (~96 bytes each = 4.7 KB)
- **Key fields per device:**
  - `mac[6]`, `ssid[33]`, `vendor[20]` — identity
  - `packet_count`, `last_rssi` — raw counters
  - `rssi_mean`, `rssi_m2`, `rssi_n` — Welford accumulators
  - `confidence`, `active` — scoring & lifecycle
- **Slot management:** `find_or_create_device()` — O(1) lookup via linear scan over 50 slots

### 4. Classifier (1 Hz Reporting Loop)
- Runs once per second across all active devices
- Applies four-factor confidence scoring
- Emits serial output at 115200 baud
- Reclaims stale device slots (zero packet count = deactivate)

---

## Confidence Scoring Model

| Criterion | Condition | Points | Rationale |
|-----------|-----------|--------|-----------|
| Vendor OUI | MAC prefix matches DJI/Parrot/Autel | **+40** | Hardware-burned, not spoofable in real-time |
| Packet Rate | >30 pkts/s in last window | **+30** | Active Wi-Fi link sustains traffic |
| RSSI Stability | Variance < 5.0 dBm² | **+20** | Hovering → stable RSSI; handsets wander |
| SSID Keyword | SSID contains dji/mavic/drone/fpv | **+10** | Drone APs advertise identifiable SSIDs |

**Total clamped to [0, 100]**. Maximum achievable score for a confirmed drone = 100.

---

## OUI Fingerprint Database

| OUI Prefix | Vendor | Devices | Score |
|------------|--------|---------|-------|
| 60:60:1F   | DJI    | Phantom 4, Mini 3 | +40 |
| A4:12:6D   | DJI    | Mavic Air/Pro | +40 |
| 90:3A:E6   | Parrot | Anafi, Bebop | +40 |
| AC:7B:A1   | Autel  | EVO Lite/Nano | +40 |
| 88:3A:DD   | TP-Link| AP (control test) | 0 |
| FC:FC:48   | Intel  | Laptop NIC (FP test) | 0 |

**Key insight:** Paper uses these as ground-truth test devices. Real deployment would expand the database significantly — especially for FPV bridges (ExpressLRS, Crossfire, ELRS receivers) and newer DJI O3/O4 link hardware.

---

## Algorithms

### Welford's Online Variance (O(1) memory, O(1) per update)
```
update(d, rssi):
    d.rssi_n++
    delta = rssi - d.rssi_mean
    d.rssi_mean += delta / d.rssi_n
    delta2 = rssi - d.rssi_mean
    d.rssi_m2 += delta * delta2

get_variance(d):
    if d.rssi_n < 2: return 0
    return d.rssi_m2 / (d.rssi_n - 1)
```
No buffers. Exact sample variance. No floating-point cancellation errors.

### Channel Hopping Strategy
```
channels = 1 through 13 (2.4 GHz ISM band)
dwell_time = 200 ms per channel
full_sweep = 2.6 seconds

Channel 1 → 2 → 3 → ... → 13 → 1 → ...
esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE)
delay(200)
```

---

## Data Flow Diagram

```
[Air] → [ESP32 WiFi in Promiscuous Mode]
         → sniffer_callback(buf, type)
           → Frame Parser (extract SA MAC, RSSI, SSID)
             → Device Table (create or update)
               → Welford Variance Update
                 → [1s Timer]
                   → Confidence Scorer
                     → Serial Output @ 115200 baud
```

---

## Output Format (Per Active Device, 1 Hz)
```
SSID: DJI-Mini-3Pro | Vendor: DJI | 42 pkt/s | RSSI: -61 dBm | Var: 2.14 | CONF: 90% | MAC: A4:12:6D:xx
```

---

## Resource Budget

| Item | Memory |
|------|--------|
| DeviceStats (x50) | ~4,800 bytes |
| OUI Database (x6) | ~180 bytes |
| Code + Stack | ~50-80 KB flash, ~10 KB SRAM |
| **Total** | **Well within ESP32's 520 KB SRAM** |

---

## Limitations (from paper + our assessment)

1. **Limited OUI database** — Only 4 drone prefixes across 3 vendors. Missing: newer DJI O3/O4, Holybro/HolyStone, EXI, Ruko, and all FPV/ELRS bridges.
2. **Single-node** — No directionality or position. RSSI triangulation requires ≥2 nodes.
3. **Blind windows** — Channel hopping misses traffic on non-active channels. Could dual-core: core 0 monitors fixed channel for beacons, core 1 hops for data.
4. **No temporal fusion** — Each 1s window is independent. A Bayesian filter across windows would reduce false positives from transient traffic (e.g., video streaming APs).
5. **2.4 GHz only** — No 5 GHz coverage. Modern drones (DJI O3/O4, many FPV) also use 5.8 GHz.

---

## Expansion Vectors

- **Phase 2:** Add 5 GHz channel set (36-165) with wider dwell times
- **Phase 3:** Multi-node triangulation with ESP-NOW sync
- **Phase 4:** ML classifier on RSSI time-series (tinyML on ESP32)
- **Phase 5:** Protocol-level detection (MAVLink telemetry signatures, OSD/comm channel patterns)