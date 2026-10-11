/**
 * ESP32 Passive Wi-Fi Drone Detector
 * ====================================
 * Reverse-engineered from:
 *   "ESP32-Based Passive Wi-Fi Drone Detection with
 *    Confidence-Weighted Fingerprinting"
 *   IJRPR Vol 7, Issue 4, pp 5962-5966, Apr 2026
 *   https://ijrpr.com/uploads/V7ISSUE4/IJRPR62362.pdf
 *
 * ---
 *  Module Architecture:
 *    1. Promiscuous RX Callback (PHY)
 *    2. Frame Parser (extract MAC/RSSI/SSID)
 *    3. Device Table (static array, 50 slots)
 *    4. Classifier (4-factor confidence, 1 Hz)
 *
 *  Key Algorithms:
 *    - Welford's online variance (O(1) memory)
 *    - OUI prefix fingerprinting (40 pts)
 *    - Packet rate threshold (30 pts)
 *    - RSSI variance stability (20 pts)
 *    - SSID keyword matching (10 pts)
 *    - Channel hopping channels 1-13 @ 200ms dwell
 *
 *  Output: Serial @ 115200 baud, 1 Hz report
 * ---
 *
 *  HARDWARE: ESP32 (any variant with WiFi)
 *  FRAMEWORK: Arduino IDE / ESP32 Arduino Core 2.x+
 *
 *  Connect serial monitor at 115200 baud to see
 *  real-time drone detection reports.
 */

// =====================================================================
// HEADERS
// =====================================================================
#include <WiFi.h>
#include <esp_wifi.h>

// =====================================================================
// CONFIGURATION
// =====================================================================
#define MAX_DEVICES          50
#define CHANNEL_MIN           1
#define CHANNEL_MAX          13
#define DWELL_MS            200
#define REPORT_INTERVAL_MS 1000
#define SERIAL_BAUD       115200

// Confidence weights
#define SCORE_VENDOR_OUI    40
#define SCORE_PKT_RATE      30
#define SCORE_RSSI_VAR      20
#define SCORE_SSID_KW       10

// Thresholds
#define PKT_RATE_THRESH     30.0f   // pkts/sec
#define RSSI_VAR_THRESH      5.0f   // dBm^2
#define CONF_MAX           100
#define SSID_MAX_LEN        32

// =====================================================================
// 802.11 HEADER STRUCTS (packed — no padding between fields)
// =====================================================================
typedef struct __attribute__((packed)) {
  uint8_t mac[6];
} MACAddr;

typedef struct __attribute__((packed)) {
  uint16_t fctl;        // Frame Control      (2 bytes)
  uint16_t duration;    // Duration / ID      (2 bytes)
  MACAddr  da;          // Destination Addr   (6 bytes)
  MACAddr  sa;          // Source Address     (6 bytes)
  MACAddr  bssid;       // BSSID              (6 bytes)
  uint16_t seq_ctrl;    // Sequence Control   (2 bytes)
} WifiMgmtHdr;          // Total: 24 bytes

// =====================================================================
// OUI FINGERPRINT DATABASE
// =====================================================================
typedef struct {
  uint8_t oui[3];       // First 3 MAC octets
  char    vendor[20];   // Vendor name string
  int     score;        // Confidence points
} OUIEntry;

static const OUIEntry OUI_DB[] = {
  // Drone vendors — each worth 40 points
  {{0x60, 0x60, 0x1F}, "DJI",     SCORE_VENDOR_OUI},   // Phantom 4, Mini 3
  {{0xA4, 0x12, 0x6D}, "DJI",     SCORE_VENDOR_OUI},   // Mavic Air/Pro
  {{0x90, 0x3A, 0xE6}, "Parrot",  SCORE_VENDOR_OUI},   // Anafi, Bebop
  {{0xAC, 0x7B, 0xA1}, "Autel",   SCORE_VENDOR_OUI},   // EVO Lite/Nano
  // Controls / false-positive test entries — 0 points
  {{0x88, 0x3A, 0xDD}, "TP-Link", 0},                   // Common AP
  {{0xFC, 0xFC, 0x48}, "Intel",   0},                   // Laptop NIC
};
#define OUI_DB_SZ  (sizeof(OUI_DB) / sizeof(OUI_DB[0]))

// Drone SSID keywords (case-insensitive matching)
static const char* DRONE_KW[] = {"dji", "mavic", "drone", "fpv", "phantom"};
#define DRONE_KW_SZ  (sizeof(DRONE_KW) / sizeof(DRONE_KW[0]))

