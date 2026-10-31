// Host unit tests for the board's pure-C parts: bplist codec and the GOP buffer / video chunker.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../hid_bridge/src/bplist/bplist.h"
#include "../hid_bridge/src/video/gop.h"
#include "../hid_bridge/src/video/ring.h"
#include "../hid_bridge/src/airplay/event_protocol.h"

static int fails;
#define CHECK(c) do { if (!(c)) { fails++; printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); } } while (0)

static void test_bplist_roundtrip(void) {
  bp_writer w;
  bp_writer_init(&w);
  int root = bp_w_dict(&w);
  bp_w_set(&w, root, "features", bp_w_uint(&w, 0x5A7FFEE6ull));
  bp_w_set(&w, root, "big", bp_w_uint(&w, 0x123456789ull));
  bp_w_set(&w, root, "name", bp_w_string(&w, "ESP32 Agent with a long name"));
  bp_w_set(&w, root, "ok", bp_w_bool(&w, true));
  bp_w_set(&w, root, "rate", bp_w_real(&w, 1.0 / 60));
  uint8_t pk[32];
  for (int i = 0; i < 32; i++) pk[i] = (uint8_t)i;
  bp_w_set(&w, root, "pk", bp_w_data(&w, pk, 32));
  int arr = bp_w_array(&w);
  bp_w_set(&w, root, "displays", arr);
  int d0 = bp_w_dict(&w);
  bp_w_append(&w, arr, d0);
  bp_w_set(&w, d0, "width", bp_w_uint(&w, 480));
  size_t len = 0;
  uint8_t *buf = bp_w_finish(&w, &len);
  bp_writer_free(&w);
  CHECK(buf != NULL);

  bp_reader r;
  int top = bp_open(&r, buf, len);
  CHECK(top >= 0 && bp_type(&r, top) == BP_DICT && bp_count(&r, top) == 7);
  uint64_t u = 0;
  CHECK(bp_get_uint(&r, bp_dict_get(&r, top, "features"), &u) && u == 0x5A7FFEE6ull);
  CHECK(bp_get_uint(&r, bp_dict_get(&r, top, "big"), &u) && u == 0x123456789ull);
  char s[64];
  CHECK(bp_get_string(&r, bp_dict_get(&r, top, "name"), s, sizeof s) && !strcmp(s, "ESP32 Agent with a long name"));
  bool b = false;
  CHECK(bp_get_bool(&r, bp_dict_get(&r, top, "ok"), &b) && b);
  double d = 0;
  CHECK(bp_get_real(&r, bp_dict_get(&r, top, "rate"), &d) && d == 1.0 / 60);
  const uint8_t *p;
  size_t n;
  CHECK(bp_get_data(&r, bp_dict_get(&r, top, "pk"), &p, &n) && n == 32 && !memcmp(p, pk, 32));
  int a = bp_dict_get(&r, top, "displays");
  CHECK(bp_type(&r, a) == BP_ARRAY && bp_count(&r, a) == 1);
  CHECK(bp_get_uint(&r, bp_dict_get(&r, bp_array_get(&r, a, 0), "width"), &u) && u == 480);
  CHECK(bp_dict_get(&r, top, "missing") < 0);
  CHECK(bp_array_get(&r, a, 5) < 0);

  // truncation and garbage never crash
  for (size_t cut = 0; cut < len; cut++) {
    bp_reader t;
    int tt = bp_open(&t, buf, cut);
    if (tt >= 0) bp_dict_get(&t, tt, "pk");
  }
  uint8_t junk[200];
  memcpy(junk, buf, len < 200 ? len : 200);
  for (int i = 8; i < 200 && (size_t)i < len - 32; i += 3) junk[i] ^= 0xA5;
  bp_reader t;
  int tt = bp_open(&t, junk, len < 200 ? len : 200);
  if (tt >= 0) { bp_dict_get(&t, tt, "pk"); bp_count(&t, tt); }
  free(buf);
}

