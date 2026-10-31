# Remote operations (iPhone + ESP32)

The iOS app makes an **outbound** WebSocket connection to a small management service. The phone works over
cellular or Wi-Fi; no inbound phone listener, public ESP32 port, or computer-side agent is required.
The service relays only status, diagnostics, screenshots, whitelisted configuration, and agent stop. It never
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

Open **Settings → Remote Management**:

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

Remote management requires the app to be running. iOS may suspend network activity when the app is not kept
active by the board's BLE connection; an offline status is then expected, not a firmware failure.
