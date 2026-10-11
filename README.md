<!-- markdownlint-disable MD033 MD013 -->

<h1 align="center">ESP32 Passive Wi-Fi Drone Detector</h1>

<p align="center">
  <b>A $5 microcontroller that detects drones passively by listening to their Wi-Fi signals.</b><br>
  No radar. No jamming. No transmission. Just listen.
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> •
  <a href="#how-it-works">How It Works</a> •
  <a href="#confidence-scoring">Confidence Model</a> •
  <a href="#deployment">Deployment</a> •
  <a href="#roadmap">Roadmap</a>
</p>

<p align="center">
  <img src="assets/architecture.png" alt="System Architecture" width="90%">
</p>

---

## What This Is

This is a complete implementation of the paper *"ESP32-Based Passive Wi-Fi Drone Detection with Confidence-Weighted Fingerprinting"* (IJRPR Vol 7, Issue 4, Apr 2026). It runs on any ESP32 microcontroller and detects consumer drones by capturing their 802.11 Wi‑Fi management frames in promiscuous mode.

**Three things make this interesting:**
- **$5 hardware.** You can build this for the price of a coffee.
- **Zero legal risk.** Passive receive-only. No jamming, no transmission, no FCC paperwork.
- **~5 KB RAM.** Tracks 50 devices simultaneously with no history buffers — using Welford's online variance algorithm.

---

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/code4vectors-afk/esp32-drone-detector
cd esp32-drone-detector

# 2. Open firmware/esp32-drone-detector.ino in Arduino IDE

# 3. Select board: Tools → Board → ESP32 Dev Module

# 4. Connect ESP32 via USB and click Upload

