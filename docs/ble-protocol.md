# BLE protocol (ESP32 ⇄ iOS app)

The board is a BLE peripheral named `ESP32 Agent XXXX` (XXXX = last 2 MAC bytes, hex).
Security: LE Secure Connections, bonding, Just Works. `net` requires an encrypted link,
so reading it triggers the iOS pairing prompt.

Service `6e400001-a9e8-4b1b-9c39-6d6f8a3c0000`

| Characteristic | UUID suffix | Props | Purpose |
|---|---|---|---|
| `cmd`    | `...0001` | write, write-no-rsp | one command line, UTF-8, `<id> <command>` |
| `reply`  | `...0002` | notify | `<id> ok` or `<id> err <reason>` |
| `status` | `...0003` | notify, read | JSON heartbeat, every 1 s (also keeps the app alive in background) |
| `video`  | `...0004` | notify | H.264 chunks, see below |
| `net`    | `...0005` | read, write (encrypted) | network config JSON |

Full UUID = `6e400001-a9e8-4b1b-9c39-6d6f8a3c` + 4-hex suffix, e.g. cmd = `6e400001-a9e8-4b1b-9c39-6d6f8a3c0001`.

## cmd
`<id>` is a decimal request id chosen by the app; the reply echoes it.
Existing HID commands, unchanged semantics from the old TCP protocol:
`ping`, `home`, `move DX DY`, `press`, `release`, `click`, `scroll A B`, `type TEXT`, `key COMBO`.
New:
- `stream on|off` — continuously forward every access unit over `video` (default off).
  OFF now advances an atomic cancellation epoch checked at live chunk boundaries, invalidating old history
  even if ON follows before the video task drains its current AU. Explicit `snap`/`bench` are unchanged.
  Firmware uploaded for this change; real-device cancellation/reconnect validation is still pending.
- `snap` — send SPS/PPS + every AU since the last IDR (the current GOP), then reply `ok`.
- `keyframe [status]` — **disabled by default**. `keyframe` returns `err experimental keyframes disabled`;
  `keyframe status` reports `enabled/sent/acked/failed/idr_age`. The first actual iOS 15 test sent a command,
  got no valid ACK/new IDR and was followed by mirror shutdown without a board reboot. Default builds now
  advertise `eventPort=0`, open no event listener and send no such commands, including from automatic recovery.
  A developer-only `AIRPLAY_EXPERIMENTAL_KEYFRAME=1` build retains TCP 7013 `/command` experiments and the
  three-attempt/5 s bounds. Neither queued commands nor 2xx replies count as successful decoding recovery.
- `power [status]` — report whether USB was configured at boot, enumeration wait in ms, and BLE TX
  readback. The startup guard waits at most 3 s plus 250 ms settling before RF initialization; a hostless
  external supply retains the bounded fallback. The guard/command is installed on the test board:
  `Nov  1 2026 06:03:20`, `usb_boot_configured=true,usb_wait_ms=140,ble_tx_dbm=0`. Low-voltage resets still
  occurred during the update/reboot (`bo:21→22`); configuration success does not prove stable power.
- `resync` — queue session closure on the RTSP task. iOS may stop mirroring completely; it is not an
  automatic reconnect/keyframe guarantee.
- `res W H` — AirPlay resolution advertised in `/info` (default 480 1040), stored in NVS; takes effect on the next mirroring session.
- `fps N` — max fps advertised (default 5), stored in NVS.
- `bench KB` — send KB kilobytes of filler on `video` with the `bench` flag, then reply `ok <ms>`.
- `unpair` — erase all bonds and restart advertising.
- `coex [bt|balance|wifi]` — Wi-Fi/BLE radio-share preference (A/B knob, not stored; every boot starts at
  `balance`). Replies `ok <current>`; bare `coex` just reports it.
When the link drops, the board releases all buttons/keys (same as before).

