// Read-only LAN diagnostics, explicitly enabled with a per-window credential over BLE/USB.
#pragma once
#include <Arduino.h>

using MonitorStatus = String (*)();
bool monitor_enable(bool on, MonitorStatus status, char *out, size_t out_len);
void monitor_poll();