// Hand-made plist as Apple writes it: UTF-16 string value and 1-byte refs.
static void test_bplist_utf16(void) {
  static const uint8_t pl[] = {
    'b','p','l','i','s','t','0','0',
    0xD1, 0x01, 0x02,                // dict {1: 2}         @8
    0x54, 'n','a','m','e',           // "name"              @11
    0x63, 0x00,'H', 0x20,0x19, 0x00,'s',  // u"H’s"        @16
    8, 11, 16,                       // offsets            @23
    0,0,0,0,0,0, 1, 1,
    0,0,0,0,0,0,0,3, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,23};
  bp_reader r;
  int top = bp_open(&r, pl, sizeof pl);
  char s[32];
  CHECK(top == 0);
  CHECK(bp_get_string(&r, bp_dict_get(&r, top, "name"), s, sizeof s) && !strcmp(s, "H\xE2\x80\x99s"));
}

// Extended lengths and trailer offsets must not wrap the bounds checks.
static void oversized_object(uint8_t marker, uint8_t b[51]) {
  memset(b, 0, 51);
  memcpy(b, "bplist00", 8);
  b[8] = marker;
  b[9] = 0x13;  // 8-byte length
  memset(b + 10, 0xff, 8);
  b[18] = 8;
  b[25] = b[26] = 1;
  b[34] = 1;
  b[50] = 18;
}

static void test_bplist_overflow(void) {
  uint8_t b[51];
  oversized_object(0xdf, b);
  bp_reader r;
  int top = bp_open(&r, b, sizeof b);
  CHECK(top == 0 && bp_count(&r, top) == 0 && bp_dict_get(&r, top, "x") < 0);
  oversized_object(0xaf, b);
  top = bp_open(&r, b, sizeof b);
  CHECK(top == 0 && bp_count(&r, top) == 0 && bp_array_get(&r, top, 0) < 0);
  oversized_object(0x4f, b);
  top = bp_open(&r, b, sizeof b);
  const uint8_t *data;
  size_t len;
  CHECK(top == 0 && !bp_get_data(&r, top, &data, &len));
  char s[8];
  oversized_object(0x5f, b);
  top = bp_open(&r, b, sizeof b);
  CHECK(top == 0 && !bp_get_string(&r, top, s, sizeof s));
  oversized_object(0x6f, b);
  top = bp_open(&r, b, sizeof b);
  CHECK(top == 0 && !bp_get_string(&r, top, s, sizeof s));
  oversized_object(0xdf, b);
  memset(b + 43, 0xff, 8);  // offset table near UINT64_MAX
  CHECK(bp_open(&r, b, sizeof b) < 0);
}

static void test_video_ring(void) {
  uint8_t arena[8], out[16];
  video_ring r;
  video_ring_init(&r, arena, sizeof arena);
  CHECK(video_ring_read(&r, 0, out, 0));
  CHECK(!video_ring_read(&r, 0, out, 1));
  video_ring_push(&r, (const uint8_t *)"abcdefgh", 8);
  CHECK(video_ring_read(&r, 0, out, 8) && !memcmp(out, "abcdefgh", 8));
  video_ring_push(&r, (const uint8_t *)"ijk", 3);
  CHECK(!video_ring_read(&r, 0, out, 1));
  CHECK(video_ring_read(&r, 3, out, 8) && !memcmp(out, "defghijk", 8));
  CHECK(video_ring_read(&r, 8, out, 3) && !memcmp(out, "ijk", 3));
  CHECK(!video_ring_read(&r, 12, out, 0));
  CHECK(!video_ring_read(&r, UINT64_MAX, out, 1));
  video_ring_push(&r, (const uint8_t *)"0123456789abcdef", 16);
  CHECK(r.end == 27);
  CHECK(video_ring_read(&r, 19, out, 8) && !memcmp(out, "89abcdef", 8));
  CHECK(!video_ring_read(&r, 18, out, 1));
  // Cursor byte positions continue across 32-bit and backing-buffer boundaries.
  r.end = UINT32_MAX - 2ull;
  video_ring_push(&r, (const uint8_t *)"ABCDEFGH", 8);
  CHECK(r.end == UINT32_MAX + 6ull);
  CHECK(video_ring_read(&r, UINT32_MAX - 2ull, out, 8) && !memcmp(out, "ABCDEFGH", 8));
}

