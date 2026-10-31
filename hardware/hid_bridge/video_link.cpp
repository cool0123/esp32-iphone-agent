// Mirrored H.264 from AirPlay to BLE, see video_link.h.
#include "video_link.h"
#include <esp_heap_caps.h>
#include <esp_random.h>
#include "src/video/ring.h"
#include "ble_link.h"
#include "src/video/gop.h"
#include "src/airplay/airplay.h"

// GOP since the latest IDR; overflow drops it until the next IDR. A still screen gets an IDR only every
// few minutes, so room for ~27 min of AUs at 5 fps (P-frames of a still screen are tiny).
const size_t GOP_CAP = 4 * 1024 * 1024;
const int MAX_AUS = 8192;
// A snapshot resends the whole GOP over BLE; past this it cannot arrive before any sane client gives up.
const size_t SNAP_MAX_BYTES = 800 * 1024;
const size_t SCRATCH_CAP = 512 * 1024;   // largest access unit we forward
const size_t MAX_CHUNK = 512;  // then reboot at a safe point instead of waiting forever

struct Req {
  char id[16];
  uint32_t kb;
  bool bench;
};

static gop_buf gop;
static video_ring monitorRing;
static uint32_t monitorEpoch, monitorAt;
const size_t MONITOR_RING_CAP = 1024 * 1024;
static SemaphoreHandle_t lock;
static uint8_t *scratch;
static QueueHandle_t reqs;
static TaskHandle_t task;
static volatile bool streaming;
static uint16_t seq;
static uint8_t chunk[VCHUNK_HDR + MAX_CHUNK];
static uint32_t winStart, winBytes, winFrames;
static volatile uint32_t lastIdr, oversizeDrops, liveContinuations;
static volatile uint32_t statKbps, statIdrMs, statAt;
static volatile float statFps;
static bool ready;

// One access unit as notifies. A failed chunk still consumes its seq, so the app sees a gap.
static bool sendAu(const uint8_t *p, size_t n, uint8_t flags, uint32_t ts) {
  size_t room = min(ble_video_room(), MAX_CHUNK);
  if (room < 5) return false;
  vchunk c;
  vchunk_begin(&c, p, n, flags, ts);
  for (size_t len; (len = vchunk_next(&c, chunk, room, seq)) > 0;) {
    bool ok = ble_video_send(chunk, len);
    seq++;
    if (!ok) return false;
  }
  return true;
}

// Copies AU i of generation gen into scratch; false if the GOP moved on.
static bool copyAu(uint32_t gen, int i, gop_au *au) {
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = gop.gen == gen && i < gop.n && gop.aus[i].len <= SCRATCH_CAP;
  if (ok) {
    *au = gop.aus[i];
    memcpy(scratch, gop.arena + au->off, au->len);
  }
  xSemaphoreGive(lock);
  return ok;
}

// Snapshot of the GOP state: generation, AU count, SPS/PPS.
static bool snapshot(uint32_t *gen, int *n, uint8_t *cfg, size_t *cfg_len, uint32_t *cfg_ts) {
  xSemaphoreTake(lock, portMAX_DELAY);
  *gen = gop.gen;
  *n = gop.wait_idr ? 0 : gop.n;
  *cfg_len = gop.cfg_len;
  *cfg_ts = gop.cfg_ts;
  memcpy(cfg, gop.cfg, gop.cfg_len);
  xSemaphoreGive(lock);
  return *n > 0 && *cfg_len > 0;
}

static String doSnap() {
  static uint8_t cfg[GOP_CFG_MAX];
  if (!ble_video_room()) return "err video not subscribed";
  // BLE carries ~40 kbit/s, so a GOP of several MB would take many minutes and the caller has already timed
  // out. Fail at once with something actionable: a fresh mirroring session starts a new, small GOP.
  xSemaphoreTake(lock, portMAX_DELAY);
  size_t gopBytes = gop.used;
  xSemaphoreGive(lock);
  if (gopBytes > SNAP_MAX_BYTES) {
    return String("err gop ") + (unsigned)(gopBytes / 1024) + " KB too large: reopen Screen Mirroring";
  }
  for (int attempt = 0; attempt < 3; attempt++) {
    uint32_t gen, cfg_ts;
    size_t cfg_len;
    int n;
    if (!snapshot(&gen, &n, cfg, &cfg_len, &cfg_ts)) return "err no decodable GOP (waiting for IDR)";
    if (!sendAu(cfg, cfg_len, VF_CONFIG | VF_SNAP, cfg_ts)) return "err ble send failed";
    bool complete = true;
    for (int i = 0; i < n && complete; i++) {
      gop_au au;
      complete = copyAu(gen, i, &au);
      if (complete && !sendAu(scratch, au.len, VF_SNAP | (au.idr ? VF_IDR : 0), au.ts)) return "err ble send failed";
    }
    if (complete) return "ok";  // else a new IDR replaced the GOP mid-send: start over with it
  }
  return "err video changing too fast";
}

