// HID bridge: an ESP32-S3 (XIAO, 8 MB PSRAM) plugged into the iPhone. It is the phone's
// USB mouse + keyboard, an AirPlay screen-mirroring receiver, and a BLE peripheral for the
// iOS app on the same phone. It holds no logic; the app decides. Protocol: docs/ble-protocol.md.
//
// HID commands (unchanged from the old TCP protocol, the board answers "ok" or "err <why>"):
//   ping | home | move <dx> <dy> | press | release | click
//   scroll <v> <h> | type <ascii text> | key <combo, e.g. cmd+h, enter>
//   homescreen (the consumer-control Home key, "AC Home": iOS goes to the Home Screen, like a keyboard's home key)

#include <esp_task_wdt.h>
#include <esp_mac.h>
#include "USB.h"
#include "USBHIDMouse.h"
#include "USBHIDKeyboard.h"
#include "USBHIDConsumerControl.h"
#include "tusb.h"
#include "ble_link.h"
#include "netcfg.h"
#include "ota_link.h"
#include "monitor_link.h"
#include "video_link.h"
#include "src/airplay/airplay.h"

const int STEP = 10;      // max pointer delta per report while moving
const int STEP_MS = 8;    // report interval; constant pace keeps iOS acceleration predictable
const int HOME_REPORTS = 50;
const long MOVE_LIMIT = 4096;  // worst case ~3.3 s, safely below the 8 s watchdog
#ifndef DEBUG_SERIAL
#define DEBUG_SERIAL 0  // 1: echo commands and the AirPlay handshake over USB serial
#endif

// Explicit runtime marker: ino timestamps can be cached when only a .cpp changes.
static const char *firmwareRevision = "wifi-video-window-v2";
const int WATCHDOG_MS = 8000;  // a hung loop (e.g. blocked USB) reboots the board instead of staying offline
static uint32_t usbBootWaitMs;
static bool usbConfiguredAtBoot;

USBHIDMouse mouse;
USBHIDKeyboard keyboard;
USBHIDConsumerControl consumer;
const uint16_t AC_HOME = 0x0223;  // HID consumer page: AC Home
static String receiverName = "ESP32 Agent";

void movePaced(long dx, long dy) {
  while (dx || dy) {
    int sx = constrain(dx, -STEP, STEP), sy = constrain(dy, -STEP, STEP);
    mouse.move(sx, sy);
    dx -= sx;
    dy -= sy;
    delay(STEP_MS);
  }
}

uint8_t keyCode(const String &k) {
  if (k == "enter") return KEY_RETURN;
  if (k == "esc") return KEY_ESC;
  if (k == "tab") return KEY_TAB;
  if (k == "backspace") return KEY_BACKSPACE;
  if (k == "space") return ' ';
  if (k == "up") return KEY_UP_ARROW;
  if (k == "down") return KEY_DOWN_ARROW;
  if (k == "left") return KEY_LEFT_ARROW;
  if (k == "right") return KEY_RIGHT_ARROW;
  if (k == "cmd") return KEY_LEFT_GUI;
  if (k == "ctrl") return KEY_LEFT_CTRL;
  if (k == "alt") return KEY_LEFT_ALT;
  if (k == "shift") return KEY_LEFT_SHIFT;
  return k.length() == 1 ? k[0] : 0;
}

bool pressCombo(String combo) {
  combo += '+';
  for (int i; (i = combo.indexOf('+')) >= 0; combo = combo.substring(i + 1)) {
    uint8_t c = keyCode(combo.substring(0, i));
    if (!c) { keyboard.releaseAll(); return false; }
    keyboard.press(c);
  }
  delay(30);
  keyboard.releaseAll();
  return true;
}

// A locked or sleeping phone suspends USB; sending HID reports then can stall. Ask it to wake up instead,
// and report "asleep" right away if it does not, so the board never hangs.
bool usbReady() {
  if (tud_suspended()) {
    tud_remote_wakeup();
    for (int i = 0; i < 50 && tud_suspended(); i++) delay(10);
  }
  return tud_mounted() && !tud_suspended();
}

