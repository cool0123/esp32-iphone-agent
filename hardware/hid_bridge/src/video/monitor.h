// Bounded AU-aligned monitor views. Caller holds the GOP/ring lock; no network I/O here.
#pragma once
#include "gop.h"
#include "ring.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  gop_view prefix;
  uint64_t start, end, gop_start;
  uint32_t epoch, captured_ms;
  bool incremental, from_gop;
} video_monitor_view;
bool monitor_view_open(const gop_buf *g, const video_ring *r, uint32_t epoch, uint32_t captured_ms,
                       uint32_t wanted_epoch, uint64_t offset, bool cursor, size_t budget, video_monitor_view *view);
bool monitor_view_read(const gop_buf *g, const video_ring *r, uint32_t epoch,
                       const video_monitor_view *view, uint64_t offset, uint8_t *out, size_t len);
#ifdef __cplusplus
}
#endif
