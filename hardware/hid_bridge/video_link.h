// Mirrored H.264 from AirPlay to BLE: keeps the current GOP in PSRAM and sends it on `snap`,
// or every access unit while `stream on`. Also runs `bench` and computes the video stats.
#pragma once
#include <Arduino.h>
#include "src/video/gop.h"

// A cold decoder starts from the GOP; a running one follows the independent rolling byte cursor.
struct MonitorView {
  gop_view prefix;
  uint64_t start, end;
  uint32_t epoch, captured_ms;
  bool incremental;
};
bool video_monitor_open(uint32_t epoch, uint64_t offset, bool cursor, MonitorView *view);
bool video_monitor_read(const MonitorView *view, uint64_t offset, uint8_t *out, size_t len);

bool video_begin();
void video_on_config(const uint8_t *sps_pps, size_t len);  // AirPlay callbacks (mirror task)
void video_on_au(const uint8_t *au, size_t len, bool idr);
void video_stream(bool on);
void video_snap(const String &id);               // replies "<id> ok" when the GOP is sent
void video_bench(const String &id, uint32_t kb);  // replies "<id> ok <ms>"

struct VideoStats {
  uint32_t kbps, idr_ms, gop_bytes;
  uint32_t idr_age, overflows, oversize_drops;
  int gop_frames;
  bool wait_idr;
  float fps;
  uint32_t live_continuations;
};
VideoStats video_stats();