## status (JSON, one notify per second, must fit one MTU; keep short keys)
```json
{"up":123456,"rst":"power-on","heap":81234,"psram":6200000,"usb":"ok|asleep|off",
 "net":"ap|sta|none","ip":"192.168.4.1","sta":1,
 "ap":"idle|connected|streaming","w":480,"h":1040,"kbps":180,"fps":4.8,"idr":2000,"idr_age":500,
 "gop":42000,"aus":12,"ov":0,"adrop":0,"vwait":0,
 "ble":{"mtu":247,"phy":2,"kbps":350,"drop":0,"rdrop":0,"n":1}}
```
`kbps` = AirPlay video bitrate in, `ble.kbps` = video bytes out over BLE, `idr` = ms between IDRs, `idr_age` = ms since the last IDR, `gop` = bytes buffered since last IDR.
`aus` = buffered access units, `ov` = GOP overflow count, `adrop` = oversized access units dropped, `vwait` = 1 while snapshots are waiting for an IDR. After a GOP overflow the live stream keeps forwarding P-frames for an already-running decoder; only random-access snapshots wait for the next IDR, and the board does not restart.
`rst` = reset reason of the current boot (`power-on|brownout|watchdog|crash|software|usb|other`), `up` = ms since boot.
`ble.tx` = controller default connection transmit power readback in dBm (255 on read failure).
Default TX was reduced from 9 to 0 dBm after strong phone RSSI measurements; this mitigates current peaks,
but is not proof of a stable supply or a diagnosed electrical cause.
`ble.drop` = video notifies given up, `ble.rdrop` = replies that never reached a subscribed peer (should stay 0),
`ble.n` = connected centrals.

Send priority: replies and status are queued and always go out before further video; video keeps at most
~8 ACL packets (~2 KB) in the controller, so a reply waits behind at most that much video. In `stream on`,
every dependent frame must arrive in order; failed sends invalidate the cursor and restart from a complete
GOP when one exists. If the history is P-only, the receiver waits for a new actual IDR; old P-frames are not
made independently decodable by retimestamping or skipping frames.

## video
Each notify: `[seq u16 LE][flags u8][payload]`, payload up to MTU-3-3 bytes.
flags: bit0 START of access unit, bit1 END of access unit, bit2 IDR, bit3 CONFIG (payload is SPS+PPS),
bit4 BENCH (filler, ignore), bit5 SNAP (part of a snap reply).
Payload is Annex-B (`00 00 00 01` start codes). On a START chunk the first 4 payload bytes are a u32 LE
board timestamp (ms) for latency stats, followed by the Annex-B data.
`seq` increments per notify; after a gap the app requires CONFIG as needed and a complete IDR before
accepting dependent frames. CONFIG alone cannot restore reference pictures.

The iOS client resets its decoder **before** enabling video notifications, rather than at the later encrypted
network-read/link-ready callback: CONFIG or an IDR START may arrive before readiness. On a restored
CoreBluetooth connection whose video characteristic is already notifying, the client first disables it and
waits for that callback before resetting/re-enabling it, creating a subscription edge for prefix replay.
This cannot recreate an IDR already missing from a P-only board history. Build 10 is installed; its restored
subscription recovery subsequently failed with a retained complete GOP after an actual force-quit/relaunch.
Build 11 additionally restores Legacy stream intent on process launch and, once the command channel is ready,
issues OFF, waits 200 ms, then resets video without clearing the known board clock and issues ON. It aborts
if the link changes during that wait. This is a continuous prefix replay, not an automatic `snap` fallback or
proof of source freshness. Build 11 is now signed/installed (authenticated 1.0.11). Its first launch logged
OFF/ON after readiness, natively decoded the retained historical prefix, rejected its ~511 s age, and caught
up to a fresh ~0.31 s source without a desktop stream restart. A subsequent force-quit was confirmed, but
intermittent/stale mirrored output initially blocked guarded desktop relaunch. The owner then manually
reopened Agent without a requested mirror restart: this retained-GOP process relaunch also recovered natively,
first observed live after ~205.43 s at ~0.066 s source age, with no desktop forwarding restart/snap/keyframe.
Seven further samples across 30.47 s stayed live (0.048–0.387 s). This is one successful retained-GOP relaunch;
missing-IDR cold recovery, restored background subscriptions and general reconnect reliability are unverified.
All three cloud workflows succeeded; both simulator suites passed 102 tests.