static String doBench(uint32_t kb) {
  size_t room = min(ble_video_room(), MAX_CHUNK);
  if (!room) return "err video not subscribed";
  uint32_t start = millis();
  memset(chunk + VCHUNK_HDR, 0xA5, room);
  for (size_t left = kb * 1024; left;) {
    size_t n = min(left, room);
    chunk[0] = (uint8_t)seq;
    chunk[1] = (uint8_t)(seq >> 8);
    chunk[2] = VF_BENCH;
    bool ok = ble_video_send(chunk, VCHUNK_HDR + n);
    seq++;
    if (!ok) return "err ble send failed";
    left -= n;
  }
  return "ok " + String(millis() - start);
}

// Continuous mode: send every AU once, catching up from the GOP's IDR when streaming starts (P-frames
// can't be skipped: each needs the one before, and the next IDR may be minutes away). After a failed
// send, start over from the GOP's IDR.
static void streamStep() {
  static uint32_t txGen = UINT32_MAX;
  static uint32_t subscriberEpoch;
  static int next;
  static gop_recovery recovery;
  uint32_t epoch = ble_video_epoch();
  if (epoch != subscriberEpoch) {
    subscriberEpoch = epoch;
    txGen = UINT32_MAX;
  }
  static uint8_t cfg[GOP_CFG_MAX];
  if (!streaming || !ble_video_room()) {
    txGen = UINT32_MAX;  // resend config + whole GOP when streaming resumes
    recovery = {};
    return;
  }
  uint32_t gen, cfg_ts;
  size_t cfg_len;
  int n;
  xSemaphoreTake(lock, portMAX_DELAY);
  gen = gop.gen;
  n = gop.wait_idr && !gop.stream_only ? 0 : gop.n;
  cfg_len = gop.cfg_len;
  cfg_ts = gop.cfg_ts;
  bool onlyP = gop.wait_idr && gop.stream_only;
  bool canContinue = gop_can_continue(&gop, txGen, next);
  bool needsKeyframe = (gop.wait_idr && gen != txGen && !canContinue) ||
                       (txGen == UINT32_MAX && gop.used > SNAP_MAX_BYTES);
  memcpy(cfg, gop.cfg, cfg_len);
  xSemaphoreGive(lock);
  if (gop_recovery_due(&recovery, gen, epoch, millis(), needsKeyframe)) airplay_request_keyframe();
  if (!n || !cfg_len) return;
  if (gen != txGen) {
    if (onlyP) {
      // CONFIG would invalidate a running decoder's references. Continue only if every AU before
      // this overflow was sent; a previously caught-up but now lagging subscriber still needs an IDR.
      if (!canContinue) { txGen = UINT32_MAX; return; }
      txGen = gen;
      next = 0;
      liveContinuations++;
    } else {
      txGen = gen;
      next = 0;
      if (!sendAu(cfg, cfg_len, VF_CONFIG, cfg_ts)) { txGen = UINT32_MAX; return; }
    }
  }
  for (gop_au au; next < n && copyAu(gen, next, &au); next++) {
    if (ble_video_epoch() != subscriberEpoch) { txGen = UINT32_MAX; return; }
    if (!sendAu(scratch, au.len, au.idr ? VF_IDR : 0, au.ts)) { txGen = UINT32_MAX; return; }
  }
}

static void videoTask(void *) {
  for (;;) {
    Req r;
    if (xQueueReceive(reqs, &r, 0) == pdTRUE) {
      String reply = String(r.id) + " " + (r.bench ? doBench(r.kb) : doSnap());
#if DEBUG_SERIAL
      Serial.println("video: " + reply);  // the reply only goes over BLE; mirror it for serial-driven tests
#endif
      ble_reply(reply);
    }
    streamStep();
    ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(20));
  }
}

