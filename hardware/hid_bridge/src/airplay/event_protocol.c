#include "event_protocol.h"
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

int ap_event_reply(const char *data, size_t len, uint32_t cseq) {
  if (len > 1024) return -1;
  char buf[1025];
  memcpy(buf, data, len);
  buf[len] = 0;
  char *end = strstr(buf, "\r\n\r\n");
  if (!end) return len == 1024 ? -1 : 0;
  size_t head = end - buf + 4;
  if (memchr(data, 0, head)) return -1;
  *end = 0;
  unsigned code;
  int used = 0;
  if (sscanf(buf, "HTTP/1.1 %u%n", &code, &used) != 1 &&
      sscanf(buf, "HTTP/1.0 %u%n", &code, &used) != 1 &&
      sscanf(buf, "RTSP/1.0 %u%n", &code, &used) != 1) return -1;
  if (code < 200 || code >= 300 || (buf[used] != ' ' && buf[used] != '\r' && buf[used] != 0)) return -1;
  bool have_seq = false, have_length = false;
  size_t body = 0;
  char *line = strstr(buf, "\r\n");
  while (line) {
    line += 2;
    char *next = strstr(line, "\r\n");
    if (next) *next = 0;
    char *colon = strchr(line, ':');
    if (!colon) return -1;
    *colon++ = 0;
    while (*colon == ' ' || *colon == '\t') colon++;
    if (!strcasecmp(line, "Transfer-Encoding")) return -1;
    bool seq = !strcasecmp(line, "CSeq"), length = !strcasecmp(line, "Content-Length");
    if (seq || length) {
      if ((seq && have_seq) || (length && have_length) || !*colon) return -1;
      uint64_t value = 0;
      for (; *colon; colon++) {
        if (*colon < '0' || *colon > '9' || value > UINT32_MAX / 10u) return -1;
        value = value * 10 + *colon - '0';
        if (value > UINT32_MAX) return -1;
      }
      if (seq) { if (value != cseq) return -1; have_seq = true; }
      else { body = (size_t)value; have_length = true; }
    }
    line = next;
  }
  if (!have_seq || body > 1024 - head) return -1;
  return len < head + body ? 0 : (int)(head + body);
}
