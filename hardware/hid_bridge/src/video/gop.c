// GOP buffer and BLE video chunker, see gop.h.
#include "gop.h"
#include <string.h>

void gop_init(gop_buf *g, uint8_t *arena, size_t cap, gop_au *aus, int max) {
  memset(g, 0, sizeof *g);
  g->arena = arena;
  g->cap = cap;
  g->aus = aus;
  g->max = max;
  g->wait_idr = true;
}

void gop_set_config(gop_buf *g, const uint8_t *annexb, size_t len, uint32_t ts) {
  // Configuration belongs to a new reference chain; never pair it with the old GOP.
  g->previous_n = g->n;
  g->used = 0; g->n = 0; g->gen++;
  g->wait_idr = true; g->stream_only = false;
  if (len > GOP_CFG_MAX) len = 0;  // never seen in practice; treat as missing
  memcpy(g->cfg, annexb, len);
  g->cfg_len = len;
  g->cfg_ts = ts;
}

static void restart(gop_buf *g) {
  g->previous_n = g->n;
  g->used = 0;
  g->n = 0;
  g->gen++;
}

int gop_push(gop_buf *g, const uint8_t *annexb, size_t len, bool idr, uint32_t ts) {
  if (idr) {
    restart(g);
    g->wait_idr = false;
    g->stream_only = false;
  } else if (g->wait_idr && !g->stream_only) {
    return -1;  // before the first IDR there is nothing a live decoder can continue from
  }
  if (g->used + len > g->cap || g->n == g->max) {
    // A fresh decoder needs an IDR, but a running one already has the reference frames. Keep the
    // live stream moving instead of rebooting the board and losing AirPlay; snapshots still wait.
    restart(g);
    g->wait_idr = true;
    g->stream_only = true;
    g->overflows++;
  }
  memcpy(g->arena + g->used, annexb, len);
  g->aus[g->n] = (gop_au){(uint32_t)g->used, (uint32_t)len, ts, idr};
  g->used += len;
  return g->n++;
}

bool gop_recovery_due(gop_recovery *r, uint32_t gen, uint32_t epoch, uint32_t ms, bool needed) {
  if (!needed) return false;
  if (r->gen != gen || r->epoch != epoch) {
    r->gen = gen; r->epoch = epoch; r->attempts = 0;
  }
  if (r->attempts >= 3 || (r->attempts && (uint32_t)(ms - r->at) < 5000)) return false;
  r->attempts++; r->at = ms;
  return true;
}

bool gop_can_continue(const gop_buf *g, uint32_t sent_gen, int sent_n) {
  return g->wait_idr && g->stream_only && sent_gen != UINT32_MAX &&
         g->gen == sent_gen + 1 && sent_n == g->previous_n;
}

bool gop_view_open(const gop_buf *g, gop_view *view) {
  if (g->wait_idr || g->n == 0 || !g->cfg_len || !g->aus[0].idr) return false;
  view->gen = g->gen;
  view->captured_ms = g->aus[g->n - 1].ts;
  view->bytes = g->used;
  view->cfg_len = g->cfg_len;
  memcpy(view->cfg, g->cfg, g->cfg_len);
  return true;
}

bool gop_view_read(const gop_buf *g, const gop_view *view, size_t offset, uint8_t *out, size_t len) {
  if (g->gen != view->gen || view->bytes > g->used || offset > view->bytes || len > view->bytes - offset) return false;
  memcpy(out, g->arena + offset, len);
  return true;
}

bool annexb_has_idr(const uint8_t *p, size_t len) {
  for (size_t i = 0; i + 4 < len; i++)
    if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 && (p[i + 3] & 0x1f) == 5) return true;
  return false;
}

bool avcc_to_annexb(uint8_t *p, size_t len) {
  size_t i = 0;
  while (i + 4 <= len) {
    uint32_t n = (uint32_t)p[i] << 24 | (uint32_t)p[i + 1] << 16 | (uint32_t)p[i + 2] << 8 | p[i + 3];
    if (n > len - i - 4) return false;
    p[i] = p[i + 1] = p[i + 2] = 0;
    p[i + 3] = 1;
    i += 4 + n;
  }
  return i == len;
}

void vchunk_begin(vchunk *c, const uint8_t *data, size_t len, uint8_t flags, uint32_t ts) {
  *c = (vchunk){data, len, 0, ts, (uint8_t)(flags & ~(VF_START | VF_END)), false};
}

size_t vchunk_next(vchunk *c, uint8_t *out, size_t max_payload, uint16_t seq) {
  if (max_payload < 5 || (c->started && c->pos >= c->len)) return 0;
  uint8_t flags = c->flags;
  size_t o = VCHUNK_HDR, room = max_payload;
  if (!c->started) {
    flags |= VF_START;
    for (int i = 0; i < 4; i++) out[o++] = (uint8_t)(c->ts >> (8 * i));
    room -= 4;
    c->started = true;
  }
  size_t n = c->len - c->pos < room ? c->len - c->pos : room;
  memcpy(out + o, c->data + c->pos, n);
  c->pos += n;
  if (c->pos >= c->len) flags |= VF_END;
  out[0] = (uint8_t)seq;
  out[1] = (uint8_t)(seq >> 8);
  out[2] = flags;
  return o + n;
}
