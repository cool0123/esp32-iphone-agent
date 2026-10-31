/*
 * RTSP/HTTP server of the AirPlay receiver: accepts connections on port 7000, frames
 * requests (header + Content-Length body) and sends responses. Replaces UxPlay's
 * lib/httpd.c + llhttp + http_request/response with a minimal parser.
 * Copyright (C) 2011-2012 Juho Vähä-Herttua, (C) 2021-2025 F. Duncanh; ESP32 port 2026.
 *
 * This program is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version. See LICENSE-GPL.md.
 */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <stdatomic.h>
#include "event_protocol.h"
#include "../bplist/bplist.h"
#include "lwip/sockets.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "ap_internal.h"

#define MAX_CONNS 3
#define MAX_REQUEST (64 * 1024)

airplay_cfg ap_cfg;
static ap_conn conns[MAX_CONNS];
static void close_conn(ap_conn *c);
static atomic_bool keyframe_pending, event_ready, drop_pending;
static atomic_uint_least32_t keyframe_sent, keyframe_acked, keyframe_failed;

bool airplay_request_keyframe(void) {
  if (!atomic_exchange(&event_ready, false)) return false;
  atomic_store(&keyframe_pending, true);
  return true;
}

void airplay_keyframe_stats(uint32_t *sent, uint32_t *acked, uint32_t *failed) {
  *sent = atomic_load(&keyframe_sent);
  *acked = atomic_load(&keyframe_acked);
  *failed = atomic_load(&keyframe_failed);
}

static void close_event(ap_conn *c) {
  if (c->event_waiting) atomic_fetch_add(&keyframe_failed, 1);
  if (c->event_fd >= 0) close(c->event_fd);
  c->event_fd = -1;
  c->event_waiting = false;
  c->event_len = 0;
}

void ap_log(const char *fmt, ...) {
  if (!ap_cfg.log) return;
  char msg[160];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(msg, sizeof msg, fmt, ap);
  va_end(ap);
  ap_cfg.log(msg);
}

const char *ap_header(const ap_req *r, const char *name) {
  for (int i = 0; i < r->nhdr; i++)
    if (!strcasecmp(r->names[i], name)) return r->vals[i];
  return NULL;
}

void ap_resp_header(ap_resp *r, const char *name, const char *val) {
  int n = snprintf(r->hdrs + r->hlen, sizeof r->hdrs - r->hlen, "%s: %s\r\n", name, val);
  if (n > 0 && r->hlen + n < sizeof r->hdrs) r->hlen += n;
}

int airplay_state(void) {
  if (ap_mirror_streaming()) return AIRPLAY_STREAMING;
  for (int i = 0; i < MAX_CONNS; i++)
    if (conns[i].fd >= 0 && (conns[i].have_keymsg || ap_mirror_owner == &conns[i])) return AIRPLAY_CONNECTED;
  return AIRPLAY_IDLE;
}

void airplay_drop_sessions(void) {
  // Serialize teardown with RTSP/event I/O. Closing may stop iOS mirroring entirely.
  atomic_store(&drop_pending, true);
}

static bool send_all(int fd, const void *p, size_t n) {
  const uint8_t *b = p;
  while (n) {
    int k = send(fd, b, n, 0);
    if (k <= 0) return false;
    b += k;
    n -= k;
  }
  return true;
}

static void send_keyframe(ap_conn *c) {
  bp_writer w;
  bp_writer_init(&w);
  int root = bp_w_dict(&w);
  bp_w_set(&w, root, "type", bp_w_string(&w, "forceKeyFrame"));
  size_t len = 0;
  uint8_t *body = bp_w_finish(&w, &len);
  bp_writer_free(&w);
  if (!body) { atomic_fetch_add(&keyframe_failed, 1); return; }
  char head[256];
  int n = snprintf(head, sizeof head,
                   "POST /command HTTP/1.1\r\nCSeq: %lu\r\nContent-Type: application/x-apple-binary-plist\r\n"
                   "Content-Length: %u\r\n\r\n", (unsigned long)++c->event_seq, (unsigned)len);
  bool ok = n > 0 && n < (int)sizeof head && send_all(c->event_fd, head, n) && send_all(c->event_fd, body, len);
  free(body);
  if (!ok) { atomic_fetch_add(&keyframe_failed, 1); close_event(c); return; }
  atomic_fetch_add(&keyframe_sent, 1);
  c->event_waiting = true;
  c->event_deadline = xTaskGetTickCount() + pdMS_TO_TICKS(2000);
  ap_log("event: forceKeyFrame sent");
}

