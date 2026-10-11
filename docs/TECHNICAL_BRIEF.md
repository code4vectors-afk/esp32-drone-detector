# ESP32 Passive Wi-Fi Drone Detector — Technical Brief

**Classification:** Internal — Engineering Team
**Version:** 1.0
**Date:** October 2026
**Source Paper:** IJRPR Vol 7, Issue 4, pp 5962-5966, Apr 2026
**Repository:** `~/Documents/esp32-drone-detector/`

---

## 1. Executive Summary

This project reverse-engineers and implements an academic paper that uses an **ESP32 microcontroller as a passive Wi-Fi sniffer** to detect consumer drones. The system captures IEEE 802.11 management and data frames in promiscuous mode, fingerprints devices by their MAC OUI prefix, tracks RSSI statistics via Welford's online variance algorithm, and outputs a 0–100% confidence score for each detected device.

**Key design characteristics:**
- **No active RF transmission** — purely passive. Legally unregulated (receive-only).
- **Sub-5 KB RAM** for 50 tracked devices — runs on a $5 ESP32.
- **No history buffers** — Welford's algorithm tracks variance with 3 scalar accumulators.
- **Battery-suitable** — low power, no radio feedback loop.

---

## 2. Tech Stack

| Layer | Component | Notes |
|-------|-----------|-------|
| MCU | ESP32 (Espressif Systems) | Dual-core, 520 KB SRAM, built-in WiFi 802.11 b/g/n |
| Radio | ESP32 WiFi in promiscuous mode | Captures ALL frames regardless of destination MAC |
| Firmware SDK | Arduino ESP32 Core 2.x+ | `esp_wifi.h` API for promiscuous control |
| Language | C++ (Arduino sketch format) | Single `.ino` file, no external deps |
| Output | Serial over USB @ 115200 baud | Parseable, pipe-able to any upstream |
| Power | 5V USB or battery pack | ~200 mA draw in continuous sniff |

**Why ESP32 and not a Raspberry Pi:**
- Cost: $5 vs $50+
- Power: 0.2W vs 5W+
- Instant-on: 1s boot vs 30s
- Deterministic: bare-metal C++ vs Linux scheduling jitter

---

## 3. System Architecture

The firmware is structured as a four-module pipeline. Each module has a single responsibility. The PHY-layer callback is kept minimal — it only captures, identifies, and updates counters. All scoring and output is deferred to the 1 Hz reporting loop.

```
                    ┌──────────────────────────────────────────┐
                    │           2.4 GHz ISM Band                │
                    │  (Wi-Fi channels 1-13, hopping @ 200ms)  │
                    └───────────┬──────────────────────────────┘
                                │
                    ┌───────────▼──────────────────────────────┐
                    │  ① Promiscuous RX Callback               │
                    │  esp_wifi_set_promiscuous_rx_cb()         │
                    │  Fires on EVERY mgmt/data frame          │
                    └───────────┬──────────────────────────────┘
                                │ buf (wifi_promiscuous_pkt_t)
                    ┌───────────▼──────────────────────────────┐
                    │  ② Frame Parser                          │
                    │  Extracts: source MAC, RSSI, frame type  │
                    │  For beacons: parses SSID from IE at     │
                    │  body offset 12-14                       │
                    └───────────┬──────────────────────────────┘
                                │ MAC, SSID, RSSI
                    ┌───────────▼──────────────────────────────┐
                    │  ③ Device Table                          │
                    │  Static DeviceStats[50] array             │
                    │  ~96 bytes/slot = 4.7 KB total           │
                    │  OUI vendor lookup on creation           │
                    │  Welford RSSI accumulator update         │
                    └───────────┬──────────────────────────────┘
                                │ Updated DeviceStats
                    ┌───────────▼──────────────────────────────┐
                    │  ④ Classifier (1 Hz timer)               │
                    │  compute_confidence() for each device     │
                    │  4-factor additive scoring → 0-100%       │
                    │  Serial output + device aging             │
                    └──────────────────────────────────────────┘
```

### 3.1 Module Detail: Promiscuous RX Callback

The callback function `sniffer_callback()` is registered with the ESP32 WiFi stack at boot:

