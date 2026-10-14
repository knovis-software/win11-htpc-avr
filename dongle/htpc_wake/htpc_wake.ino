// htpc_wake — M5Stack AtomS3 Lite (ESP32-S3) as a WiFi-listening USB keyboard
// that wakes a Wi-Fi-only Windows HTPC from S3 sleep and types its launch keys.
//
// Triggers (any of):
//   * Wake-on-LAN magic packet addressed to THIS board's MAC, UDP port 9 or 7
//     (HA's wake_on_lan integration; sender does not need ARP for the box).
//   * HTTP  GET/POST http://<ip>/wake            (mode=key|replug|both, default auto)
//   * The AtomS3 button.
// Launch keys (v3.3): GET http://<ip>/launch?action=movie|music&token=<LAUNCH_TOKEN> types F13 (movie)
//   or F14 (music); AutoHotkey on the HTPC (autohotkey/launch-keys.ahk) runs the matching Plex
//   launcher shortcut. A fixed list, never arbitrary keys, and only with the token from wifi_secrets.h
//   (no LAUNCH_TOKEN defined = endpoint disabled). Refused while the bus is suspended: the caller wakes
//   the box first and polls GET / until usb_suspended is false, so a key never lands on a sleeping host.
// Status:  GET http://<ip>/            JSON: usb mounted/suspended, wake count, rssi ...
// OTA:     ArduinoOTA on port 3232, hostname htpc-wake (no password, LAN only).
//
// Wake mechanics:
//   auto  -> bus suspended: TinyUSB remote wakeup, then a manual DWC2 resume-signal
//            fallback, then a Shift tap. Bus not suspended: just the Shift tap.
//   replug-> only on request: USB disconnect/reconnect. Never on a sleeping host in
//            auto - it de-configures the device and kills remote wakeup until re-enumerated.
//   The key is LEFT SHIFT alone: harmless if the box is already awake (idempotent).
//
// Build: arduino-cli, FQBN esp32:esp32:m5stack_atoms3:USBMode=default,CDCOnBoot=cdc
// LED: blue = booting/no wifi, green blink = idle+wifi, white flash = wake fired.

#include <WiFi.h>
#include <WiFiUdp.h>
#include <WebServer.h>
#include <ESPmDNS.h>
#include <ArduinoOTA.h>
#include "USB.h"
#include "USBHIDKeyboard.h"
#include "tusb.h"
#include "esp_mac.h"
#include "soc/soc.h"
#ifndef SOC_DPORT_USB_BASE
#define SOC_DPORT_USB_BASE 0x60080000   // ESP32-S3 USB OTG (DWC2) core; usb_reg.h expects this and the core does not define it
#endif
#include "soc/usb_reg.h"     // DWC2 DCTL for the manual resume-signalling fallback
#include "wifi_secrets.h"   // WIFI_SSID / WIFI_PASS — not committed

extern "C" uint8_t const *tud_descriptor_configuration_cb(uint8_t index);   // Arduino core builds it

#define HOSTNAME   "htpc-wake"
#define PIN_LED    35
#define PIN_BTN    41

USBHIDKeyboard keyboard;
WiFiUDP udp9, udp7;
WebServer http(80);

uint8_t  myMac[6];
uint32_t wakeCount = 0;
String   lastWake = "never";
String   lastTrigger = "";
unsigned long bootMs;

static void led(uint8_t r, uint8_t g, uint8_t b) { neopixelWrite(PIN_LED, r, g, b); }

static String macStr(const uint8_t *m) {
  char s[18]; snprintf(s, sizeof s, "%02X:%02X:%02X:%02X:%02X:%02X", m[0], m[1], m[2], m[3], m[4], m[5]); return s;
}

static void shiftTap() {
  keyboard.press(KEY_LEFT_SHIFT);
  delay(40);
  keyboard.releaseAll();
}

// Wait up to ms for the host to resume (tud_suspended() going false).
static bool waitResume(uint32_t ms) {
  unsigned long t0 = millis();
  while (tud_suspended() && millis() - t0 < ms) delay(20);
  return !tud_suspended();
}

