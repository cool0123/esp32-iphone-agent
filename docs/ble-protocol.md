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
`seq` increments per notify; the app counts gaps as drops and waits for the next IDR/CONFIG after a gap.

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