static void read_event(ap_conn *c) {
  if (!c->event_waiting) { close_event(c); return; }
  int n = recv(c->event_fd, c->event_buf + c->event_len, sizeof c->event_buf - c->event_len, 0);
  if (n <= 0) { close_event(c); return; }
  c->event_len += n;
  int result = ap_event_reply(c->event_buf, c->event_len, c->event_seq);
  if (result < 0) { close_event(c); return; }
  if (result > 0) {
    if ((size_t)result != c->event_len) { close_event(c); return; }
    atomic_fetch_add(&keyframe_acked, 1);
    c->event_waiting = false;
    c->event_len = 0;
    ap_log("event: forceKeyFrame acknowledged (new IDR still required)");
  }
}

static void close_conn(ap_conn *c) {
  if (ap_mirror_owner == c) {
    atomic_store(&keyframe_pending, false);
    atomic_store(&event_ready, false);
    ap_mirror_stop();
    ap_mirror_owner = NULL;
  }
  close_event(c);
  close(c->fd);
  free(c->buf);
  memset(c, 0, sizeof *c);
  c->fd = c->event_fd = -1;
  ap_log("rtsp: connection closed");
}

// Splits "Name: value" header lines; returns false on a malformed request line.
static bool parse_head(char *head, ap_req *r) {
  char *line = head, *next;
  memset(r, 0, sizeof *r);
  next = strstr(line, "\r\n");
  if (next) *next = 0;
  r->method = strtok_r(line, " ", &line);
  r->url = strtok_r(NULL, " ", &line);
  r->proto = strtok_r(NULL, " ", &line);
  if (!r->method || !r->url || !r->proto) return false;
  for (line = next ? next + 2 : NULL; line && *line; line = next ? next + 2 : NULL) {
    next = strstr(line, "\r\n");
    if (next) *next = 0;
    char *colon = strchr(line, ':');
    if (!colon || r->nhdr == AP_MAX_HDRS) continue;
    *colon++ = 0;
    while (*colon == ' ') colon++;
    r->names[r->nhdr] = line;
    r->vals[r->nhdr++] = colon;
  }
  return true;
}

static bool respond(ap_conn *c, const ap_req *req, ap_resp *res) {
  char head[640];
  int n = snprintf(head, sizeof head, "%s %d %s\r\n%.*sContent-Length: %u\r\n\r\n", req->proto, res->code,
                   res->reason, (int)res->hlen, res->hdrs, (unsigned)res->body_len);
  bool ok = n > 0 && n < (int)sizeof head && send_all(c->fd, head, n) &&
            (!res->body_len || send_all(c->fd, res->body, res->body_len));
  free(res->body);
  return ok && !res->close;
}

// Handles every complete request in the connection buffer. False = close the connection.
static bool process(ap_conn *c) {
  for (;;) {
    char *end = c->len >= 4 ? memmem(c->buf, c->len, "\r\n\r\n", 4) : NULL;
    if (!end) return c->len < MAX_REQUEST;
    size_t head_len = end - (char *)c->buf + 4;
    *end = 0;  // the head becomes a C string; body follows at head_len
    const char *cl = strcasestr((char *)c->buf, "\r\nContent-Length:");
    size_t body_len = cl ? strtoul(cl + 17, NULL, 10) : 0;
    if (head_len + body_len > MAX_REQUEST) return false;
    if (c->len < head_len + body_len) {
      *end = '\r';  // wait for the rest of the body
      return true;
    }
    ap_req req;
    ap_resp res = {.code = 200, .reason = "OK"};
    if (!parse_head((char *)c->buf, &req)) return false;
    req.body = c->buf + head_len;
    req.body_len = body_len;
    ap_handle(c, &req, &res);
    if (!respond(c, &req, &res)) return false;
    memmove(c->buf, c->buf + head_len + body_len, c->len - head_len - body_len);
    c->len -= head_len + body_len;
  }
}

static bool read_conn(ap_conn *c) {
  if (c->cap - c->len < 1024) {
    size_t cap = c->cap ? c->cap * 2 : 4096;
    if (cap > MAX_REQUEST + 4096) return false;
    uint8_t *b = realloc(c->buf, cap + 1);
    if (!b) return false;
    c->buf = b;
    c->cap = cap;
  }
  int n = recv(c->fd, c->buf + c->len, c->cap - c->len, 0);
  if (n <= 0) return false;
  c->len += n;
  return process(c);
}