// returns a description of what was done; recorded in /status as last_trigger
static String doWake(const String &mode, const String &why) {
  led(255, 255, 255);
  String did;
  bool suspended = tud_suspended();
  bool mounted   = tud_mounted();
  String m = mode.length() ? mode : "auto";

  if (m == "replug") {
    // ONLY on request. On a sleeping host this de-configures the device and makes
    // remote wakeup impossible until the host re-enumerates it - never use it in auto.
    tud_disconnect(); did += "disconnect;"; delay(1500); tud_connect(); did += "connect;";
    unsigned long t0 = millis();
    while (!tud_mounted() && millis() - t0 < 5000) delay(50);
    did += tud_mounted() ? "mounted;" : "not_mounted;";
    delay(500); shiftTap(); did += "shift;";
  } else if (suspended) {
    // 1. TinyUSB remote wakeup (only signals if the host enabled it: SET_FEATURE REMOTE_WAKEUP)
    bool ok = tud_remote_wakeup();
    did += ok ? "remote_wakeup_ok;" : "remote_wakeup_REFUSED(host_not_enabled);";
    if (waitResume(3000)) did += "resumed;";
    else {
      // 2. Manual resume signalling straight at the DWC2 core, 8 ms of K-state (spec: 1-15 ms)
      REG_CLR_BIT(USB_PCGCCTL_REG, USB_STOPPCLK);
      REG_SET_BIT(USB_DCTL_REG, USB_RMTWKUPSIG); delay(8); REG_CLR_BIT(USB_DCTL_REG, USB_RMTWKUPSIG);
      did += "manual_resume;";
      if (waitResume(3000)) did += "resumed;"; else did += "still_suspended;";
    }
    delay(300); shiftTap(); did += "shift;";
  } else {
    // host is not suspended: awake (or asleep without the S3 noticing). Just tap - harmless.
    shiftTap(); did += "shift;";
  }
  wakeCount++;
  lastWake = String(millis() - bootMs) + "ms_after_boot";
  lastTrigger = why + " mode=" + m + " was_suspended=" + (suspended ? "1" : "0") + " was_mounted=" + (mounted ? "1" : "0") + " did=" + did;
  Serial.println("WAKE " + lastTrigger);
  led(0, 40, 0);
  return lastTrigger;
}

// Launch keys: F13/F14 are HID usages 0x68/0x69 - keys no real keyboard has, so nothing else reacts to them.
static String doLaunch(const String &action, const String &why) {
  uint8_t usage = action == "movie" ? 0x68 : action == "music" ? 0x69 : 0;
  if (!usage) return "bad_action";
  if (!tud_mounted() || tud_suspended()) return "host_not_awake";
  led(60, 30, 0);
  keyboard.pressRaw(usage); delay(40); keyboard.releaseAll();
  lastTrigger = why + " launch=" + action;
  Serial.println("LAUNCH " + lastTrigger);
  led(0, 40, 0);
  return "ok";
}

static bool isMagicForMe(const uint8_t *p, int n) {
  if (n < 102) return false;
  for (int i = 0; i < 6; i++) if (p[i] != 0xFF) return false;
  for (int r = 0; r < 16; r++) if (memcmp(p + 6 + r * 6, myMac, 6) != 0) return false;
  return true;
}

static void pollWol(WiFiUDP &u, const char *port) {
  int n = u.parsePacket();
  if (n <= 0) return;
  static uint8_t buf[256];
  int len = u.read(buf, sizeof buf);
  if (isMagicForMe(buf, len)) doWake("auto", String("wol:") + port + " from " + u.remoteIP().toString());
}

static String statusJson() {
  String s = "{";
  s += "\"host\":\"" HOSTNAME "\",";
  s += "\"ip\":\"" + WiFi.localIP().toString() + "\",";
  s += "\"mac\":\"" + macStr(myMac) + "\",";
  s += "\"rssi\":" + String(WiFi.RSSI()) + ",";
  s += "\"uptime_s\":" + String((millis() - bootMs) / 1000) + ",";
  s += "\"usb_mounted\":" + String(tud_mounted() ? "true" : "false") + ",";
  s += "\"usb_suspended\":" + String(tud_suspended() ? "true" : "false") + ",";
  s += "\"fw\":\"v3.3 2026-10-13\",";
  s += "\"wake_count\":" + String(wakeCount) + ",";
  s += "\"last_wake\":\"" + lastWake + "\",";
  s += "\"last_trigger\":\"" + lastTrigger + "\"";
  s += "}";
  return s;
}

static void connectWifi() {
  led(0, 0, 60);
  WiFi.mode(WIFI_STA);
  WiFi.setHostname(HOSTNAME);
  WiFi.setSleep(false);            // stay responsive to UDP; USB power is not scarce
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - t0 < 30000) delay(200);
}