```c
esp_wifi_set_promiscuous_rx_cb(sniffer_callback);
```

**Execution constraints:**
- Called from within the WiFi interrupt context
- Must complete before the next frame arrives (microsecond-level budget)
- No blocking calls, no dynamic allocation, no serial I/O

**Filter chain inside the callback:**
1. Reject non-management and non-data frame types → return
2. Cast buffer to `WifiMgmtHdr` (24-byte 802.11 header)
3. Extract source MAC from `hdr->sa.mac` (6 bytes at fixed offset)
4. Extract RSSI from `pkt->rx_ctrl.rssi`
5. Look up or create device slot → update packet counter + Welford
6. If frame is a beacon (type=0, subtype=8):
   - Read SSID IE at body offset 12 (tag byte), 13 (length), 14+ (value)
   - Copy SSID string to device slot (max 32 bytes)

**Beacon detection — Frame Control byte 0 (wire order, little-endian over memory):**

| Bits | Field | Beacon Value |
|------|-------|-------------|
| 0-1  | Protocol | 00 |
| 2-3  | Type | 00 (management) |
| 4-7  | Subtype | 1000 (beacon) |
| **Byte 0** | **= 0x80** | |

### 3.2 Module Detail: Device Table

Statically allocated array of `DeviceStats` records:

```c
typedef struct {
  uint8_t  mac[6];          // Source MAC
  char     ssid[33];         // Beacon SSID
  char     vendor[20];       // Resolved vendor
  int      vendor_score;     // OUI points
  uint32_t packet_count;     // Frames this window
  int      last_rssi;         // Latest RSSI
  float    rssi_mean;        // Welford: running mean
  float    rssi_m2;          // Welford: squared diff sum
  uint16_t rssi_n;           // Welford: count
  int      confidence;       // 0-100 score
  bool     active;
} DeviceStats;
```

**Slot lifecycle:**
- **CREATED** — on first frame from a new MAC address (table linear scan, O(50))
- **UPDATED** — every frame increments packet_count and updates Welford
- **SCORED** — once per second in the reporting loop
- **EVICTED** — when packet_count is 0 at the end of a reporting window (slot deactivated)

### 3.3 Module Detail: Welford's Online Variance

Reference: Welford, B.P. (1962). *Note on a Method for Calculating Corrected Sums of Squares and Products.* Technometrics 4(3), 419-420.

**Why not a sliding window?**
A conventional sliding RSSI history buffer requires O(n) memory per device slot. With 50 devices × 100 samples = 20 KB just for RSSI history. Welford's algorithm achieves exact sample variance with exactly **three scalar accumulators** — no buffer, no window.

```c
static void welford_update(DeviceStats* d, int rssi) {
  d->rssi_n++;
  float delta  = rssi - d->rssi_mean;
  d->rssi_mean += delta / d->rssi_n;
  float delta2  = rssi - d->rssi_mean;
  d->rssi_m2   += delta * delta2;
}

static float welford_variance(DeviceStats* d) {
  if (d->rssi_n < 2) return 0.0f;
  return d->rssi_m2 / (float)(d->rssi_n - 1);
}
```

**Numerical properties:**
- No catastrophic cancellation for typical RSSI ranges (-30 to -90 dBm)
- Single-pass, exact (not approximate)
- Variance threshold of 5.0 dBm² discriminates hovering drone (±2 dBm) from walking human (±8-15 dBm)

### 3.4 Module Detail: 4-Factor Confidence Scoring

Scoring runs once per second per active device. Each criterion contributes additive points up to a clamped max of 100.

| # | Criterion | Points | Mechanism | Indication |
|---|-----------|--------|-----------|------------|
| 1 | **Vendor OUI** | 40 | MAC prefix lookup in OUI_DB table | Drone manufacturer prefix = strong tell. MAC prefixes are IEEE-assigned and hardware-burned — not trivially spoofed in real-time. |
| 2 | **Packet Rate** | 30 | `packet_count / window_sec > 30` | Active Wi-Fi link (video feed, telemetry) sustains >30 pkts/s. Ambient client traffic is bursty. |
| 3 | **RSSI Stability** | 20 | `welford_variance(d) < 5.0` | Hovering drone has near-constant range → stable RSSI. A walking person changes multipath continuously → high variance. |
| 4 | **SSID Keywords** | 10 | Case-insensitive substring match against `{dji, mavic, drone, fpv, phantom}` | Drone access points advertise telltale SSIDs. |

