# Remote operations (iPhone + ESP32)

The iOS app makes an **outbound** WebSocket connection to a small management service. The phone works over
cellular or Wi-Fi; no inbound phone listener, public ESP32 port, or computer-side agent is required.
The service relays only status, diagnostics, screenshots, whitelisted configuration, a fixed image/model connection check, and agent stop. It never
exposes arbitrary HID commands, the LLM API key, or the device-management token.

## 1. Start the management service

Use separate random tokens for the phone and the AI/admin client. Put them in the environment, not in source
or command logs. The service refuses to start without both tokens.

```bash
cd server
export OPS_DEVICE_TOKEN='replace-with-a-random-device-token'
export OPS_ADMIN_TOKEN='replace-with-a-different-admin-token'
# Default is loopback only. For a LAN test, explicitly use 0.0.0.0; for production use an HTTPS reverse proxy.
export OPS_HOST=127.0.0.1
export OPS_PORT=8787
uv run python -m hidagent.ops
```

Production: put the service behind an HTTPS reverse proxy. Do not expose the plain HTTP service directly to
the public internet.

## 2. Configure the iOS app

Open **Settings → Remote Management**, or the **远程运维** section in **ESP32 Agent 15** (iOS 15+):

- Management URL: the service's HTTPS base URL, for example `https://ops.example.com`.
- Device token: `OPS_DEVICE_TOKEN` for this phone (stored in the iOS Keychain).
- Enable **Remote management**.

Plain `http://` is accepted only for local test addresses. The app converts `https` to `wss` and connects to
`/ws/device`. The management URL itself cannot be changed through the remote API.

## 3. AI/admin API

Send `Authorization: Bearer $OPS_ADMIN_TOKEN` on every request. Paths below are relative to the service URL.

| Method | Path | Purpose |
|---|---|---|
| GET | `/health` | Unauthenticated process health only |
| GET | `/api/status` | Connection state, latest board/app telemetry |
| GET | `/api/config` | Sanitized model/capture configuration; no credentials |
| POST | `/api/config` | Change whitelisted configuration fields |
| GET | `/api/logs` | Last 100 redacted debug-log lines |
| GET | `/api/frame.jpg` | Current mirrored screenshot |
| POST | `/api/stop` | Stop the agent and release the pointer |
| POST | `/api/model-check` | Run a fixed red-image check using the phone's saved model/credential |

Writable fields: `baseURL`, `model`, `plannerModel`, `actorModel`, `tokenParam`, `extraBody`, `agentName`,
`frameMode` (`stream` or `snap`). Values are strings. Unknown fields, including `apiKey`, are rejected on both
the service and the phone. Model changes apply to the next agent run; capture-mode changes take effect immediately.
Configuration responses also strip URL credentials and query parameters.

Example (tokens stay in the shell environment):

```bash
curl -H "Authorization: Bearer $OPS_ADMIN_TOKEN" https://ops.example.com/api/status
curl -H "Authorization: Bearer $OPS_ADMIN_TOKEN" https://ops.example.com/api/config
curl -H "Authorization: Bearer $OPS_ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"model":"your-vision-model","frameMode":"stream"}' \
  https://ops.example.com/api/config
```

Telemetry's `app.frameAge` measures source capture age, not the time since JPEG decoding. Cached frames being
replayed after reconnection are not fresh. `/api/frame.jpg` rejects an unavailable or stale screenshot.
Build 4 also invalidates the reference chain on CONFIG, packet loss, reconnect or decoder failure, waits for
a complete IDR, and rejects callbacks from older stream generations. A successful decode alone is not proof
of image integrity; the build 3 true-device test exposed mixed historical/current reference pictures despite
fresh timestamps, so it must not be used to certify autonomous tasks.
The iOS 15 app shows its last agent step separately from the changing BLE status. For provisioning by the
owner's trusted BLE debugging client, it also accepts `app ops {"endpoint":"http://LAN_HOST:8787","token":"..."}`;
never print or persist that command with the credential. The endpoint/token remain local to the phone.

## Board LAN diagnostics (optional)

This is separate from phone remote management. A trusted BLE/USB peer can run `monitor on` to open a
15-minute, read-only HTTP window on port 3235. The reply contains the board's IP, port and random bearer
credential. The listener starts **off** at every boot; `monitor off` closes it and a renewed window invalidates
the previous credential. Use it only on a trusted LAN, never expose this HTTP port to the internet.

