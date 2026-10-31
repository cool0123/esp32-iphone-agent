#include "monitor_link.h"
#include "video_link.h"
#include <esp_http_server.h>
#include <esp_heap_caps.h>
#include <esp_random.h>

static httpd_handle_t server;
static char token[49];
static uint32_t expires;
static MonitorStatus statusFn;
static const uint32_t WINDOW_MS = 15 * 60 * 1000;

static bool authorized(httpd_req_t *req) {
  if ((int32_t)(expires - millis()) <= 0) return false;
  char header[sizeof token + 7];
  size_t len = httpd_req_get_hdr_value_len(req, "Authorization");
  if (len != 7 + strlen(token) || len >= sizeof header ||
      httpd_req_get_hdr_value_str(req, "Authorization", header, sizeof header) != ESP_OK) return false;
  unsigned diff = 0;
  for (size_t i = 0; i < 7; i++) diff |= header[i] ^ "Bearer "[i];
  for (size_t i = 0; i < sizeof token - 1; i++) diff |= header[i + 7] ^ token[i];
  return diff == 0;
}

static esp_err_t unavailable(httpd_req_t *req, const char *reason) {
  httpd_resp_set_status(req, "503 Service Unavailable");
  return httpd_resp_sendstr(req, reason);
}

static esp_err_t handle(httpd_req_t *req) {
  httpd_resp_set_hdr(req, "Cache-Control", "no-store");
  if (!authorized(req)) return httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, "authentication required");
  if (strcmp(req->uri, "/status") == 0) {
    httpd_resp_set_type(req, "application/json");
    String s = statusFn();
    return httpd_resp_send(req, s.c_str(), s.length());
  }
  gop_view view;
  if (!video_gop_open(&view)) return unavailable(req, "waiting for a decodable GOP");
  uint8_t *buf = (uint8_t *)heap_caps_malloc(16 * 1024, MALLOC_CAP_SPIRAM);
  if (!buf) return unavailable(req, "no snapshot memory");
  char stamp[16];
  snprintf(stamp, sizeof stamp, "%lu", (unsigned long)view.captured_ms);
  httpd_resp_set_hdr(req, "X-Frame-Ms", stamp);
  char up[16];
  snprintf(up, sizeof up, "%lu", (unsigned long)millis());
  httpd_resp_set_hdr(req, "X-Board-Ms", up);
  httpd_resp_set_type(req, "video/h264");
  esp_err_t result = httpd_resp_send_chunk(req, (const char *)view.cfg, view.cfg_len);
  uint32_t started = millis();
  for (size_t offset = 0; result == ESP_OK && offset < view.bytes;) {
    size_t len = min((size_t)16 * 1024, view.bytes - offset);
    if (millis() - started > 5000 || !video_gop_read(&view, offset, buf, len)) {
      result = ESP_FAIL;  // no chunk terminator: clients reject this truncated response
      break;
    }
    result = httpd_resp_send_chunk(req, (const char *)buf, len);
    offset += len;
  }
  heap_caps_free(buf);
  if (result == ESP_OK) result = httpd_resp_send_chunk(req, NULL, 0);
  return result;
}

bool monitor_enable(bool on, MonitorStatus status, char *out, size_t out_len) {
  if (server) { httpd_stop(server); server = NULL; }
  memset(token, 0, sizeof token);
  if (!on) return true;
  if (!status || !out || out_len < sizeof token) return false;
  uint8_t random[24];
  esp_fill_random(random, sizeof random);
  const char *hex = "0123456789abcdef";
  for (size_t i = 0; i < sizeof random; i++) {
    token[i * 2] = hex[random[i] >> 4];
    token[i * 2 + 1] = hex[random[i] & 15];
  }
  expires = millis() + WINDOW_MS;
  statusFn = status;
  httpd_config_t cfg = HTTPD_DEFAULT_CONFIG();
  cfg.server_port = 3235;
  cfg.max_open_sockets = 2;
  cfg.max_uri_handlers = 2;
  cfg.stack_size = 6144;
  cfg.recv_wait_timeout = cfg.send_wait_timeout = 2;
  cfg.lru_purge_enable = true;
  if (httpd_start(&server, &cfg) != ESP_OK) { server = NULL; return false; }
  httpd_uri_t uri = {};
  uri.uri = "/status"; uri.method = HTTP_GET; uri.handler = handle;
  esp_err_t result = httpd_register_uri_handler(server, &uri);
  uri.uri = "/gop.h264";
  if (result == ESP_OK) result = httpd_register_uri_handler(server, &uri);
  if (result != ESP_OK) { httpd_stop(server); server = NULL; return false; }
  snprintf(out, out_len, "%s", token);
  return true;
}

void monitor_poll() {
  if (server && (int32_t)(expires - millis()) <= 0) monitor_enable(false, nullptr, nullptr, 0);
}
