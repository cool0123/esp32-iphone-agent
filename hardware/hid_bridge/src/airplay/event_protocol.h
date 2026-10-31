// Bounded framing for replies to receiver-initiated AirPlay event commands.
#pragma once
#include <stddef.h>
#include <stdint.h>

// 0 = incomplete; positive = complete 2xx reply length; -1 = invalid/rejected.
// The buffer need not be NUL terminated. Reject unbounded bodies and mismatched CSeq.
int ap_event_reply(const char *data, size_t len, uint32_t cseq);