static void test_gop_view(void) {
  uint8_t arena[100], out[100], cfg[] = {0, 0, 0, 1, 0x67};
  gop_au aus[8];
  gop_buf g;
  gop_view v;
  uint8_t au[40] = {0, 0, 0, 1, 0x65};
  gop_init(&g, arena, sizeof arena, aus, 8);
  CHECK(!gop_view_open(&g, &v));
  gop_set_config(&g, cfg, sizeof cfg, 10);
  CHECK(!gop_view_open(&g, &v));
  gop_push(&g, au, 20, true, 11);
  gop_push(&g, au, 20, false, 12);
  CHECK(gop_view_open(&g, &v));
  CHECK(v.captured_ms == 12 && v.bytes == 40 && v.cfg_len == sizeof cfg);
  CHECK(!memcmp(v.cfg, cfg, sizeof cfg));
  // Appending does not move the captured prefix or silently include newer bytes.
  gop_push(&g, au, 20, false, 13);
  CHECK(gop_view_read(&g, &v, 0, out, 40));
  CHECK(!memcmp(out, au, 20) && !memcmp(out + 20, au, 20));
  CHECK(!gop_view_read(&g, &v, 40, out, 1));
  CHECK(!gop_view_read(&g, &v, SIZE_MAX, out, 1));
  CHECK(!gop_view_read(&g, &v, 1, out, SIZE_MAX));
  // A new IDR or overflow invalidates an in-flight HTTP download.
  gop_push(&g, au, 20, true, 14);
  CHECK(!gop_view_read(&g, &v, 0, out, 20));
  CHECK(gop_view_open(&g, &v));
  gop_push(&g, au, 40, false, 15);
  gop_push(&g, au, 40, false, 16);
  gop_push(&g, au, 1, false, 17);
  CHECK(!gop_view_read(&g, &v, 0, out, 1));
  CHECK(!gop_view_open(&g, &v));
}

static void test_gop(void) {
  static uint8_t arena[100];
  static gop_au aus[4];
  gop_buf g;
  gop_init(&g, arena, sizeof arena, aus, 4);
  uint8_t au[40] = {0, 0, 0, 1, 0x41};
  CHECK(gop_push(&g, au, 10, false, 1) == -1);  // waits for the first IDR
  CHECK(gop_push(&g, au, 30, true, 2) == 0);
  CHECK(gop_push(&g, au, 30, false, 3) == 1);
  CHECK(gop_push(&g, au, 30, false, 4) == 2 && g.used == 90);
  CHECK(gop_push(&g, au, 30, false, 5) == 0 && g.n == 1 && g.used == 30);
  CHECK(g.wait_idr && g.stream_only && g.overflows == 1);  // live P-frames continue, snapshots wait
  CHECK(gop_push(&g, au, 10, false, 6) == 1);
  CHECK(gop_push(&g, au, 10, true, 7) == 0 && !g.wait_idr && !g.stream_only);

  uint8_t idr[] = {0, 0, 0, 1, 0x67, 1, 0, 0, 0, 1, 0x65, 9};
  CHECK(annexb_has_idr(idr, sizeof idr));
  CHECK(!annexb_has_idr(idr, 6));

  uint8_t avcc[] = {0, 0, 0, 2, 0x65, 1, 0, 0, 0, 1, 0x41};
  uint8_t want[] = {0, 0, 0, 1, 0x65, 1, 0, 0, 0, 1, 0x41};
  CHECK(avcc_to_annexb(avcc, sizeof avcc) && !memcmp(avcc, want, sizeof want));
  uint8_t bad[] = {0, 0, 0, 9, 0x65};
  CHECK(!avcc_to_annexb(bad, sizeof bad));
}