- `GET /status`: board telemetry.
- `GET /gop.h264`: SPS/PPS plus the cached decodable GOP, with `X-Board-Ms` and `X-Frame-Ms` headers.
- `GET /gop.h264?gen=G&offset=N`: only the continuous stream suffix after the previous complete download.
  `X-Monitor-Protocol: 3` identifies the rolling-cursor protocol. `X-Gop-Gen` is a random boot epoch,
  `X-Gop-Start`/`X-Gop-Bytes` are absolute 64-bit start/end byte positions, and `X-Gop-Config` is the number
  of initial SPS/PPS bytes (excluded from the cursor). A 1 MB rolling buffer lets an already-running decoder
  continue across the separate 4 MB GOP cache overflowing. A reconnect/lagged cursor starts again from a
  decodable GOP plus config when one exists, otherwise returns 503. A response with config resets the decoder.
  Advance a cursor only after a complete response; retain a late initial GOP as a decoder prefix and fetch
  the new suffix before publishing any screenshot. The final frame must still pass source-age checks.
- Both require `Authorization: Bearer <window-credential>`; there is no network HID command endpoint.

The desktop can fetch the initial cache over Wi-Fi and then only new bytes, without subscribing to BLE video.
A first true-device test exposed that repeatedly downloading the full cache exceeded the 3 s freshness bound
as the GOP grew (about 4 s at 0.5 MB); incremental downloads address that measured bottleneck. True-device
protocol v3 testing subsequently followed over 15000 pictures and two GOP-cache overflows with source age
usually around 0.1–1.1 s, without restarting the decoder. Static landscape screens can send only intermittent
frames; the 3 s input gate still applies and must not be bypassed. The desktop keeps one strict low-delay ffmpeg decoder alive, checks
that every expected picture was decoded, and clears the capture on a decode failure. Its capture worker polls
continuously so the decoder stays ready; reading a cached JPEG does not refresh its source capture time.
Credential renewal preserves the decoder and byte cursor. This reduces BLE load and
avoids replaying megabytes through BLE after each desktop reconnect. The client must bound capture age,
including download/decode time, and reject truncated or corrupt downloads. A GOP replacement during the
transfer deliberately aborts it; retry from the new IDR. No decodable GOP returns 503. This does not repair
iOS background decoding, board brownouts, or the phone's BLE video transport.

## iOS 15 acceptance evidence (2026-10-31)

The operations build, build 4 (signed as version 1.0.4), and build 5 (signed as version 1.0.5, bundle build 5)
were installed and launched on iPhone9,4 / iOS 15.8.8. The phone connected to the authenticated LAN service
on port 3233, preserved its Keychain credential across upgrades, and itself returned
`model=deepseek-flash, image=red, reasoning_chars=0` from `/api/model-check` using the saved official
DeepSeek endpoint and explicit `thinking.type=disabled`. The same check passed after build 5 installation
and after the latest board OTA. This proves the model credential and fixed-image request.

A read-only home-screen task completed while the desktop BLE client and management service were stopped:
the phone made two model requests and reported the time, weather, and dock apps, then ended. An independent
operation task opened Calendar and dismissed its first-use prompt, but failed to return home and was stopped.
A complete independent operation task and reliable long-term background video remain unaccepted.

Build 5 permits observed AssistiveTouch → 主屏幕 navigation on iOS 15 and explicitly rejects the ineffective
Legacy `home` shortcut. It also avoids replaying the entire GOP for a healthy, unchanged live stream; damaged
or disconnected reference chains still require an IDR. The complete Calendar → home task needs a new device test.

The latest board patch addresses BLE history-cache overflow: it omits CONFIG only when the sender's AU
cursor exactly matches the end of the immediately preceding generation. A missing tail AU, a skipped generation,
a new subscription, or a failed send cannot use this continuation. `lcs` counts admitted continuation transitions;
this counter alone does not prove the phone decoded intact pictures. Host ASan/UBSan regressions and the full
firmware build passed; OTA returned 0 and the board reported `bv="Nov  1 2026 02:49:50"`, `bo=17`, `usb=ok`,
`ap=idle`, and `lcs=0` (the version is the device's build timestamp). Cross-overflow phone decoding has not yet
been tested with this patch. OTA/brownout can leave mirroring disconnected; the owner must reopen Screen
Mirroring → ESP32 Agent. `resync` was observed to stop mirroring without automatic reconnection.

Remote management requires the app to be running. iOS may suspend network activity when the app is not kept
active by the board's BLE connection; an offline status is then expected, not a firmware failure.