bool video_begin() {
  uint8_t *arena = (uint8_t *)heap_caps_malloc(GOP_CAP, MALLOC_CAP_SPIRAM);
  gop_au *aus = (gop_au *)heap_caps_malloc(MAX_AUS * sizeof(gop_au), MALLOC_CAP_SPIRAM);
  scratch = (uint8_t *)heap_caps_malloc(SCRATCH_CAP, MALLOC_CAP_SPIRAM);
  if (!arena || !aus || !scratch) {
    heap_caps_free(arena);
    heap_caps_free(aus);
    heap_caps_free(scratch);
    scratch = NULL;
    return false;
  }
  gop_init(&gop, arena, GOP_CAP, aus, MAX_AUS);
  uint8_t *monitorArena = (uint8_t *)heap_caps_malloc(MONITOR_RING_CAP, MALLOC_CAP_SPIRAM);
  video_ring_init(&monitorRing, monitorArena, monitorArena ? MONITOR_RING_CAP : 0);
  monitorEpoch = esp_random();
  lock = xSemaphoreCreateMutex();
  reqs = xQueueCreate(4, sizeof(Req));
  if (!lock || !reqs) return false;
  ready = xTaskCreatePinnedToCore(videoTask, "video", 6 * 1024, NULL, 2, &task, 1) == pdPASS;
  return ready;
}

void video_on_config(const uint8_t *sps_pps, size_t len) {
  if (!ready) return;
  xSemaphoreTake(lock, portMAX_DELAY);
  gop_set_config(&gop, sps_pps, len, millis());
  xSemaphoreGive(lock);
}

void video_on_au(const uint8_t *au, size_t len, bool idr) {
  if (!ready) return;
  uint32_t now = millis();
  winBytes += len;
  winFrames++;
  if (idr) {
    if (lastIdr) statIdrMs = now - lastIdr;
    lastIdr = now;
  }
  if (now - winStart >= 1000) {
    statKbps = winBytes * 8 / (now - winStart);
    statFps = winFrames * 1000.0f / (now - winStart);
    statAt = now;
    winBytes = winFrames = 0;
    winStart = now;
  }
  xSemaphoreTake(lock, portMAX_DELAY);
  if (monitorRing.cap) video_ring_push(&monitorRing, au, len);
  monitorAt = now;
  if (len > SCRATCH_CAP) {
    // This AU can never be copied for BLE. Drop the GOP instead of retrying it forever; a later
    // decodable IDR can still recover. Rebooting cannot fix an oversized encoder frame.
    oversizeDrops++;
    gop.used = gop.n = 0;
    gop.gen++;
    gop.wait_idr = true;
    gop.stream_only = false;
  } else {
    gop_push(&gop, au, len, idr, now);
  }
  xSemaphoreGive(lock);
  xTaskNotifyGive(task);
}

void video_stream(bool on) { streaming = on; }

static void request(const String &id, bool bench, uint32_t kb) {
  if (!ready) { ble_reply(id + " err video unavailable"); return; }
  Req r = {{0}, kb, bench};
  strncpy(r.id, id.c_str(), sizeof r.id - 1);
  if (xQueueSend(reqs, &r, 0) != pdTRUE) ble_reply(id + " err busy");
}

void video_snap(const String &id) { request(id, false, 0); }
void video_bench(const String &id, uint32_t kb) { request(id, true, kb); }

bool video_monitor_open(uint32_t epoch, uint64_t offset, bool cursor, MonitorView *view) {
  if (!ready || !monitorRing.cap) return false;
  xSemaphoreTake(lock, portMAX_DELAY);
  *view = {};
  view->epoch = monitorEpoch;
  view->end = monitorRing.end;
  view->captured_ms = monitorAt;
  view->incremental = cursor && epoch == monitorEpoch && video_ring_read(&monitorRing, offset, nullptr, 0);
  bool ok = view->incremental || gop_view_open(&gop, &view->prefix);
  if (ok) view->start = view->incremental ? offset : view->end - view->prefix.bytes;
  xSemaphoreGive(lock);
  return ok;
}

bool video_monitor_read(const MonitorView *view, uint64_t offset, uint8_t *out, size_t len) {
  if (!ready || offset < view->start || offset > view->end || len > view->end - offset) return false;
  xSemaphoreTake(lock, portMAX_DELAY);
  bool ok = view->incremental
    ? video_ring_read(&monitorRing, offset, out, len)
    : gop_view_read(&gop, &view->prefix, (size_t)(offset - view->start), out, len);
  xSemaphoreGive(lock);
  return ok;
}

VideoStats video_stats() {
  if (!ready) return {};
  uint32_t now = millis();
  bool fresh = now - statAt < 3000;  // mirroring stopped: report zeros, not stale numbers
  xSemaphoreTake(lock, portMAX_DELAY);
  uint32_t gopBytes = gop.used, overflows = gop.overflows;
  int frames = gop.n;
  bool waiting = gop.wait_idr;
  xSemaphoreGive(lock);
  return {fresh ? statKbps : 0, statIdrMs, gopBytes, lastIdr ? now - lastIdr : 0,
          overflows, oversizeDrops, frames, waiting, fresh ? statFps : 0, liveContinuations};
}