static void test_gop_continuation(void) {
  uint8_t arena[100], au[40] = {0, 0, 0, 1, 0x41}, cfg[] = {0, 0, 0, 1, 0x67};
  gop_au aus[8];
  gop_buf g;
  gop_view view;
  gop_init(&g, arena, sizeof arena, aus, 8);
  gop_set_config(&g, cfg, sizeof cfg, 0);
  CHECK(!gop_can_continue(&g, UINT32_MAX, 0));
  gop_push(&g, au, 30, true, 1);
  gop_push(&g, au, 30, false, 2);
  uint32_t gen = g.gen;
  int caught_up = g.n;
  CHECK(!gop_can_continue(&g, gen, caught_up));
  // The sender caught up once, but a tail AU arrives before the overflow. That tail cannot be lost.
  gop_push(&g, au, 30, false, 3);
  gop_push(&g, au, 30, false, 4);
  CHECK(g.previous_n == 3 && g.n == 1);
  CHECK(!gop_can_continue(&g, gen, caught_up));
  CHECK(!gop_can_continue(&g, UINT32_MAX, 3));  // new subscription / failed chunk
  CHECK(gop_can_continue(&g, gen, 3));        // includes a final AU copied before the overflow
  CHECK(!gop_view_open(&g, &view));           // P-only history is never a snapshot
  uint32_t first_overflow_gen = g.gen;
  gop_push(&g, au, 30, false, 5);
  gop_push(&g, au, 30, false, 6);
  gop_push(&g, au, 30, false, 7);
  CHECK(!gop_can_continue(&g, gen, 3));       // missed a whole generation, despite equal AU counts
  CHECK(gop_can_continue(&g, first_overflow_gen, 3));
  gop_push(&g, au, 30, true, 8);
  CHECK(!gop_can_continue(&g, g.gen - 1, g.previous_n));  // a new IDR starts with CONFIG
  CHECK(gop_view_open(&g, &view));

  // Metadata exhaustion is an overflow even when the byte arena still has room.
  gop_init(&g, arena, sizeof arena, aus, 2);
  gop_push(&g, au, 5, true, 9);
  gen = g.gen;
  gop_push(&g, au, 5, false, 10);
  gop_push(&g, au, 5, false, 11);
  CHECK(g.used == 5 && g.previous_n == 2 && gop_can_continue(&g, gen, 2));
  CHECK(!gop_can_continue(&g, gen, 1));
}

static void test_chunker(void) {
  uint8_t data[100], out[64], got[100];
  for (int i = 0; i < 100; i++) data[i] = (uint8_t)i;
  vchunk c;
  vchunk_begin(&c, data, sizeof data, VF_IDR | VF_SNAP, 0xAABBCCDD);
  size_t n, got_len = 0;
  int chunks = 0;
  uint16_t seq = 65534;
  while ((n = vchunk_next(&c, out, 20, seq)) > 0) {
    CHECK(n <= VCHUNK_HDR + 20);
    CHECK(out[0] == (uint8_t)seq && out[1] == (uint8_t)(seq >> 8));
    CHECK(out[2] & VF_IDR && out[2] & VF_SNAP);
    size_t off = VCHUNK_HDR;
    if (chunks == 0) {
      CHECK(out[2] & VF_START);
      CHECK(out[3] == 0xDD && out[6] == 0xAA);
      off += 4;
    } else {
      CHECK(!(out[2] & VF_START));
    }
    memcpy(got + got_len, out + off, n - off);
    got_len += n - off;
    chunks++;
    seq++;
    if (got_len < 100) CHECK(!(out[2] & VF_END));
  }
  CHECK(out[2] & VF_END);
  CHECK(got_len == 100 && !memcmp(got, data, 100));
  CHECK(chunks == 6);  // 16 + 5 * 20 >= 100
  CHECK(seq == 4);     // wrapped

  vchunk_begin(&c, data, 3, VF_CONFIG, 1);  // tiny AU: one chunk is START and END
  n = vchunk_next(&c, out, 20, 0);
  CHECK(n == VCHUNK_HDR + 4 + 3 && (out[2] & (VF_START | VF_END | VF_CONFIG)) == (VF_START | VF_END | VF_CONFIG));
  CHECK(vchunk_next(&c, out, 20, 1) == 0);
}