// =====================================================================
// DEVICE STATE TABLE
// =====================================================================
typedef struct {
  uint8_t  mac[6];          // Source MAC address
  char     ssid[SSID_MAX_LEN + 1]; // Beacon SSID (max 32 chars)
  char     vendor[20];      // Resolved vendor string
  int      vendor_score;    // OUI-derived points (0 or SCORE_VENDOR_OUI)
  uint32_t packet_count;    // Frames in current window
  int      last_rssi;       // Most recent RSSI (dBm)
  float    rssi_mean;       // Welford: running mean
  float    rssi_m2;         // Welford: sum of squared diffs
  uint16_t rssi_n;          // Welford: sample count
  int      confidence;      // Composite 0-100 score
  bool     active;          // Slot in use
} DeviceStats;

// Statically allocated — no malloc, no fragmentation
static DeviceStats devices[MAX_DEVICES];

// =====================================================================
// GLOBALS
// =====================================================================
static int          current_channel = CHANNEL_MIN;
static unsigned long last_report_ms  = 0;
static unsigned long last_hop_ms     = 0;
static uint32_t      total_frames    = 0;

// =====================================================================
// UTILITY — MAC COMPARISON (constant-time okay for 6 bytes)
// =====================================================================
static bool mac_eq(const uint8_t* a, const uint8_t* b) {
  return a[0] == b[0] && a[1] == b[1] && a[2] == b[2]
      && a[3] == b[3] && a[4] == b[4] && a[5] == b[5];
}

// =====================================================================
// UTILITY — OUI PREFIX MATCH (first 3 octets only)
// =====================================================================
static bool oui_match(const uint8_t* mac, const uint8_t* oui) {
  return mac[0] == oui[0] && mac[1] == oui[1] && mac[2] == oui[2];
}

// =====================================================================
// VENDOR OUI LOOKUP
//   Returns score (0 or SCORE_VENDOR_OUI) and sets vendor_name.
//   If no match, vendor_name is cleared.
// =====================================================================
static int lookup_vendor(const uint8_t* mac, char* vendor_out) {
  for (int i = 0; i < OUI_DB_SZ; i++) {
    if (oui_match(mac, OUI_DB[i].oui)) {
      strncpy(vendor_out, OUI_DB[i].vendor, 19);
      vendor_out[19] = '\0';
      return OUI_DB[i].score;
    }
  }
  vendor_out[0] = '\0';
  return 0;
}

// =====================================================================
// SSID KEYWORD CHECK
//   Case-insensitive substring match against DRONE_KW list.
// =====================================================================
static int check_ssid_keywords(const char* ssid) {
  if (!ssid || ssid[0] == '\0') return 0;

  // Fold to lowercase
  char lower[SSID_MAX_LEN + 1];
  int i;
  for (i = 0; i < SSID_MAX_LEN && ssid[i]; i++) {
    char c = ssid[i];
    lower[i] = (c >= 'A' && c <= 'Z') ? (c - 'A' + 'a') : c;
  }
  lower[i] = '\0';

  for (int k = 0; k < DRONE_KW_SZ; k++) {
    if (strstr(lower, DRONE_KW[k]) != NULL) {
      return SCORE_SSID_KW;
    }
  }
  return 0;
}

// =====================================================================
// WELFORD'S ONLINE VARIANCE — O(1) memory, O(1) per sample
//   Exactly as described in paper Section V.
//   Reference: Welford, B.P. (1962). Technometrics 4(3), 419-420.
// =====================================================================
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

// =====================================================================
// DEVICE TABLE — FIND OR CREATE
//   Scans linear array (50 slots). Returns slot index or -1 if full.
//   On creation: copies MAC, runs OUI lookup, zeros accumulators.
// =====================================================================
static int find_or_create_device(const uint8_t* mac) {
  int empty = -1;
  for (int i = 0; i < MAX_DEVICES; i++) {
    if (devices[i].active) {
      if (mac_eq(devices[i].mac, mac)) return i;
    } else if (empty < 0) {
      empty = i;
    }
  }
  if (empty < 0) return -1; // table full — frame dropped

  // Initialize new slot
  DeviceStats* d = &devices[empty];
  memcpy(d->mac, mac, 6);
  d->ssid[0]       = '\0';
  d->vendor[0]     = '\0';
  d->vendor_score  = 0;
  d->packet_count  = 0;
  d->last_rssi     = -100;
  d->rssi_mean     = 0.0f;
  d->rssi_m2       = 0.0f;
  d->rssi_n        = 0;
  d->confidence    = 0;
  d->active        = true;

  // Attempt OUI fingerprint on creation
  d->vendor_score = lookup_vendor(mac, d->vendor);
  return empty;
}

