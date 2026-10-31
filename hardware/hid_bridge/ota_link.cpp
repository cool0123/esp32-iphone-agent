// OTA updates over Wi-Fi, enabled from the BLE control channel.
//
// Flashing over USB needs the board unplugged from the phone, which breaks a running session. The
// partition table already has two app slots, so a peer can turn the OTA listener on, upload, and the
// board reboots into the new image. The window is per-boot and password-protected: the password is
// generated when OTA is enabled and only ever sent back over BLE, so it is never stored anywhere.
#include "ota_link.h"
#include <ArduinoOTA.h>
#include <WiFi.h>
#include <esp_random.h>
#include <esp_task_wdt.h>

static bool wanted, listening;
static char pass[24];

static void makePass() {
  static const char *abc = "abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  for (int i = 0; i < (int)sizeof pass - 1; i++) pass[i] = abc[esp_random() % strlen(abc)];
  pass[sizeof pass - 1] = 0;
}

void ota_begin(const char *hostname) {
  ArduinoOTA.setHostname(hostname);
  ArduinoOTA.setRebootOnSuccess(true);
  ArduinoOTA.onStart([]() {
    // A flash write plus a full-power TX burst browns out a board powered from the phone's USB port.
    WiFi.setTxPower(WIFI_POWER_5dBm);
    // The loop task sits inside the flash write for longer than the 8 s watchdog allows, and the panic
    // reboot aborted every upload (reset reason "watchdog"). An update ends in a reboot anyway, so take
    // the loop task off the watchdog for the duration and put it back if the upload fails.
    esp_task_wdt_delete(NULL);
    Serial.println("ota: update started");
  });
  ArduinoOTA.onEnd([]() {
    esp_task_wdt_add(NULL);
    Serial.println("ota: update finished");
  });
  ArduinoOTA.onError([](ota_error_t e) {
    esp_task_wdt_add(NULL);
    Serial.printf("ota: error %u\n", (unsigned)e);
  });
}

static void listen(bool on) {
  if (on == listening) return;
  listening = on;
  if (on) {
    ArduinoOTA.setPassword(pass);
    ArduinoOTA.begin();
  } else {
    ArduinoOTA.end();
  }
}

bool ota_enable(bool on, char *out, size_t out_len) {
  wanted = on;
  if (!on) {
    listen(false);
    pass[0] = 0;
    return true;
  }
  makePass();
  snprintf(out, out_len, "%s", pass);
  listen(true);
  return listening;
}

bool ota_on() { return wanted; }

void ota_pause() {
  if (listening) listen(false);
}

void ota_resume() {
  if (wanted) listen(true);
}

// Called from loop(): ArduinoOTA.handle() must run often while a transfer is in flight.
void ota_poll() {
  if (listening) ArduinoOTA.handle();
}
