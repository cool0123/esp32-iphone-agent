// Monotonic byte-addressed ring for already-running video decoders.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint8_t *arena; size_t cap; uint64_t end; } video_ring;
void video_ring_init(video_ring *r, uint8_t *arena, size_t cap);
void video_ring_push(video_ring *r, const uint8_t *data, size_t len);
bool video_ring_read(const video_ring *r, uint64_t offset, uint8_t *out, size_t len);
#ifdef __cplusplus
}
#endif