// =====================================================================
// CONFIDENCE SCORE — 4-FACTOR ADDITIVE MODEL
//   Runs once per reporting window per active device.
//   Clamped to [0, CONF_MAX].
// =====================================================================
static int compute_confidence(DeviceStats* d, float window_sec) {
  int score = 0;

  // 1. Vendor OUI fingerprint (+40 if matches DJI/Parrot/Autel)
  score += d->vendor_score;

  // 2. Packet rate (>30 pkts/sec = +30)
  float rate = (window_sec > 0.001f) ? (d->packet_count / window_sec) : 0.0f;
  if (rate > PKT_RATE_THRESH) score += SCORE_PKT_RATE;

  // 3. RSSI stability (variance < 5 dBm^2 = +20; hovering drone)
  if (welford_variance(d) < RSSI_VAR_THRESH) score += SCORE_RSSI_VAR;

  // 4. SSID keyword match (+10)
  score += check_ssid_keywords(d->ssid);

  return (score > CONF_MAX) ? CONF_MAX : score;
}

// =====================================================================
// PROMISCUOUS SNIFFER CALLBACK
//   Called by ESP32 WiFi stack for every captured frame.
//   MUST be fast — blocks the radio receive path.
//   Performs: type filter → device lookup → counter update → Welford → SSID parse
// =====================================================================
static void sniffer_callback(void* buf, wifi_promiscuous_pkt_type_t type) {
  // Only management (beacons, probes) and data frames
  if (type != WIFI_PKT_MGMT && type != WIFI_PKT_DATA) return;

  wifi_promiscuous_pkt_t* pkt = (wifi_promiscuous_pkt_t*)buf;
  WifiMgmtHdr*            hdr = (WifiMgmtHdr*)pkt->payload;
  int                     rssi = pkt->rx_ctrl.rssi;

  total_frames++;

  // Locate or create device slot for this source address
  int idx = find_or_create_device(hdr->sa.mac);
  if (idx < 0) return; // table full

  DeviceStats* d = &devices[idx];
  d->packet_count++;
  d->last_rssi = rssi;
  welford_update(d, rssi);

  // --- Beacon frame check ---
  // Frame Control byte 0 layout (802.11 little-endian):
  //   bits 0-1: Protocol version
  //   bits 2-3: Type         (00 = management)
  //   bits 4-7: Subtype      (1000 = beacon)
  // So management+beacon → byte0 = 0x80
  uint8_t fc_byte0  = hdr->fctl & 0xFF;
  uint8_t fc_type   = (fc_byte0 >> 2) & 0x03;
  uint8_t fc_subtyp = (fc_byte0 >> 4) & 0x0F;

  if (fc_type == 0 && fc_subtyp == 8) {
    // Beacon frame body starts after the 24-byte header
    uint8_t* body = pkt->payload + sizeof(WifiMgmtHdr);
    // Standard IE format: tag byte, length byte, value
    // SSID IE has tag=0x00, typically the first IE at body offset 12
    // (after 8-byte timestamp + 2-byte interval + 2-byte capabilities)
    if (body[12] == 0 && body[13] > 0 && body[13] <= SSID_MAX_LEN) {
      memcpy(d->ssid, &body[14], body[13]);
      d->ssid[body[13]] = '\0';
    }
  }
}

// =====================================================================
// DEVICE AGING & SLOT RECLAMATION
//   Called each reporting cycle. Deactivates slots with zero traffic.
//   Packet counts are then reset for the next window.
// =====================================================================
static void age_devices(void) {
  for (int i = 0; i < MAX_DEVICES; i++) {
    if (!devices[i].active) continue;
    if (devices[i].packet_count == 0) {
      devices[i].active = false;
    }
    // Reset window counters
    devices[i].packet_count = 0;
  }
}