static void server_task(void *arg) {
  int lfd = socket(AF_INET, SOCK_STREAM, 0), one = 1;
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(AP_RTSP_PORT), .sin_addr.s_addr = htonl(INADDR_ANY)};
  setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  if (bind(lfd, (struct sockaddr *)&a, sizeof a) || listen(lfd, 2)) {
    ap_log("rtsp: cannot listen on %d", AP_RTSP_PORT);
    vTaskDelete(NULL);
  }
  int efd = socket(AF_INET, SOCK_STREAM, 0);
  a.sin_port = htons(AP_EVENT_PORT);
  setsockopt(efd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  if (bind(efd, (struct sockaddr *)&a, sizeof a) || listen(efd, 2)) {
    close(efd); close(lfd);
    ap_log("rtsp: cannot listen on event port %d", AP_EVENT_PORT);
    vTaskDelete(NULL);
    return;
  }
  for (int i = 0; i < MAX_CONNS; i++) conns[i].fd = conns[i].event_fd = -1;
  for (;;) {
    if (atomic_exchange(&drop_pending, false))
      for (int i = 0; i < MAX_CONNS; i++) if (conns[i].fd >= 0) close_conn(&conns[i]);
    if (atomic_exchange(&keyframe_pending, false)) {
      ap_conn *c = ap_mirror_owner;
      if (c && c->event_fd >= 0 && !c->event_waiting) send_keyframe(c);
      else atomic_fetch_add(&keyframe_failed, 1);
    }
    for (int i = 0; i < MAX_CONNS; i++)
      if (conns[i].event_waiting && (int32_t)(xTaskGetTickCount() - conns[i].event_deadline) >= 0)
        close_event(&conns[i]);
    atomic_store(&event_ready, ap_mirror_owner && ap_mirror_owner->event_fd >= 0 &&
                 !ap_mirror_owner->event_waiting && !atomic_load(&keyframe_pending));
    fd_set rf;
    FD_ZERO(&rf);
    FD_SET(lfd, &rf);
    FD_SET(efd, &rf);
    int maxfd = lfd > efd ? lfd : efd;
    for (int i = 0; i < MAX_CONNS; i++) {
      if (conns[i].event_fd >= 0) {
        FD_SET(conns[i].event_fd, &rf);
        if (conns[i].event_fd > maxfd) maxfd = conns[i].event_fd;
      }
      if (conns[i].fd >= 0) {
        FD_SET(conns[i].fd, &rf);
        if (conns[i].fd > maxfd) maxfd = conns[i].fd;
      }
    }
    struct timeval tv = {0, 100000};
    if (select(maxfd + 1, &rf, NULL, NULL, &tv) <= 0) continue;
    if (FD_ISSET(efd, &rf)) {
      struct sockaddr_in peer = {0};
      socklen_t pl = sizeof peer;
      int fd = accept(efd, (struct sockaddr *)&peer, &pl);
      ap_conn *owner = NULL;
      int matches = 0;
      for (int i = 0; i < MAX_CONNS; i++)
        if (conns[i].fd >= 0 && conns[i].have_aes && conns[i].remote_ip == peer.sin_addr.s_addr) {
          owner = &conns[i]; matches++;
        }
      if (fd >= 0 && matches == 1 && owner->event_fd < 0) {
        struct timeval timeout = {0, 200000};
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        owner->event_fd = fd;
        ap_log("event: session connection accepted");
      } else if (fd >= 0) close(fd);
    }
    if (FD_ISSET(lfd, &rf)) {
      struct sockaddr_in peer;
      socklen_t pl = sizeof peer;
      int fd = accept(lfd, (struct sockaddr *)&peer, &pl);
      ap_conn *c = NULL;
      for (int i = 0; i < MAX_CONNS && !c; i++)
        if (conns[i].fd < 0) c = &conns[i];
      if (fd >= 0 && !c) {
        close(fd);
      } else if (fd >= 0) {
        memset(c, 0, sizeof *c);
        c->fd = fd;
        c->event_fd = -1;
        c->remote_ip = peer.sin_addr.s_addr;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        ap_log("rtsp: connection from %s", inet_ntoa(peer.sin_addr));
      }
    }
    for (int i = 0; i < MAX_CONNS; i++) {
      if (conns[i].event_fd >= 0 && FD_ISSET(conns[i].event_fd, &rf)) read_event(&conns[i]);
      if (conns[i].fd >= 0 && FD_ISSET(conns[i].fd, &rf) && !read_conn(&conns[i])) close_conn(&conns[i]);
    }
  }
}

void airplay_set_display(uint16_t width, uint16_t height, uint8_t max_fps) {
  ap_cfg.width = width;
  ap_cfg.height = height;
  ap_cfg.max_fps = max_fps;
}

bool airplay_start(const airplay_cfg *cfg) {
  ap_cfg = *cfg;
  for (int i = 0; i < MAX_CONNS; i++) conns[i].fd = conns[i].event_fd = -1;
  if (!ap_crypto_init(cfg->ed25519_seed)) return false;
  if (!ap_mdns_start()) ap_log("mdns: advertising failed");
  return xTaskCreatePinnedToCore(server_task, "rtsp", 12 * 1024, NULL, 5, NULL, 0) == pdPASS;
}