**Maximum score: 100** (vendor match + high rate + stable RSSI + keyword SSID)

**Confidence interpretation:**

| Score | Meaning | Action |
|-------|---------|--------|
| 80-100 | Almost certainly a drone | Log + alert |
| 50-79 | Likely a drone | Flag for review |
| 10-49 | Possible drone (weak signal) | Track only |
| 0-9 | Ambient Wi-Fi device | Ignore |

### 3.5 Module Detail: Channel Hopping Strategy

```
Channels: 1 through 13 (2.4 GHz ISM band)
Dwell:    200 ms per channel
Sweep:    13 × 200 ms = 2.6 seconds full cycle
```

Each channel hop calls:
```c
esp_wifi_set_channel(channel, WIFI_SECOND_CHAN_NONE);
```

**Design rationale:**
- 200 ms is sufficient to capture ≥2 beacon frames (100 ms beacon interval is standard)
- Full sweep in 2.6s means no device goes undetected for more than ~3 seconds
- Round-robin is deterministic — no timing side channels

**Trade-off:** While tuned to channel N, frames on channel N+1 are invisible. A dual-core variant (Section 8) could dedicate one core to fixed-channel beacon monitoring while the other hops for data frames.

---

## 4. OUI Fingerprint Database

Current mappings (as published in the paper):

| OUI Prefix | Vendor | Score | Known Devices |
|------------|--------|-------|---------------|
| `60:60:1F` | DJI | +40 | Phantom 4, Mini 3 |
| `A4:12:6D` | DJI | +40 | Mavic Air, Mavic Pro |
| `90:3A:E6` | Parrot | +40 | Anafi, Bebop |
| `AC:7B:A1` | Autel | +40 | EVO Lite, EVO Nano |
| `88:3A:DD` | TP-Link | 0 | Control (common AP) |
| `FC:FC:48` | Intel | 0 | Control (laptop NIC) |

**Database architecture:**
- Simple static const array — 6 entries, ~180 bytes
- Lookup is O(6) linear scan (3-byte prefix match)
- Entries are scored per-vendor (drone = +40, non-drone = 0)

**To expand the database**, add a new entry to `OUI_DB[]`:

```c
{{0xXX, 0xXX, 0xXX}, "VendorName", SCORE_VENDOR_OUI},
```

**Priority expansion targets** (discussed in paper Section X):
- ExpressLRS / Crossfire / ELRS FPV bridges (typically `E8:4B:09`, `A8:A4:43` ranges)
- DJI O3 Air Unit (`A4:12:6D` range but newer hardware)
- DJI O4 / DJI Goggles 2
- HolyBro, Matek, SpeedyBee flight controller WiFi
- Ruko / Potensic / Hubsan consumer drones

---

## 5. Output Format

One report emitted per second over serial at 115200 baud:

```
--- ESP32 Drone Detector ---
SSID: DJI-Mini-3Pro | Vendor: DJI | 42 pkt/s | RSSI: -61 dBm | Var: 2.14 | CONF: 90% | MAC: A4:12:6D:xx
SSID: (hidden) | Vendor: TP-Link | 5 pkt/s | RSSI: -72 dBm | Var: 8.31 | CONF: 0% | MAC: 88:3A:DD:xx
No drone signatures detected.
Frames: 1247 | Channel: 7/13 | Slots: 2/50
------------------------------
```

**Machine parsing:** The format is deliberately grep/awk-friendly. To get only 80%+ devices:
```bash
screen /dev/ttyUSB0 115200 | grep "CONF: 9[0-9]%\|CONF: 100%"
```

---

## 6. Resource Budget

| Item | Bytes | % of 520 KB |
|------|-------|-------------|
| DeviceStats × 50 | 4,800 | 0.9% |
| OUI Database | 180 | <0.1% |
| Code (flash) | ~55 KB | n/a |
| Stack + heap | ~8 KB | 1.5% |
| **Total SRAM** | **~13 KB** | **2.5%** |

