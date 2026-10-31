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
replayed after reconnection are not fresh. `/api/frame.jpg` rejects an unavailable, damaged or stale screenshot.
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
- Both require `Authorization: Bearer <window-credential>`; there is no network HID command endpoint.

The desktop can fetch the full cache over Wi-Fi without subscribing to BLE video. This reduces BLE load and
avoids replaying megabytes through BLE after each desktop reconnect. The client must bound capture age,
including download/decode time, and reject truncated or corrupt downloads. A GOP replacement during the
transfer deliberately aborts it; retry from the new IDR. No decodable GOP returns 503. This does not repair
iOS background decoding, board brownouts, or the phone's BLE video transport.

Remote management requires the app to be running. iOS may suspend network activity when the app is not kept
active by the board's BLE connection; an offline status is then expected, not a firmware failure.