## Read-only Wi-Fi video (build 12)

After command readiness, build 12 sends stream OFF and obtains the private IPv4/3235/48-hex-character
monitor capability over BLE. Its HTTP client uses an ephemeral uncached session with redirects refused.
BLE video callbacks are ignored while Wi-Fi is selected. A complete HTTP response and cursor continuity
must validate before decoding. The prefix requires SPS/PPS plus a complete IDR; subsequent requests use
the 64-bit byte cursor and boot epoch. Historical intermediate pictures are reference-only: only the last
picture in a response may publish, using X-Frame-Ms anchored conservatively to request start/board uptime.
Empty responses never refresh an existing image. Link loss/cancellation invalidates old callbacks. Network
failure or 503 clears the reference chain and blocks input until a complete replay succeeds. Missing-IDR
cold recovery is still unresolved.

The phone's monitor/OTA command replies redact credentials before debug logging. The firmware now renews
an active per-boot monitor capability without rotating its token or closing in-flight requests. This prevents
two BLE centrals from repeatedly invalidating each other's video authentication. Unauthenticated HTTP
requests still return 401; the API remains read-only.

Build 12 subsequently passed seven native Wi-Fi live samples (source ages 0.767–1.066 s), one
complete-GOP process relaunch (1,223,632 bytes, 29.482 s from hello to first observed live frame), and
one monitor outage recovery (24.472 s after reopening). The prior BLE relaunch used about 3 MB, so
these trials do not establish a controlled speed ratio. Automatic tasks stayed stopped.

Build 13 (installed, authenticated 1.0.13 hello at 1793515032.7389562) preserves references/cursor across
transport failures and checkpoints validated chains in a 64 MB local cache. Cache replay is emit=false
and requires the live board to accept its exact session/cursor. Tokens/keys/commands are never cached.
Both simulator suites passed 113 tests. Its initial large-history transfer failed before a complete chain
was saved; the board then overflowed to P-only (ov=1,vwait=1). A later 1.0.13 hello at
1793516123.6557567 was followed by an observed native live frame (age 0.659 s), but no controlled
force-quit cache recovery was established.

Follow-up implementation `a39e3c800efdfbb6b488d5a6fe0217e7a91bc16b` adds bounded AU-aligned GOP
windows (128 KiB target; a larger single AU stays whole), continuing older offsets from the GOP even
when they precede the 1 MB live ring. Each window retains its own last AU source timestamp. Incremental
responses omit config; the first window still requires SPS/PPS+IDR. New encoder configuration resets the
ring/reference GOP and advances the monitor epoch; in-flight old views are rejected. Protocol remains 3.
The build 14 phone patch requires an actual new decoded frame after an outage: empty responses and
pre-outage callbacks cannot reauthorize an old image. Diagnostics record only numeric HTTP/URL error codes.
Build 14 is installed (authenticated 1.0.14 hello at 1793516620.6908545); all three CI workflows
passed, both simulator suites 113 tests. The old running firmware accepted its saved cursor and local
reference replay began, but the source then stopped advancing: the next observed image was >7 s old.
No native fresh cache recovery is claimed. Installation and firmware runtime acceptance are tracked
separately in build/reconnect-recovery/verification.json.