String run(const String &line) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  long a = 0, b = 0;
  int n = sscanf(arg.c_str(), "%ld %ld", &a, &b);

  if (cmd == "ping") return "ok";
  if (!usbReady()) return "err phone usb asleep (unlock the phone)";
  if (cmd == "home") {  // slam the pointer into the top-left corner
    for (int i = 0; i < HOME_REPORTS; i++) { mouse.move(-127, -127); delay(2); }
    return "ok";
  }
  if (cmd == "move") {
    if (n != 2 || a < -MOVE_LIMIT || a > MOVE_LIMIT || b < -MOVE_LIMIT || b > MOVE_LIMIT) return "err move range";
    movePaced(a, b);
    return "ok";
  }
  if (cmd == "press") { mouse.press(MOUSE_LEFT); return "ok"; }
  if (cmd == "release") { mouse.release(MOUSE_LEFT); return "ok"; }
  if (cmd == "click") { mouse.press(MOUSE_LEFT); delay(60); mouse.release(MOUSE_LEFT); return "ok"; }
  if (cmd == "scroll") { mouse.move(0, 0, a, b); return "ok"; }
  if (cmd == "type") { keyboard.print(arg); return "ok"; }
  if (cmd == "key") return pressCombo(arg) ? "ok" : "err unknown key";
  if (cmd == "homescreen") { consumer.press(AC_HOME); delay(40); consumer.release(); return "ok"; }
  return "err unknown command";
}

const char *resetReason() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON: return "power-on";
    case ESP_RST_BROWNOUT: return "brownout";
    case ESP_RST_TASK_WDT: case ESP_RST_INT_WDT: case ESP_RST_WDT: return "watchdog";
    case ESP_RST_PANIC: return "crash";
    case ESP_RST_SW: return "software";
    case ESP_RST_USB: return "usb";
    default: return "other";
  }
}

const char *usbState() {
  if (!tud_mounted()) return "off";
  return tud_suspended() ? "asleep" : "ok";
}

String monitorStatus() { return statusJson(true); }

// Board-level commands from the app; everything else is an HID command for run().
String board(const String &line, const String &id) {
  int sp = line.indexOf(' ');
  String cmd = sp < 0 ? line : line.substring(0, sp);
  String arg = sp < 0 ? "" : line.substring(sp + 1);
  long a = 0, b = 0;
  int n = sscanf(arg.c_str(), "%ld %ld", &a, &b);
  if (cmd == "stream") {
    if (arg != "on" && arg != "off") return "err usage: stream on|off";
    video_stream(arg == "on");
    return "ok";
  }
  if (cmd == "app" || cmd == "log") {  // debug relay: Mac -> app ("app run ...") and app -> Mac ("log ...")
    ble_reply(cmd + " " + arg);         // every peer sees it; each side ignores lines it doesn't handle
    return "ok";
  }
  if (cmd == "snap") { video_snap(id); return ""; }  // replies when the GOP is sent
  if (cmd == "power") {
    if (arg.length() && arg != "status") return "err usage: power [status]";
    return String("ok {\"usb_boot_configured\":") + (usbConfiguredAtBoot ? "true" : "false") +
           ",\"usb_wait_ms\":" + usbBootWaitMs + ",\"ble_tx_dbm\":" + ble_tx_power() + "}";
  }
  if (cmd == "keyframe") {
    if (arg == "status") {
      uint32_t sent, acked, failed;
      airplay_keyframe_stats(&sent, &acked, &failed);
      VideoStats v = video_stats();
      return String("ok {\"enabled\":") + (airplay_event_port() ? "true" : "false") +
             ",\"sent\":" + sent + ",\"acked\":" + acked + ",\"failed\":" + failed +
             ",\"idr_age\":" + v.idr_age + "}";
    }
    if (arg.length()) return "err usage: keyframe [status]";
    if (!airplay_event_port()) return "err experimental keyframes disabled";
    return airplay_request_keyframe() ? "ok queued (new IDR required)" : "err no ready event channel";
  }
  if (cmd == "resync") {  // closes sessions; the owner may need to restart mirroring manually
    airplay_drop_sessions();
    return "ok";
  }
  if (cmd == "bench") {
    if (n < 1 || a <= 0 || a > 4096) return "err usage: bench KB (1-4096)";
    video_bench(id, a);
    return "";
  }
  if (cmd == "res") {
    if (n < 2 || a < 160 || b < 160 || a > 1920 || b > 2560) return "err usage: res W H";
    cfg_set_res(a, b);
    airplay_set_display(a, b, cfg_fps());
    return "ok";
  }
  if (cmd == "fps") {
    if (n < 1 || a < 1 || a > 60) return "err usage: fps N (1-60)";
    cfg_set_fps(a);
    airplay_set_display(cfg_width(), cfg_height(), a);
    return "ok";
  }
  if (cmd == "coex") {  // A/B knob, not stored: every boot starts at balance
    if (arg.length() && !net_coex(arg)) return "err usage: coex bt|balance|wifi";
    return String("ok ") + net_coex_mode();
  }
  if (cmd == "unpair") {
    ble_reply(id + " ok");  // answer before the link goes down
    ble_unpair();
    return "";
  }
  // Read-only LAN diagnostics v3: continuous ring cursor, independent of the BLE GOP cache.
  if (cmd == "monitor") {
    if (arg == "off") { monitor_enable(false, nullptr, nullptr, 0); return "ok off"; }
    if (arg != "on") return "err usage: monitor on|off";
    if (!net_up()) return "err monitor needs a wifi link";
    char credential[49];
    if (!monitor_enable(true, monitorStatus, credential, sizeof credential)) return "err monitor listener failed";
    return String("ok ") + net_ip() + " 3235 " + credential;
  }
  if (cmd == "ota") {  // per-boot window; the password is only ever sent over BLE
    if (arg == "off") {
      ota_enable(false, nullptr, 0);
      return "ok off";
    }
    if (arg.length() && arg != "on") return "err usage: ota on|off";
    if (!net_up()) return "err ota needs a wifi link";
    char pass[24];
    if (!ota_enable(true, pass, sizeof pass)) return "err ota listener failed";
    return String("ok ") + net_ip() + " 3232 " + pass;
  }
  return run(line);
}