# 5. Open Serial Monitor at 115200 baud → watch live reports
```

**No external libraries. No cloud services. No calibration.** Just the ESP32 Arduino Core.

---

## Hardware

| Item | Cost | Notes |
|------|------|-------|
| ESP32 dev board | $5–$15 | Any variant with WiFi (ESP32 DevKit, LOLIN D32, M5Stack Atom) |
| USB cable + power | — | Phone charger, power bank, or laptop USB port |
| External antenna (optional) | $5–$10 | RP-SMA 2.4 GHz improves range |

That's the entire BOM.

---

## How It Works

<p align="center">
  <img src="assets/confidence_model.png" alt="Confidence Model" width="85%">
</p>

The system runs a <b>4‑module pipeline</b> on the ESP32 at 1 Hz:

### 1. Listen (Promiscuous RX)
The ESP32 places its Wi‑Fi radio in promiscuous mode — the same mode used for network packet sniffing. It cycles through all 13 Wi‑Fi channels (2.4 GHz) every 2.6 seconds, capturing every 802.11 management and data frame within range.

### 2. Identify (Frame Parser)
Each captured frame is parsed for:
- **Source MAC address** — the device transmitting
- **RSSI** — received signal strength in dBm
- **SSID** — for beacon frames, the network name being broadcast

### 3. Track (Device Table)
A statically allocated array of 50 `DeviceStats` records (~96 bytes each = 4.7 KB total) maintains per-device state using <b>Welford's online algorithm</b> — which computes exact sample variance with three floating-point accumulators instead of a history buffer.

### 4. Score (Classifier)
Once per second, every active device receives a **0–100% confidence score** from four weighted factors.

---

## Confidence Scoring

| Factor | Points | What It Detects |
|--------|--------|------------------|
| **Vendor OUI** | 40 | MAC prefix matches DJI/Parrot/Autel. Not spoofable in real time — these are IEEE-assigned, hardware-burned. |
| **Packet Rate** | 30 | Active Wi‑Fi link sustains &gt;30 pkts/sec. Video transmission or telemetry. |
| **RSSI Stability** | 20 | Variance &lt;5 dBm². A hovering drone produces stable RSSI; a walking person produces wandering RSSI. |
| **SSID Keywords** | 10 | Case‑insensitive match against `dji, mavic, drone, fpv, phantom`. |

**Max score: 100.** Clamped at [0, 100].

| Score | Interpretation |
|-------|----------------|
| 80–100% | ✅ Almost certainly a drone. Alert. |
| 50–79%  | ⚠️ Likely a drone. Flag for review. |
| 10–49%  | 👀 Possible drone. Track only. |
| 0–9%    | 🔕 Ambient Wi‑Fi device. Ignore. |

### Current OUI Database

| OUI Prefix | Vendor | Devices |
|------------|--------|---------|
| `60:60:1F` | DJI | Phantom 4, Mini 3 |
| `A4:12:6D` | DJI | Mavic Air, Mavic Pro |
| `90:3A:E6` | Parrot | Anafi, Bebop |
| `AC:7B:A1` | Autel | EVO Lite, EVO Nano |
| `88:3A:DD` | TP‑Link | Control (false‑positive test) |
| `FC:FC:48` | Intel | Control (false‑positive test) |

---

## Output Format

The system outputs one report per second over USB serial. Every line shows a detected device with all four confidence signals:

```
--- ESP32 Drone Detector ---
SSID: DJI-Mini-3Pro | Vendor: DJI | 42 pkt/s | RSSI: -61 dBm | Var: 2.14 | CONF: 90% | MAC: A4:12:6D:xx
SSID: (hidden) | Vendor: unknown | 3 pkt/s | RSSI: -75 dBm | Var: 12.40 | CONF: 0% | MAC: 88:3A:DD:xx
Frames: 1,247 | Channel: 7/13 | Slots: 2/50
------------------------------
```

Pipe to grep for alerts:
```bash
screen /dev/ttyUSB0 115200 | grep "CONF: 9[0-9]%\|CONF: 100%"
```

---

## Deployment

| Metric | Value |
|--------|-------|
| Hardware cost | $5–$15 |
| Setup time | 15 minutes |
| Power draw | ~0.2 W (runs for days on USB battery) |
| Detection range | 50–150 m line of sight |
| Legal status | ⚖️ Passive receive‑only. No transmission. No licensing. |

### Cost Comparison

| Solution | Per‑Node | Power |
|----------|----------|-------|
| Commercial C‑UAS | $2,000–$50,000+ | 50–500 W |
| **ESP32 Passive Sniffer** | **$5–$15** | **0.2 W** |
| Multi‑node network (10×) | $50–$150 | 2 W |

**Caveat:** This does not replace a full counter‑UAS system. It does not jam, intercept, triangulate, or mitigate. What it does is **detect with high confidence at zero marginal cost** — enabling perimeter awareness where no detection capability currently exists.

---

## Project Structure

```
esp32-drone-detector/
├── firmware/
│   └── esp32-drone-detector.ino    ← The code. Flash this to your ESP32.
├── docs/
│   ├── SPEC.md                     ← Reverse-engineered architecture spec
│   ├── TECHNICAL_BRIEF.md          ← Full team engineering briefing
│   └── ESP32_Drone_Detector_Executive_Summary.pdf ← 3-page exec overview
├── assets/
│   ├── architecture.png            ← System diagram
│   └── confidence_model.png        ← Scoring visual
└── README.md                       ← You are here
```

---

## Roadmap

| Phase | Capability | Priority |
|-------|------------|----------|
| **1 — Current** | Single‑node, 2.4 GHz, 4 drone vendors | ✅ |
| **2 — OUI Expansion** | 50+ fingerprints, 5 GHz channel set | 🔜 Next |
| **3 — Multi‑Node** | 3+ ESP32s triangulating position via ESP‑NOW | 📅 |
| **4 — ML Classification** | TinyML on RSSI time‑series for false‑positive reduction | 📅 |
| **5 — Protocol Detection** | MAVLink / CRSF / ELRS signature recognition | 📅 |

---

## References

- **Original paper:** Meet Patel, Tejas Patil, Jatin Solanki, Hrushikesh Vibhute — *ESP32-Based Passive Wi-Fi Drone Detection with Confidence-Weighted Fingerprinting*. IJRPR Vol 7(4), Apr 2026. [PDF](https://ijrpr.com/uploads/V7ISSUE4/IJRPR62362.pdf)
- **Welford, B.P.** (1962) *Note on a Method for Calculating Corrected Sums of Squares and Products.* Technometrics 4(3), 419‑420.
- **IEEE 802.11‑2020** — IEEE Standard for Information Technology.

---

<p align="center">
  <sub>Reverse‑engineered and implemented by <b>C4C Engineering</b>.</sub><br>
  <sub>Open source. Passive. No transmission. $5 hardware.</sub>
</p>