Connection TX power is set/read using actual handles; the old DEFAULT readback did not establish per-link
power. Prior two-peer/reconnect samples read 0 dBm. Bounded-window firmware is deployed with verified
marker wifi-video-window-v2, SHA256 767467e03c935c31cb73f6975dadf242479e36efaaaf237b7639e07affb9f5c0.
After one upload timeout, retry with phone polling paused returned0; stream configuration was restored.
Brownouts rose 24→25 around this reboot;
supply remains unresolved. USB boot configuration was observed after130ms; actual peer TX reads0dBm.
At that deployment the mirror was idle with no GOP; the follow-up below records subsequent acceptance.
Keyframe experiments remain disabled, OTA off, coexistence balanced. Host/simulator passes and deployment
alone do not establish P-only recovery, independent task success, or long-duration supply stability.

## Build 14/15 native follow-up (2026-11-01)

After the owner restarted system mirroring, build 14 produced native live screenshots. Independent
read-only window checks downloaded about 283 KB in 3 batches and 1,483,625 bytes in 12 batches,
including continuation before the 1 MB ring; final window source ages were 27 ms and 125 ms. Native
screenshots remained available. The desktop reader was stopped for the larger diagnostic to stay
within the two HTTP sockets; an earlier three-reader attempt was disconnected.

Monitor off/on rejected stale screenshot requests (409) and resumed: first observed screenshot 200
about 3 s after reopening; both live telemetry and screenshot success observed at 6.365 s. Telemetry
can lag, so these are observation timings. After a real force-quit and confirmed Ops offline, one
complete-GOP cache relaunch accepted the saved cursor at 13:44:07.671Z and produced fresh native
output 18.772 s after hello. Same original mirror, no board reboot; bo remained 25. These are separate
trials, not controlled acceleration ratios or independent agent tasks.

Later a queued HTTP request exposed a clock bug: request-start minus server uptime is a LOWER bound,
but min retained the worst delay. Build 15 keeps the greatest conservative HTTP bound separately from
BLE's receive-time upper bound. Metadata/empty responses never republish a frame, and the 3 s input
limit remains. Commit 970ac869dc2e7f74dd781678a14d27eb26f376fb, authenticated 1.0.15 hello
1793541826.4836347; all three workflows passed, both simulator suites 114 tests. Regression covers
slow/fast requests, historical pictures, BLE contamination, empty responses and transport reset.

After upgrading, build 15 accepted saved references and produced native live output (age 0.320 s)
while the board was P-only (ov=1,vwait=1), after the App was brought to foreground. This is an observed
recovery path, not the following controlled force-quit trial: after that trial actually closed the App
and Ops went offline, the mirror stopped sending video (ap=connected,fps=0). Both readers have no
fresh source; HID is blocked. That controlled P-only trial is BLOCKED, not passed. Reopen the App
without changing system mirroring first to preserve the experiment. No autonomous tasks ran; power
root cause and background reconnect reliability remain unresolved. bo stayed 25; self-review only.

## net (JSON)
Read: `{"mode":"ap","ssid":"ESP32Agent-1A2B","pass":"<random 12 chars>","ip":"192.168.4.1"}`
(SoftAP credentials are generated once at first boot and kept in NVS).
Write `{"mode":"ap"}` or `{"mode":"sta","ssid":"...","pass":"..."}` — stored in NVS, board restarts Wi-Fi.

## AirPlay
Receiver name `ESP32 Agent`, mirroring only (no audio), H.264 only, resolution/fps from NVS.

## Deviations (firmware notes)
- `status`: if the negotiated MTU is too small for the full JSON (MTU-3 < ~255 bytes), the notify carries a
  reduced object `{"up","rst","usb","net","ap","vwait","ov","ble":{"mtu"}}`; a `status` read always returns the last full JSON.
- `sta` in `status` = number of stations on the board's hotspot (mode `ap`), or 1/0 = connected (mode `sta`).
- `net` read in `sta` mode returns the station network's `ssid`/`pass`.
- `snap` while mirroring has stopped returns the last buffered GOP (check `"ap"` in status); `snap` without
  any video replies `err no video ...`.