String statusJson(bool full) {
  static const char *apStates[] = {"idle", "connected", "streaming"};
  // lcs counts BLE history-overflow transitions admitted by the exact previous-generation AU cursor.
  VideoStats v = video_stats();
  char s[512];
  snprintf(s, sizeof s,
           "{\"bv\":\"%s %s\",\"fw\":\"%s\",\"bo\":%lu,\"up\":%lu,\"rst\":\"%s\",\"heap\":%u,\"psram\":%u,\"usb\":\"%s\",\"net\":\"%s\","
           "\"ip\":\"%s\",\"sta\":%d,"
           "\"ap\":\"%s\",\"w\":%u,\"h\":%u,\"kbps\":%lu,\"fps\":%.1f,\"idr\":%lu,\"idr_age\":%lu,"
           "\"gop\":%lu,\"aus\":%d,\"ov\":%lu,\"lcs\":%lu,\"adrop\":%lu,\"vwait\":%d,\"mdr\":%u,\"mdf\":%u,\"ota\":%d,"
           "\"rssi\":%d,\"ble\":{\"mtu\":%u,\"phy\":%u,\"kbps\":%lu,\"drop\":%lu,\"rdrop\":%lu,\"tx\":%d,\"n\":%d}}",
           __DATE__, __TIME__, firmwareRevision, (unsigned long)net_brownouts(),
           millis(), resetReason(), (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
           (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM), usbState(), net_mode(), net_ip().c_str(), net_peers(),
           apStates[airplay_state()], cfg_width(), cfg_height(), (unsigned long)v.kbps, v.fps, (unsigned long)v.idr_ms,
           (unsigned long)v.idr_age, (unsigned long)v.gop_bytes, v.gop_frames, (unsigned long)v.overflows,
           (unsigned long)v.live_continuations, (unsigned long)v.oversize_drops, v.wait_idr, net_mdns_restarts(), net_mdns_fails(), ota_on() ? 1 : 0,
           net_rssi(),
           ble_mtu(), ble_phy(),
           (unsigned long)ble_kbps(), (unsigned long)ble_drops(), (unsigned long)ble_reply_drops(), ble_tx_power(), ble_peers());
  if (full) return s;
  // MTU below ~250 (before the MTU exchange): keep only the fields the app needs to stay alive
  snprintf(s, sizeof s,
           "{\"up\":%lu,\"rst\":\"%s\",\"usb\":\"%s\",\"net\":\"%s\",\"ap\":\"%s\",\"vwait\":%d,\"ov\":%lu,\"ble\":{\"mtu\":%u}}",
           millis(), resetReason(), usbState(), net_mode(), apStates[airplay_state()], v.wait_idr,
           (unsigned long)v.overflows, ble_mtu());
  return s;
}

void statusTask(void *) {
  for (;;) {
    vTaskDelay(pdMS_TO_TICKS(1000));
    if (!ble_connected()) continue;
    String s = statusJson(true);
    if (s.length() > ble_mtu() - 3u) s = statusJson(false);
    ble_status(s);
  }
}

void logLine(const char *msg) {
#if DEBUG_SERIAL
  Serial.printf("[%lu] %s\n", millis(), msg);
#endif
}

void startAirplay() {
  static airplay_cfg cfg;
  cfg.name = receiverName.c_str();
  esp_read_mac(cfg.hwaddr, ESP_MAC_WIFI_STA);
  cfg_ed25519_seed(cfg.ed25519_seed);
  cfg.width = cfg_width();
  cfg.height = cfg_height();
  cfg.max_fps = cfg_fps();
  cfg.on_config = video_on_config;
  cfg.on_au = video_on_au;
  cfg.log = logLine;
  if (!airplay_start(&cfg)) Serial.println("airplay: start failed");
}

void setup() {
  Serial.begin(115200);
#if DEBUG_SERIAL
  for (int i = 0; i < 30 && !Serial; i++) delay(100);  // give a serial monitor 3 s to catch the boot lines
#endif
  mouse.begin();
  keyboard.begin();
  consumer.begin();
  USB.productName("HID Bridge");
  // The core defaults to SELF_POWERED, so the phone was never asked for the current this board draws and
  // browned it out on every Wi-Fi burst. Declare bus-powered and ask for 500 mA instead.
  USB.usbAttributes(0x80);
  USB.usbPower(500);
  USB.begin();
  // Descriptor power is only requested during enumeration. Let the host configure USB before RF starts.
  // A bounded grace period keeps standalone externally powered diagnostics usable without a USB host.
  uint32_t usbStarted = millis();
  while (!tud_mounted() && millis() - usbStarted < 3000) delay(10);
  usbConfiguredAtBoot = tud_mounted();
  usbBootWaitMs = millis() - usbStarted;
  if (usbConfiguredAtBoot) delay(250);  // let the host supply settle after selecting the configuration
  esp_task_wdt_config_t wdt = {.timeout_ms = WATCHDOG_MS, .idle_core_mask = 0, .trigger_panic = true};
  esp_task_wdt_reconfigure(&wdt);
  esp_task_wdt_add(NULL);

  net_begin();
  if (!video_begin()) Serial.println("video: no PSRAM for the GOP buffer");
  ble_begin("ESP32 Agent " + board_suffix());
  startAirplay();
  ota_begin("iphone-agent");  // listener stays off until a peer runs `ota on`
  xTaskCreatePinnedToCore(statusTask, "status", 4096, NULL, 1, NULL, 1);
  Serial.printf("boot %s: free internal heap %u (largest %u), PSRAM %u, reset %s\n", receiverName.c_str(),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
                (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM), resetReason());
}

void loop() {
  esp_task_wdt_reset();
  net_poll();
  ota_poll();
  monitor_poll();
  if (ble_take_link_drop()) {  // any control peer lost: never leave a gesture held, even with a debug peer up
    mouse.release(MOUSE_LEFT);
    keyboard.releaseAll();
    if (!ble_connected()) video_stream(false);
  }

  String line;
  if (Serial.available()) {  // USB serial takes the same `<id> <command>` lines, for debugging from a Mac
    line = Serial.readStringUntil('\n');
    line.trim();
    if (line.startsWith("0 net ")) { net_request(line.substring(6)); Serial.println("0 ok"); return; }
    int sp = line.indexOf(' ');
    String id = sp < 0 ? line : line.substring(0, sp);
    Serial.println(id + " " + board(sp < 0 ? "" : line.substring(sp + 1), id));
    return;
  }
  if (!ble_pop_cmd(line, 50)) return;
  int sp = line.indexOf(' ');
  String id = sp < 0 ? line : line.substring(0, sp);
  String rest = sp < 0 ? "" : line.substring(sp + 1);
  rest.trim();
#if DEBUG_SERIAL
  unsigned long started = millis();
  // Maintenance windows answer with per-window credentials; never log them.
  bool secret = rest.startsWith("ota on") || rest.startsWith("monitor on") || rest.startsWith("app ops ");
#endif
  String reply = id.toInt() || id == "0" ? board(rest, id) : "err missing request id";
  if (reply.length()) ble_reply(id + " " + reply);
#if DEBUG_SERIAL
  Serial.printf("%s -> %s (%lu ms)\n", secret ? "maintenance (credential redacted)" : line.c_str(), secret ? "ok (credential redacted)" : reply.c_str(),
                millis() - started);
#endif
}
