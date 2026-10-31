// Over-the-air firmware updates, off until a BLE peer turns them on (see ota_link.cpp).
#pragma once
#include <Arduino.h>

// Called once at boot after Wi-Fi is up; advertises nothing until ota_enable(true).
void ota_begin(const char *hostname);
// Turn the OTA listener on/off. A fresh random password is printed into `out` when on.
bool ota_enable(bool on, char *out, size_t out_len);
bool ota_on();
// Drop the listener while the Wi-Fi interface is being rebuilt (same reason mDNS is stopped first).
void ota_pause();
void ota_resume();  // no-op unless the peer asked for OTA
void ota_poll();    // call from loop() while a transfer may be in flight
