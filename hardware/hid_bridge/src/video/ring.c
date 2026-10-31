#include "ring.h"
#include <string.h>
void video_ring_init(video_ring *r, uint8_t *arena, size_t cap) { *r = (video_ring){arena, cap, 0}; }
void video_ring_push(video_ring *r, const uint8_t *data, size_t len) {
  if (!r->cap) { r->end += len; return; }
  uint64_t end = r->end + len;
  if (len > r->cap) { data += len - r->cap; len = r->cap; }
  if (len) {
    size_t at = (size_t)((end - len) % r->cap);
    size_t first = r->cap - at < len ? r->cap - at : len;
    memcpy(r->arena + at, data, first);
    memcpy(r->arena, data + first, len - first);
  }
  r->end = end;
}
bool video_ring_read(const video_ring *r, uint64_t offset, uint8_t *out, size_t len) {
  uint64_t first = r->end > r->cap ? r->end - r->cap : 0;
  if (!r->cap || offset < first || offset > r->end || len > r->end - offset) return false;
  if (len) {
    size_t at = (size_t)(offset % r->cap);
    size_t n = r->cap - at < len ? r->cap - at : len;
    memcpy(out, r->arena + at, n);
    memcpy(out + n, r->arena, len - n);
  }
  return true;
}