// =====================================================================
// SERIAL REPORT — 1 Hz Dump
//   Format matches paper's Listing 5:
//     SSID: <val> | Vendor: <val> | <N> pkt/s | RSSI: <val> dBm | Var: <val> | CONF: <val>% | MAC: <val>
// =====================================================================
static void print_report(void) {
  Serial.println(F("\n--- ESP32 Drone Detector ---"));
  bool any_active = false;

  for (int i = 0; i < MAX_DEVICES; i++) {
    if (!devices[i].active) continue;
    any_active = true;
    DeviceStats* d = &devices[i];

    // SSID
    Serial.print(F("SSID: "));
    if (d->ssid[0]) {
      Serial.print(d->ssid);
    } else {
      Serial.print(F("(hidden)"));
    }

    // Vendor
    Serial.print(F(" | Vendor: "));
    Serial.print(d->vendor[0] ? d->vendor : F("unknown"));

    // Packet rate
    Serial.print(F(" | "));
    Serial.print(d->packet_count);
    Serial.print(F(" pkt/s"));

    // RSSI
    Serial.print(F(" | RSSI: "));
    Serial.print(d->last_rssi);
    Serial.print(F(" dBm"));

    // Variance
    Serial.print(F(" | Var: "));
    Serial.print(welford_variance(d), 2);

    // Confidence
    Serial.print(F(" | CONF: "));
    Serial.print(d->confidence);
    Serial.print(F("%"));

    // MAC address
    Serial.print(F(" | MAC: "));
    for (int b = 0; b < 6; b++) {
      if (b > 0) Serial.print(':');
      if (d->mac[b] < 0x10) Serial.print('0');
      Serial.print(d->mac[b], HEX);
    }
    Serial.println();
  }

  if (!any_active) {
    Serial.println(F("No drone signatures detected."));
  }

  Serial.print(F("Frames: "));
  Serial.print(total_frames);
  Serial.print(F(" | Channel: "));
  Serial.print(current_channel);
  Serial.print(F("/13 | Slots: "));
  int active_count = 0;
  for (int i = 0; i < MAX_DEVICES; i++) {
    if (devices[i].active) active_count++;
  }
  Serial.print(active_count);
  Serial.print(F("/"));
  Serial.print(MAX_DEVICES);
  Serial.println();
  Serial.println(F("------------------------------"));
}

// =====================================================================
// SETUP
// =====================================================================
void setup() {
  Serial.begin(SERIAL_BAUD);
  delay(200);

  Serial.println(F(""));
  Serial.println(F("ESP32 Drone Detector v1.0"));
  Serial.println(F("Paper: IJRPR Vol 7(4) Apr 2026, pp 5962-5966"));
  Serial.println(F("Mode: Passive Wi-Fi Sniffing (no transmit)"));
  Serial.println(F(""));

  // Clear device table
  for (int i = 0; i < MAX_DEVICES; i++) {
    devices[i].active = false;
  }

  // Initialize WiFi in station mode to access the radio
  WiFi.mode(WIFI_STA);
  WiFi.disconnect();
  delay(100);

  // Enable promiscuous mode and register callback
  esp_wifi_set_promiscuous(true);
  esp_wifi_set_promiscuous_rx_cb(sniffer_callback);

  // Start on channel 1
  current_channel = CHANNEL_MIN;
  esp_wifi_set_channel(current_channel, WIFI_SECOND_CHAN_NONE);

  last_report_ms = millis();
  last_hop_ms    = millis();

  Serial.println(F("Scanning 2.4 GHz channels 1-13..."));
  Serial.println(F("Open serial monitor @ 115200 baud for live reports."));
  Serial.println(F(""));
}

// =====================================================================
// MAIN LOOP
//   Two responsibilities, both timer-driven:
//     1. Channel hopping — switch channel every DWELL_MS
//     2. Report & age — every REPORT_INTERVAL_MS
// =====================================================================
void loop() {
  unsigned long now_ms = millis();

  // --- 1. Channel Hopping ---
  //     Round-robin over channels 1..13, 200 ms dwell each.
  //     Full sweep = 2.6 seconds.
  if (now_ms - last_hop_ms >= DWELL_MS) {
    current_channel = (current_channel % CHANNEL_MAX) + 1;
    esp_wifi_set_channel(current_channel, WIFI_SECOND_CHAN_NONE);
    last_hop_ms = now_ms;
  }

  // --- 2. Reporting Cycle ---
  //     1 Hz: score, report, and age devices.
  if (now_ms - last_report_ms >= REPORT_INTERVAL_MS) {
    float window_sec = (now_ms - last_report_ms) / 1000.0f;

    // Score all active devices
    for (int i = 0; i < MAX_DEVICES; i++) {
      if (!devices[i].active) continue;
      devices[i].confidence = compute_confidence(&devices[i], window_sec);
    }

    // Print and age
    print_report();
    age_devices();

    last_report_ms = now_ms;
  }
}

// =====================================================================
// END OF SKETCH
// =====================================================================