static void test_event_reply(void) {
  const char *ok = "HTTP/1.1 200 OK\r\nCSeq: 7\r\nContent-Length: 4\r\n\r\n";
  char reply[1025];
  size_t head = strlen(ok);
  memcpy(reply, ok, head);
  memcpy(reply + head, "\0\1\2\3", 4);  // binary plist replies can contain NUL
  for (size_t n = 0; n < head + 4; n++) CHECK(ap_event_reply(reply, n, 7) == 0);
  CHECK(ap_event_reply(reply, head + 4, 7) == (int)head + 4);
  CHECK(ap_event_reply(reply, head + 4, 8) == -1);
  const char *bad[] = {
    "HTTP/1.1 500 Error\r\nCSeq: 7\r\n\r\n",
    "HTTP/1.1 200 OK\r\n\r\n",
    "HTTP/1.1 200 OK\r\nCSeq: 7x\r\n\r\n",
    "HTTP/1.1 200 OK\r\nCSeq: 7\r\nCSeq: 7\r\n\r\n",
    "HTTP/1.1 200 OK\r\nCSeq: 7\r\nContent-Length: -1\r\n\r\n",
    "HTTP/1.1 200 OK\r\nCSeq: 7\r\nContent-Length: 999999999999999\r\n\r\n",
    "HTTP/1.1 200 OK\r\nCSeq: 7\r\nContent-Length: 1024\r\n\r\n",
    "HTTP/1.1 200 OK\r\nCSeq: 7\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
    "HTTP/1.1 200 OK\r\nCSeq: 7\r\nTransfer-Encoding: chunked\r\n\r\n",
    "HTTP/1.1 200 OK\r\nbad\r\nCSeq: 7\r\n\r\n"
  };
  for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) CHECK(ap_event_reply(bad[i], strlen(bad[i]), 7) == -1);
  memset(reply, 'x', sizeof reply);
  CHECK(ap_event_reply(reply, 1023, 7) == 0);
  CHECK(ap_event_reply(reply, 1024, 7) == -1);
  CHECK(ap_event_reply(reply, 1025, 7) == -1);
  const char *empty = "RTSP/1.0 200 OK\r\nCSeq: 7\r\n\r\n";
  CHECK(ap_event_reply(empty, strlen(empty), 7) == (int)strlen(empty));
}

static void test_gop_recovery(void) {
  gop_recovery r = {0};
  CHECK(!gop_recovery_due(&r, 1, 1, 0, false));
  CHECK(gop_recovery_due(&r, 1, 1, 0, true));
  CHECK(!gop_recovery_due(&r, 1, 1, 4999, true));
  CHECK(gop_recovery_due(&r, 1, 1, 5000, true));
  CHECK(gop_recovery_due(&r, 1, 1, 10000, true));
  CHECK(!gop_recovery_due(&r, 1, 1, 15000, true));
  CHECK(gop_recovery_due(&r, 2, 1, 15001, true)); // new IDR/history generation
  CHECK(gop_recovery_due(&r, 2, 2, UINT32_MAX - 100, true)); // new subscriber
  CHECK(!gop_recovery_due(&r, 2, 2, 100, true));
  CHECK(gop_recovery_due(&r, 2, 2, 4900, true)); // millis wrap
  CHECK(!gop_recovery_due(&r, 3, 3, 9900, false)); // healthy continuity never requests
}

int main(void) {
  test_event_reply();
  test_gop_recovery();
  test_bplist_roundtrip();
  test_bplist_utf16();
  test_bplist_overflow();
  test_gop();
  test_gop_view();
  test_gop_continuation();
  test_video_ring();
  test_chunker();
  printf(fails ? "%d FAILED\n" : "all tests passed\n", fails);
  return fails != 0;
}
