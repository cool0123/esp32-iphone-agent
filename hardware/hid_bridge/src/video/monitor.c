#include "monitor.h"
#include <string.h>

// Every view ends at a whole access unit. A single AU larger than budget stays whole.
static bool gop_window(const gop_buf *g, size_t start, size_t budget, gop_view *v) {
  int first = 0;
  while (first < g->n && g->aus[first].off < start) first++;
  if (first == g->n || g->aus[first].off != start || !g->cfg_len) return false;
  *v = (gop_view){0};
  v->gen = g->gen; v->cfg_len = g->cfg_len;
  memcpy(v->cfg, g->cfg, g->cfg_len);
  for (int i = first; i < g->n; i++) {
    const gop_au *a = &g->aus[i];
    size_t end = (size_t)a->off + a->len;
    if (i > first && end - start > budget) break;
    v->bytes = end; v->captured_ms = a->ts;
  }
  return true;
}

bool monitor_view_open(const gop_buf *g, const video_ring *r, uint32_t epoch, uint32_t captured_ms,
                       uint32_t wanted_epoch, uint64_t offset, bool cursor, size_t budget, video_monitor_view *v) {
  if (!r->cap || !budget || g->used > r->end) return false;
  *v = (video_monitor_view){0};
  v->epoch = epoch;
  v->gop_start = r->end - g->used;
  bool matching = cursor && wanted_epoch == epoch;
  // The GOP retains older bytes than the live ring. Continue a bounded cold replay from there
  // instead of restarting its IDR after each window. P-only bytes require an existing cursor.
  if (matching && offset >= v->gop_start && offset < r->end &&
      gop_window(g, (size_t)(offset - v->gop_start), budget, &v->prefix)) {
    v->start = offset; v->end = v->gop_start + v->prefix.bytes;
    v->captured_ms = v->prefix.captured_ms;
    v->incremental = v->from_gop = true;
    return true;
  }
  // A cursor at the tail, or crossing a GOP rollover, can use the independent ring (<= ring cap).
  if (matching && video_ring_read(r, offset, NULL, 0)) {
    v->start = offset; v->end = r->end;
    v->captured_ms = captured_ms; v->incremental = true;
    return true;
  }
  if (g->wait_idr || !g->n || !g->aus[0].idr || !gop_window(g, 0, budget, &v->prefix)) return false;
  v->start = v->gop_start; v->end = v->gop_start + v->prefix.bytes;
  v->captured_ms = v->prefix.captured_ms; v->from_gop = true;
  return true;
}

bool monitor_view_read(const gop_buf *g, const video_ring *r, uint32_t epoch,
                       const video_monitor_view *v, uint64_t offset, uint8_t *out, size_t len) {
  if (v->epoch != epoch || offset < v->start || offset > v->end || len > v->end - offset) return false;
  return v->from_gop ? gop_view_read(g, &v->prefix, (size_t)(offset - v->gop_start), out, len)
                     : video_ring_read(r, offset, out, len);
}