void setup() {
  bootMs = millis();
  pinMode(PIN_BTN, INPUT_PULLUP);
  led(0, 0, 60);

  // USB first so the host sees a keyboard as early as possible
  USB.usbAttributes(TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP);   // bus-powered, remote wakeup capable
  USB.usbPower(100);
  USB.productName("HTPC wake key");
  USB.manufacturerName("win11-htpc-avr");
  keyboard.begin();
  USB.begin();
  // The core builds the configuration descriptor BEFORE it applies usbAttributes()/usbPower()
  // (esp32-hal-tinyusb.c: tinyusb_load_enabled_interfaces() runs first), so the served
  // descriptor still says self-powered / 500 mA / no remote wakeup - and Windows never arms a
  // device that does not advertise remote wakeup. Patch the bytes in place and re-enumerate.
  {
    uint8_t *cfg = (uint8_t *)tud_descriptor_configuration_cb(0);
    cfg[7] = 0x80 | TUSB_DESC_CONFIG_ATT_REMOTE_WAKEUP;   // bus-powered + remote wakeup
    cfg[8] = 50;                                          // 100 mA
    delay(50);
    tud_disconnect(); delay(300); tud_connect();          // host re-reads the descriptor
  }
  Serial.begin(115200);

  esp_read_mac(myMac, ESP_MAC_WIFI_STA);   // valid before WiFi init; WiFi.macAddress() is not
  connectWifi();

  udp9.begin(9);
  udp7.begin(7);
  MDNS.begin(HOSTNAME);
  MDNS.addService("http", "tcp", 80);

  http.on("/", []() { http.send(200, "application/json", statusJson()); });
  http.on("/status", []() { http.send(200, "application/json", statusJson()); });
  http.on("/desc", []() {   // the config descriptor as actually served to the host (bmAttributes at byte 7)
    uint8_t const *d = tud_descriptor_configuration_cb(0);
    uint16_t len = d[2] | (d[3] << 8);
    String hex; char b[4];
    for (uint16_t i = 0; i < len && i < 128; i++) { snprintf(b, sizeof b, "%02x ", d[i]); hex += b; }
    http.send(200, "text/plain", "len=" + String(len) + " bmAttributes=0x" + String(d[7], HEX) + " bMaxPower=" + String(d[8] * 2) + "mA\n" + hex + "\n");
  });
  http.on("/wake", []() {
    String mode = http.hasArg("mode") ? http.arg("mode") : "auto";
    String r = doWake(mode, "http from " + http.client().remoteIP().toString());
    http.send(200, "application/json", "{\"ok\":true,\"did\":\"" + r + "\"}");
  });
  http.on("/launch", []() {
#ifdef LAUNCH_TOKEN
    if (!http.hasArg("token") || http.arg("token") != LAUNCH_TOKEN) { http.send(403, "application/json", "{\"ok\":false,\"err\":\"token\"}"); return; }
    String r = doLaunch(http.arg("action"), "http from " + http.client().remoteIP().toString());
    http.send(r == "ok" ? 200 : 409, "application/json", "{\"ok\":" + String(r == "ok" ? "true" : "false") + ",\"result\":\"" + r + "\"}");
#else
    http.send(404, "application/json", "{\"ok\":false,\"err\":\"launch disabled: no LAUNCH_TOKEN\"}");
#endif
  });
  http.begin();

  ArduinoOTA.setHostname(HOSTNAME);
  ArduinoOTA.onStart([]() { led(60, 0, 60); });
  ArduinoOTA.begin();

  Serial.println("READY " + statusJson());
}

void loop() {
  static unsigned long lastBlink = 0, lastWifiCheck = 0;
  static bool btnWas = true;

  ArduinoOTA.handle();
  http.handleClient();
  pollWol(udp9, "9");
  pollWol(udp7, "7");

  bool btn = digitalRead(PIN_BTN);
  if (btnWas && !btn) { delay(30); if (!digitalRead(PIN_BTN)) doWake("auto", "button"); }
  btnWas = btn;

  if (millis() - lastWifiCheck > 10000) {
    lastWifiCheck = millis();
    if (WiFi.status() != WL_CONNECTED) { WiFi.disconnect(); connectWifi(); }
  }
  if (millis() - lastBlink > 3000) {
    lastBlink = millis();
    if (WiFi.status() == WL_CONNECTED) { led(0, 40, 0); delay(30); led(0, 4, 0); } else led(0, 0, 60);
  }
  delay(2);
}