This leaves enormous headroom for expansion: larger OUI database, dual-core operation, on-device logging, or ML inference.

---

## 7. Deployment

### Bill of Materials
- ESP32 dev board (any: ESP32 DevKit, LOLIN D32, M5Stack Atom)
- Micro-USB cable and 5V power source
- Optional: external 2.4 GHz antenna (ESP32 has internal PIFA, but external RP-SMA improves range)

### Build & Flash
1. Open `esp32-drone-detector.ino` in Arduino IDE
2. Select board: `ESP32 Dev Module` (or your specific variant)
3. Set partition scheme: `No OTA (Large APP)`
4. Upload speed: 921600 (or 115200 if unstable)
5. Flash via USB

### Runtime
1. Open serial monitor at **115200 baud**
2. Observe 1 Hz reports
3. Place ESP32 in area of interest (window, perimeter, field)
4. For persistent logging: pipe serial to file or script

---

## 8. Limitations & Future Work

### Known Limitations

| Limitation | Impact | Mitigation |
|------------|--------|------------|
| **Small OUI database** | Misses newer/non-DJI drones | Expand OUI_DB[] array |
| **No 5 GHz coverage** | Misses drones on 5.8 GHz | Add channel set 36-165 (different dwell) |
| **Single node** | No direction finding or position | Multi-node triangulation |
| **Blind windows** | Misses traffic on non-active channel | Dual-core: one core fixed-channel, one hops |
| **No temporal fusion** | Each 1s window independent | Bayesian filter across windows |
| **First-IE SSID assumption** | SSID IE may not be first | Walk all IEs |

### Expansion Roadmap

**Phase 2 (OUI expansion + 5 GHz)**
- Add 30-50 OUI entries covering FPV, consumer, and tactical drone vendors
- Implement 5 GHz channel set (36-165) with channel-specific dwell times
- Test coverage vs sweep time trade-off

**Phase 3 (Multi-node triangulation)**
- Deploy 3+ ESP32 nodes with known positions
- Use ESP-NOW for inter-node RSSI sync (no WiFi disruption)
- Weighted least-squares position estimate from RSSI path-loss model
- Bearing-only mode with 2 nodes for direction

**Phase 4 (ML classification)**
- Collect RSSI time-series labeled data (drone vs human vs vehicle)
- Train tiny decision tree or 2-layer perceptron (TensorFlow Lite for ESP32)
- Replace heuristic thresholds with learned decision boundary

**Phase 5 (Protocol-level detection)**
- Identify MAVLink telemetry signatures (packet structure, header bytes)
- Detect DJI OSD/comm channel patterns
- Recognize ExpressLRS/CRSF handshake sequences

---

## 9. References

1. Meet Patel et al., *ESP32-Based Passive Wi-Fi Drone Detection with Confidence-Weighted Fingerprinting*, IJRPR Vol 7(4), Apr 2026. https://ijrpr.com/uploads/V7ISSUE4/IJRPR62362.pdf
2. B.P. Welford, *Note on a Method for Calculating Corrected Sums of Squares and Products*, Technometrics 4(3), 419-420, 1962.
3. IEEE 802.11-2020, *IEEE Standard for Information Technology — Local and Metropolitan Area Networks*, IEEE, 2020.
4. Espressif Systems, *ESP32 Technical Reference Manual*, Rev. 5.1.
5. A. Sae-Tang et al., *Passive Wi-Fi Based Drone Detection Using ESP32*, ECTI-CON 2022.

---

## 10. Quick Start

```bash
# 1. Open the sketch
cd ~/Documents/esp32-drone-detector/
code esp32-drone-detector.ino

# 2. Flash to ESP32 via Arduino IDE (Tools → Board: "ESP32 Dev Module")

# 3. Monitor output
screen /dev/ttyUSB0 115200

# Or pipe to a log file
stty -F /dev/ttyUSB0 115200 raw
cat /dev/ttyUSB0 > drone_log_$(date +%Y%m%d_%H%M%S).txt
```