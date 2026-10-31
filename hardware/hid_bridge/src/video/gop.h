// GOP buffer (every access unit since the latest IDR) and the BLE video chunker.
// Plain C with caller-provided memory so it can be unit-tested on the host.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// video notify flags (docs/ble-protocol.md)
enum { VF_START = 1, VF_END = 2, VF_IDR = 4, VF_CONFIG = 8, VF_BENCH = 16, VF_SNAP = 32 };
#define VCHUNK_HDR 3  // seq u16 LE + flags u8
#define GOP_CFG_MAX 512

typedef struct {
  uint32_t off, len, ts;
  bool idr;
} gop_au;

typedef struct {
  uint8_t *arena;
  size_t cap, used;
  gop_au *aus;
  int n, max;
  uint8_t cfg[GOP_CFG_MAX];  // SPS+PPS, Annex-B
  size_t cfg_len;
  uint32_t cfg_ts;
  bool wait_idr;    // no random-access GOP: snapshots wait for the next IDR
  bool stream_only; // after overflow: keep forwarding P-frames for an already-running decoder
  uint32_t gen;     // bumps whenever the buffer restarts
  uint32_t overflows;
  int previous_n;   // AU count immediately before the most recent generation change
} gop_buf;

void gop_init(gop_buf *g, uint8_t *arena, size_t cap, gop_au *aus, int max);
void gop_set_config(gop_buf *g, const uint8_t *annexb, size_t len, uint32_t ts);
// Appends one Annex-B access unit. Returns its index, or -1 if it was dropped.
int gop_push(gop_buf *g, const uint8_t *annexb, size_t len, bool idr, uint32_t ts);
// A live decoder may cross one history overflow only after sending every AU of that generation.
// Caller holds the GOP lock; a new subscriber or failed send must use UINT32_MAX as sent_gen.
bool gop_can_continue(const gop_buf *g, uint32_t sent_gen, int sent_n);
// At most three recovery attempts per generation/subscriber, five seconds apart.
typedef struct {
  uint32_t gen, epoch, at;
  unsigned attempts;
} gop_recovery;
bool gop_recovery_due(gop_recovery *r, uint32_t gen, uint32_t epoch, uint32_t ms, bool needed);
// True if the Annex-B data contains an IDR slice (NAL type 5).
bool annexb_has_idr(const uint8_t *p, size_t len);
// Rewrites AVCC (4-byte big-endian length prefixes) in place into Annex-B start codes.
// Returns false if the lengths do not tile the buffer exactly.
bool avcc_to_annexb(uint8_t *p, size_t len);

// An immutable prefix of a decodable GOP. Caller holds its GOP lock for each operation;
// network I/O happens between reads, never while holding that lock.
typedef struct {
  uint32_t gen, captured_ms;
  size_t bytes, cfg_len;
  uint8_t cfg[GOP_CFG_MAX];
} gop_view;
bool gop_view_open(const gop_buf *g, gop_view *view);
bool gop_view_read(const gop_buf *g, const gop_view *view, size_t offset, uint8_t *out, size_t len);

// Splits one access unit into notifies: [seq u16 LE][flags][payload], the START chunk
// carrying a u32 LE timestamp before the data.
typedef struct {
  const uint8_t *data;
  size_t len, pos;
  uint32_t ts;
  uint8_t flags;
  bool started;
} vchunk;

void vchunk_begin(vchunk *c, const uint8_t *data, size_t len, uint8_t flags, uint32_t ts);
// Writes the next notify into out (room for VCHUNK_HDR + max_payload bytes); 0 when done.
size_t vchunk_next(vchunk *c, uint8_t *out, size_t max_payload, uint16_t seq);

#ifdef __cplusplus
}
#endif
