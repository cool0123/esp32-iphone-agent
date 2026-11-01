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

Build 6 (`bd01471`) removes automatic whole-GOP snapshots from continuous streaming. If video falls behind
while the actor replies, the agent waits for live video and discards that decision before looking again;
explicit snapshot mode remains available. The iOS 15 build `41232551721`, iOS build/tests `41232551715`, and
CI `41232551702` passed; the simulator ran 93 tests with zero failures. The first build 6 installation was
reported failed; an operations reconnect confirmed the phone was still running 1.0.5. A fresh upload/import
and re-sign with the existing certificate/defaults produced `Signed/ESP32-Agent15-v1.0.6-retry.ipa`
(SHA256 `727d73506bb6c826ccdaafe7b2f19681aa6de64c1a0f0cbb547bfacf60c4d5c3`). This package **was installed
and launched**: the phone's authenticated hello reported `1.0.6` at `2026-10-31T19:42:34.767Z`.
The saved key/configuration survived; its red-image check again returned
`model=deepseek-flash, image=red, reasoning_chars=0`. The initial installation failure remains unexplained:
the successful build 5 and initial build 6 have identical provisioning/entitlements, and their code hashes
and binary-mode CMS signatures verify.

A subsequent build 5 independent task failed: desktop BLE and management were stopped for about 45 s, the
phone clicked the home screen and opened search, then source lag caused two `snap` timeouts and historical
replays. It did not open Calendar and was stopped (`running=false`, final step `stopped`). Separately,
computer-controlled, visually verified AssistiveTouch → 主屏幕 did return home; this is not an independent task.
During build 6 installation preparation, the board browned out again (`bo=18`, `ap=idle`), leaving no live
screenshot. Input was refused. After mirroring was restored, the installation above succeeded without
another board reboot (`bo=18`). The computer LAN decoder is live, but the newly installed phone decoder
still lacks a complete reference chain (`frameLive=false`, `frameAge=-1`). Stream reception is enabled,
no task is running, and mirroring must be manually stopped and reopened before build 6 task acceptance.

After the owner reopened mirroring, build 6 had a live, intact phone screenshot (source age about 0.08 s).
Three further independent attempts stopped desktop BLE and management for about 45 s each, restoring only
management for evidence. The plain task failed because `type 日历` became ASCII gibberish despite `ok`.
An icon-only attempt also failed; a third attempt with icon hints opened Calendar and used AssistiveTouch,
but repeatedly reopened Calendar after returning to App Library instead of confirming completion. All were
stopped, and **none passed the complete task**. The source-delay decision discard did execute on the phone,
without whole-GOP snapshots. During the last attempt, overflow left `ov=1,lcs=0,vwait=1` and the phone lost
live video: the exact-cursor continuation check was not satisfied. A lagging subscriber is still not
protected across history overflow; complete phone decoding across overflow remains unverified.

Build 7 (`7c702b7`) additionally requires a source frame captured after the last real gesture before a model
call, rejects non-ASCII USB typing, invalidates Legacy pointer position at task start, and explains App Library
navigation. Its final iOS 15 build `41238052355` passed; the downloaded IPA is `build/IPhoneAgent-iOS15-build7-verified.ipa`
with SHA256 `568b3b6c5c073a13bb4d401fd6d43e72889864ec4850b6a4aa08422b5f1e5271`. Follow-up test commit `af68869` models an
actual new image on recovery without weakening the existing assertions, and checks that a recent connection
notification cannot certify an old source image. CI `41238052366` passed, including firmware, Python 3.10/3.12
and **97 simulator tests with zero failures**. The separate iOS build `41238052376` has compiled successfully;
its duplicate simulator job is still running. Build 7 has not been signed or installed; the phone remains on 1.0.6, both current
screens are unavailable, and AllSign's wireless service is offline. Manual mirroring recovery is required.

Later validation supersedes the pending build 7 status above: `41238052376` passed, and the owner reopened
mirroring. Build 7 was signed, installed and launched; authenticated hello reported **1.0.7** at
`2026-10-31T20:34:38.377Z`. Its signed IPA SHA256 is
`43fc3dfa7bab2fc60c9f86314a5f56ff7a4a69b1d3e561b87e47f1fbc7a1d720`. The retained Key/configuration and phone
red-image model check passed again. Historical video caught up to about 0.13 s source age after desktop BLE
was disconnected; newly decoded historical frames were never treated as live.

With the computer only setting up the first Home Screen page, the phone prepared the original task at
`2026-10-31T20:43:25.762Z`. Desktop BLE/probe/Ops were stopped, with the disconnected window starting at
`20:43:28.153Z` for 55 s; only Ops was restored afterward. The phone opened Calendar, used separate
AssistiveTouch/Home taps, and returned Home, but reopened Calendar instead of finishing. It was stopped,
and final telemetry confirmed `running=false,lastStep=stopped`. **The complete independent task still failed.**
Source-frame waiting ran on-device without automatic whole-GOP snapshots. The actor's requests discarded
all earlier visual observations, leaving action coordinates but no memory that Calendar had been seen.

The same caught-up phone decoder subsequently crossed **one history overflow successfully**: `ov:1→2`,
`lcs:0→1`, unchanged IDR time `2448672`, `bo=18`, and unchanged BLE drop count 2. Authenticated native screenshots
before/after were complete with the desktop clock advancing, `frameLive=true`, source age about 0.14 s and
no decode warning. This is stronger evidence than `lcs` alone, but does not validate lagging/cold-client
recovery. After overflow a new desktop decoder cannot start from the remaining P-only history.

Build 8 (`090b239`) retains up to eight prior image-backed model observations (300 characters each), separately
from action feedback. They are labeled historical, the current image remains authoritative, and returning
to an earlier screen must not reset task progress. This does not hardcode Calendar or auto-accept the task.
iOS 15 `41240758313`, modern iOS `41240758258` and CI `41240758290` all passed; both simulator jobs ran **99 tests
with zero failures**. The original IPA SHA256 is `532155f30b16af3087135a64fbfbde37db56d30749327d4a96c3102a5d347b1f`.
The signed phone package is `Signed/ESP32-Agent15-v1.0.8.ipa`, SHA256
`ab9bfa2ac26a3663cef48f950bcc2662f3ce9323ba7d655387af0c5492c83193` (430048 bytes). At signing time the phone
remained on 1.0.7 and the new desktop decoder needed a mirroring restart. The owner subsequently restored
mirroring; build 8 was actually installed and launched, with authenticated hello reporting **1.0.8** at
`2026-10-31T21:04:33.466Z`. The retained model configuration and phone red-image test passed. Historical frames
caught up to about 0.13 s source age before the task began.

**One complete independent Calendar task passed on build 8.** The computer only set up the first Home Screen
page with the Calendar icon visible. The phone confirmed preparation at `21:10:29.756Z`; desktop BLE/probe/Ops
were then shut down for `21:10:32.165Z—21:11:27.166Z` (55.001 s), with only Ops restored afterward. Planning
and the first model request began before full disconnection; all gestures, subsequent model calls and the
normal completion occurred inside the disconnected window. The phone tapped Calendar, AssistiveTouch and
Home, retried Home once after observing the menu still open, saw the desktop and emitted `done` at
**21:10:53.891Z**. Final telemetry was `running=false,lastStep=done`, source age about 0.08 s. There was no
manual stop substituted for completion, no text entry and no calendar-event edit.

The phone's original trace directory `ESP32 Agent 15/traces/20261031-171029` was inspected afterward through
Files: `008.jpg` clearly showed Calendar's day view with the AssistiveTouch menu; `012.jpg` showed the normal
Home Screen. Saved desktop evidence of these inspections consists of Files preview screenshots; the original
JPG/steps.jsonl files remain on the phone and were not exported. This corroborates the gesture/model logs and
live final screenshot. It validates this handset, portrait calibration and starting page once, not arbitrary
apps or starting states. Returning from this evidence inspection to the actual Home Screen was a later
computer-controlled action, separate from the independent acceptance.

During later evidence collection build 8 also crossed one history overflow with native decoding intact:
`ov:2→3,lcs:1→2`, unchanged IDR `1965864`, `bo=18`, BLE drop count 4 unchanged, and final source age about 0.11 s
with no decoder warning. Build 7 and build 8 each now have one caught-up phone overflow example. Cold/lagging
client recovery, long-term power stability and broader task reliability remain unresolved.

The first firmware recovery experiment advertised the reverse event channel at TCP 7013 and attempted to
send a binary-plist `{type:forceKeyFrame}` command without directly closing the mirror connection. BLE `keyframe` queues it;
`keyframe status` reports sent/acked/failed/idr_age separately from the MTU-limited heartbeat. Cold/lagging
stream recovery makes at most three attempts per generation/subscriber, at least 5 s apart, preserving exact
continuation and source-age guards. Event replies are bounded and checked for matching CSeq/full framing;
event rejection/timeout leaves the RTSP control session alive. Session closure is now serialized on the RTSP
task. The protocol idea is supported by [related AirPlay/CarPlay implementation notes](https://github.com/lvalen91/carlink_linux/blob/main/docs/CARPLAY_CAPABILITIES.md#9-control-commands--events-sdk-path-command),
**not yet by this iOS 15 handset**.

Host ASan/UBSan tests, a real-code TCP event integration harness (mock crypto/media/initial handshake), and the
full firmware build passed. OTA returned 0 and the board actually reports `Nov  1 2026 05:39:51`; binary SHA256
`aa73f00a0601362cd520f0e3ad9802d0fb1310a9f48332f923768b2e65629a54`. Low-voltage reset count nevertheless rose
**18→19 during OTA**, so power stability remains unresolved. After deployment the phone remains on 1.0.8 with
the task stopped, USB is healthy, and AirPlay is idle. Keyframe counters are all zero and a request correctly
fails with `no ready event channel`. The owner must restart mirroring once before real event-channel/IDR and
cold/lagging decoder tests can proceed. Neither a queued command nor a 2xx ACK alone establishes recovery.

**The subsequent real-device keyframe trial failed.** After the owner restarted mirroring, the phone had a
complete fresh native image (`frameAge≈0.083 s`) and the board was streaming. One request produced
`sent=1,acked=0,failed=1`, no new IDR, and was followed within about one second by `ap=idle`; it remained idle
at the ten-second check. The board did not reboot and `bo=19` stayed unchanged. There is no raw wire reply
establishing whether the command, encryption/framing, or event-connection closure ended the source session.
Host tests do not model an iPhone's decision to stop its mirror session.

The experiment is now **disabled by default** (`AIRPLAY_EXPERIMENTAL_KEYFRAME=0`): no event listener,
`eventPort=0`, explicit requests return `experimental keyframes disabled`, and automatic recovery cannot send.
`keyframe status` includes `enabled`; enabling the experiment requires a separate developer build. Tests now
cover both the default disabled protocol and the explicit experimental build, without removing original wire
assertions. To reduce current peaks, BLE default TX was separately lowered from 9 to 0 dBm after phone RSSI
measurements around -24..-35 dBm; `ble.tx` reads the controller value. This does not establish electrical root
cause or long-term supply stability. Cold/P-only recovery remains unresolved.

The disabled-event/0 dBm build **is installed**: board version `Nov  1 2026 06:00:25`, SHA256
`65ae568d612bc5c7f8d8ae3383c64c52242bd99589932872a25c8e20ac92a526`, runtime `enabled=false,ble.tx=0` and no TCP
7013 listener. That OTA nevertheless raised `bo:19→20`. Subsequent phone RSSI was around -33..-44 dBm.

A further USB startup guard **was initially built but not installed** (subsequent installation below): wait up to 3 s for USB configuration, then 250 ms
settling before starting RF, with `power status` diagnostics and a bounded hostless fallback. The core OTA
receive-gap timeout was raised from 1 to 10 s. Firmware is 1,535,115 bytes, globals 101,316 bytes, SHA256
`4d51217e24ccfd0073faa53d020bad3eb63eb5760f9c0ffdaf9ba7a4258149e4`. Host sanitizer/wire tests and the full build
passed. Four startup-guard upload attempts failed mid-transfer: three used the earlier `7feb1529…` build
(two normal, diagnostic); only the last Wi-Fi-priority trial included the 10 s timeout/latest hash. Diagnostics showed
peer EOF before the uploader's Broken pipe/timeout. No board error code establishes the cause. Uptime remained
continuous and a direct BLE read confirmed `bo=20`, the old version, and `power status` unsupported. Temporary
radio preference and the OTA window were restored with confirmed `coex balance` / `ota off`. The next step is
a fresh board power cycle before another update, then mirroring only after deployment is confirmed. The phone
remains on 1.0.8 with its task stopped. Keyframe/cold recovery and long-term power stability have not passed.

**The USB startup guard is now actually installed.** After the owner power-cycled the board, the old firmware
reported `bo=21` (previously 20), showing another recorded brownout at startup. The first OTA preparation did
not obtain a valid credential response, so no upload started. After revalidating the control/OTA channel, the
next upload returned 0 and the board read back **`Nov  1 2026 06:03:20`**. The deployed binary is the already
built/tested SHA256 `4d51217e24ccfd0073faa53d020bad3eb63eb5760f9c0ffdaf9ba7a4258149e4`, without code changes.
`power status` now reports **`usb_boot_configured=true,usb_wait_ms=140,ble_tx_dbm=0`**, establishing that the
startup guard runs. USB configuration alone does not establish adequate supply voltage/current.

The update/reboot nevertheless raised `bo:21→22` with `rst=brownout`; there is no voltage trace or precise
reset-stage evidence to identify the electrical cause. A short idle observation (`up≈24→44 s`) kept Wi-Fi/USB
healthy with no further recorded reset, which is not a loaded or long-term power test. `keyframe` remains
disabled, radio preference is balance, OTA is off, and code CI `41247671118` succeeded. The phone is still on
1.0.8 with no task running; Ops is online, but AirPlay is idle and no fresh screenshot is available (409).
The owner must restart mirroring to continue load/recovery tests. Evidence is in
`build/event-recovery/startup-installed.json`; neither automatic keyframe recovery nor stable power has passed.

**Current phone version is now 1.0.10 / build 10.** The owner's mirror restart restored a full fresh desktop
on the LAN decoder, while the phone app was offline. A fresh-image-guided launch restored Ops, but its native
decoder stayed blind after reconnect despite a still-complete GOP. Removing the second BLE central did not
restore the image. One explicitly recorded desktop `stream off`/`stream on` diagnostic recovered native
decoding from the existing IDR; source age fell from ~433 s to ~0.19 s. This was assisted recovery, not an
independent phone recovery pass, and newly decoded history was not accepted as live.

Build 9 moved decoder reset before subscription: the old link-ready reset could erase CONFIG/IDR data that
arrived while the encrypted network read was completing. It added a regression through actual app callbacks
for CONFIG/partial IDR before readiness and IDR completion afterward. All three build 9 workflows passed
(100 simulator tests). Version 1.0.9 was installed, but real logs showed CoreBluetooth restoring an existing
subscribed link without another prefix replay; **that recovery trial failed**. This was not a complete fix.

Build 10 (`614161a3cd242f31e8ce1facf34784f70203b6b0`) also renews an already-notifying video subscription: disable,
wait for its callback, reset the decoder and re-enable, requesting a prefix through a real subscription edge.
Fresh subscriptions reset before enabling too; the later link-ready callback preserves early video. CI
`41250191867` passed 100 tests and the iOS 15 build `41250191850` passed. Modern workflow `41250191840` also
subsequently passed with 100 simulator tests and zero failures; all three workflows are green. Authentication hello confirms
**1.0.10 is installed**. Unsigned IPA SHA256 `a83c0290cdab3a08baadd58bab0f3efc659dcfaf14e9972438cb6435d9467715`,
signed SHA256 `0eac61e782a05eb8e68b6675bee688c406490b6862c2538898699af396fca789`. Configuration/Key persisted;
the phone's official DeepSeek red-image check again passed with `reasoning_chars=0`.

However, the old mirror history overflowed during installation: `ov=1,lcs=1,vwait=1`, IDR age ~1603 s before
launch evidence. A newly started decoder cannot reconstruct the missing prefix. The phone still waits for a
complete IDR; this is **not a build 10 restored-subscription recovery pass**. Nor does board `lcs=1` prove
native phone decoding while that phone was blind. A new mirror session with a complete GOP is required for
the next real-device recovery test. Firmware remains `Nov  1 2026 06:03:20`, `bo=22` did not increase during
this round, experimental events remain disabled, radio preference is balance and OTA is off. Electrical root
cause and long-term power stability remain unresolved. No autonomous action task ran this round; evidence
is in `build/reconnect-recovery/verification.json`. Review was self-review; no independent second reviewer
completion is claimed.

**Build 10 also failed a retained-GOP restart test.** After the owner restarted mirroring and left Agent in
front, native video was complete/fresh (~0.20 s). A switcher force-quit removed its card and took Ops offline.
The mirror and complete GOP remained. Relaunch authenticated as 1.0.10 and reconnected BLE, but native video
still waited for a keyframe after history throughput fell back to the live rate. The desktop BLE central was
removed during catch-up; no desktop stream restart, snapshot or keyframe request assisted this trial.

Build 11 (`c36d5f14ad130507cad5bcd49e52229c20c0b416`) restores Legacy receiving intent from stream mode at process
launch. After command readiness it sends OFF, waits 200 ms, resets references while retaining the known board
clock, then sends ON; a changed/disconnected link aborts the old restart. Modern in-run reconnect uses the
same helper. New regressions cover historical age and a second reconnect during that wait. Board firmware
also advances an atomic epoch on OFF and checks it at live chunk boundaries, cancelling in-flight history
even when ON follows quickly. The existing host suite does not execute this `video_link.cpp` path: sanitizer,
wire tests and a full compile passed, but device cancellation/recovery verification remains pending.

OTA returned 0 for SHA256 `3ee7aa95b9a24b83c0ef690549c478c3094c8f8d69f1535b050c5353061daba6`. The reboot raised
`bo:22→23,rst=brownout`; supply is unresolved. The printed `bv` remains `Nov  1 2026 06:03:20` because the ino
translation unit containing the compile-time timestamp was cached while only video_link.cpp changed. That
string cannot uniquely identify this binary or prove the cancellation path is running. Only upload completion
and management/USB/Wi-Fi recovery are recorded; real cancellation validation is outstanding.

The build 11 iOS 15 IPA is downloaded (SHA256 `3558f3e0ca42532825405ed05719547c253085b0ea15d6f4578158626ff1430f`),
but is **not signed/installed**. The phone remains on 1.0.10 with its task stopped. Mirroring is idle after OTA,
no fresh image is available and the signing service is not running, so the owner must restart mirroring before
fresh-image-guided installation/testing can continue. Experimental events remain disabled, OTA is off and
radio preference is balance. Check `build/reconnect-recovery/verification.json` for CI and evidence updates.

**Build 11 installation and first-launch replay are now verified.** Authenticated hello reports 1.0.11 at
`1793490921.8557048`. Signed IPA: 432,934 bytes, SHA256
`1965287fd1aa6a8519827fe37db4df8314563c763b7eebc4b3e1df6dfab3c887`. Existing configuration/Key survived, and
the phone's official DeepSeek red-image check again returned red / reasoning_chars=0. All three build 11
workflows succeeded (`41253448396`, `41253448449`, `41253448416`); each simulator suite passed 102 tests.

The complete GOP was still retained before launch (`ov=0,vwait=0,gop≈1.92 MB`). Logs show command readiness
at `23:55:23.132Z`, phone-issued OFF/ON and `video forwarding restarted after link readiness` at
`23:55:23.507Z`. The desktop never restarted forwarding or requested snap/keyframe; its second BLE central
was removed during catch-up. Native source age fell from ~511 s through 270/216/147/83 s, with live=false
while stale. First observed live: epoch `1793491055.8851626`, source age **0.3091 s**, ~134.03 s after hello.
A complete native screenshot is saved. This verifies first-launch automatic replay/catch-up, not every
reconnect or execution of the firmware's rapid-toggle cancellation branch.

A later actual switcher force-quit removed the Agent card and took Ops offline without rebooting the board.
Mirrored source updates then became intermittent/stale (board connected/streaming transitions). Guarded
desktop HID cancelled relaunch attempts, so **repeated process-restart recovery remains unverified**.
The owner needs only to open Agent manually to continue this trial while preserving the existing mirror.
No desktop forwarding restart, new mirror session or autonomous task was used during this trial.

The external desktop `agent_runner/lan_probe.py` now retains valid decoder references/cursor on stale source,
while continuing to reject images older than 3 s; corrupt/inconsistent input still resets it. A real H.264
red-prefix → idle → blue-predictive-suffix regression proves same-process/cursor recovery and fresh blue
output. All 20 desktop monitor/pointer tests passed. Restarting the corrected probe did not establish
sustained fresh source, so the mirror stalls are not claimed fixed.

Brownout count remains 23, USB/Wi-Fi are normal, and the experimental channel stays disabled. New BLE
connections actually read `ble.tx=9` and `power status.ble_tx_dbm=9`, despite the earlier 0 dBm readback;
the cause is unverified and the earlier value must not be presented as current. No new power adjustment
or board flash was done in this trial. Supply, long-term stability and missing-IDR cold recovery remain
unresolved. Evidence: `build/reconnect-recovery/verification.json`; self-review only, no independent
second-review completion claimed.

**The pending retained-GOP relaunch trial subsequently passed once.** The owner was instructed only to
reopen Agent, preserving the existing mirror. Authenticated 1.0.11 hello: `1793492052.5599997`. Logs show a new
BLE connection becoming command-ready at `2026-11-01T00:14:13.309Z`, followed by phone-issued OFF/ON and
forwarding restart at `00:14:13.796Z`. This does not exercise the distinct restored-background-subscription
path. Before catch-up the board retained a complete 3,032,905-byte GOP (`bo=23,ov=0,vwait=0`).

Native decoding replayed ~1,639 s-old history with live=false/task stopped. After removing the desktop's
second BLE central, the phone caught up automatically: first observed live at `1793492257.9908884`, source
age **0.06566 s**, **205.43 s** after hello. No desktop stream restart, snap, keyframe request, board flash or
mirror restart assisted this trial. Complete native screenshots and the entire observation series are saved.
After restoring the desktop management central, seven samples over **30.47 s** all stayed live, source ages
**0.0477–0.3869 s**, without decoder errors. Board count stayed 23, original IDR timestamp stayed 0, GOP grew
to 3,256,179 bytes and remained complete. TX still read 9 dBm; events remain disabled and OTA off.

`build/reconnect-recovery/verification.json` now records `build11.restart_trial.passed=true` for this one
force-quit → owner manual relaunch → retained-GOP replay/catch-up, preserving the earlier blocked stage.
First-launch catch-up remains a separate pass. The ~205 s replay delay, missing-IDR cold recovery, background
restoration, broad reconnect reliability, source stalls and supply stability remain unresolved. No autonomous
operation task was run, and this short observation is not a long-duration power/reliability acceptance.

**Historical build 12 deployment state (superseded by the follow-up below).** Authenticated hello reports
1.0.12 at `1793494392.9145372`; telemetry selects `videoTransport=wifi`. The model check still returns
red / reasoning_chars=0 with the existing official DeepSeek configuration. Signed IPA SHA256:
`a1b9aac19be5cbcc95909a7c88dc21062ceef74f885ede365e15c339b80c7b54` (453,761 bytes). Fresh native Wi-Fi
output and recovery latency are **not yet verified**.

Implementation `a0f397b1ec63ab9660bf6d35dceba6a4a0193ef8` validates complete responses, reference prefixes,
cursor continuity and source age before publication. Only each HTTP batch's last decoded picture publishes,
so historical intermediate frames cannot inherit its latest timestamp. Empty responses cannot rejuvenate
old pictures; link/error/cancellation guards remain. Ephemeral private-IP HTTP refuses redirects; monitor/OTA
credentials are hidden in command reply logs. The read-only board monitor now renews the same active
per-boot capability, preventing two centrals from rotating each other's token. Actual repeated renewal
preserved the first credential, and unauthenticated status still returned401.

The first simulator run had one overly strict RGB assertion; the same H.264 fixture now checks strong blue
dominance after platform color conversion, retaining last-only-output/reference/time assertions. Corrective
test commit `7d9371152b12022190e887123c4733fda3f72868`: CI `41258182148`, modern `41258182057`,
Legacy `41258182085` all succeeded, both suites **107 tests, zero failures**. The installed binary came from
the original implementation build; the follow-up changes tests only.

Firmware build and existing sanitizer host suite passed. A tool's 60 s timeout interrupted the first OTA
attempt; background retry returned0. SHA256 `cf7924bd54994283f8118507c01f3cf0dac56ead8efcd697e25c7dbaf63ae0cd`,
verified running marker **fw=wifi-video-power-v1**. TX is now set/read for actual connection handles;
the old DEFAULT readback did not establish active-peer power. Two peers read0 dBm, including seven samples
after desktop reconnect. Brownouts nevertheless rose **23→24** around reboot, so power is unresolved.
Short idle observation (uptime107240→133042ms, bo24 unchanged) is not load or long-term acceptance.

After OTA the board is **mirror idle, empty GOP, waiting IDR**, USB/Wi-Fi/management alive. The phone is
stopped, selected Wi-Fi, frameLive=false; screenshot correctly409. The system must restart screen mirroring
before native Wi-Fi testing can proceed. Desktop HID also has no fresh source and cannot safely perform
that UI sequence. Missing-IDR cold recovery remains unsolved; the failed keyframe experiment stays disabled.
OTA is off, coexistence balanced. No autonomous task was run. Evidence is under
`build/reconnect-recovery/verification.json`; self-review only, no independent review completion claimed.

**Follow-up: native Wi-Fi passed within a bounded scope; cache recovery remains unverified.**
Build 12 passed seven native live samples (source age 0.767–1.066 s), an actual force-quit/relaunch
(1,223,632-byte GOP; 29.482 s hello-to-first-observed-live; source age 0.607 s), and monitor off/on
recovery (24.472 s after reopening; source age 0.905 s). Outage samples remained blind. No desktop
stream restart, snap/keyframe, mirror restart during those trials, or autonomous task was involved.
The prior BLE trial used about 3 MB; these are not controlled speed-ratio measurements.

Build 13 is actually installed (authenticated 1.0.13 hello 1793515032.7389562), after both simulator
suites passed 113 tests. It preserves retryable transport references and adds a validated, checksummed,
64 MB local reference cache, without credentials. The live board must accept the exact epoch/cursor
before local emit=false replay; cache decode alone cannot authorize input. Initial large-history transfer
failed, followed by GOP overflow (ov=1,vwait=1), without a completed cache chain. Removing desktop
BLE/video competition did not recover it. This is a failure boundary, not a cache-recovery pass.

Follow-up commit a39e3c800efdfbb6b488d5a6fe0217e7a91bc16b adds AU-aligned, 128 KiB target history
windows with exact per-window source time, GOP-backed continuation before the live ring, and new-config
epoch/reference invalidation. A single larger AU remains whole. Firmware build and sanitizer host tests
passed. Build 14 also closes an empty-response reauthorization bug found during self-review: only a new
decoded frame may restore the network gate; old callbacks stay rejected while references remain usable.
Diagnostics expose only numeric HTTP/URL error codes. Build 14 is now authenticated as 1.0.14 (hello 1793516620.6908545), and all three workflows
succeeded (both simulator suites 113 tests). Old firmware accepted its saved cursor and started local
reference replay at 07:03:43.516Z, but the source stopped advancing; the next observed decoded frame
was >7 s old, so fresh recovery is not claimed. Later build 13 output had also been observed live
(age 0.659 s), without a controlled cache restart. CI, OTA and native acceptance remain separate
fields in verification.json. A missing IDR without a valid local chain still needs a new
system mirror keyframe; the failed experimental reverse-channel path remains disabled. Bounded-window firmware is deployed (OTA0, verified wifi-video-window-v2 marker, binary SHA256
767467e03c935c31cb73f6975dadf242479e36efaaaf237b7639e07affb9f5c0). A prior upload timed out;
retry with phone video polling paused succeeded and stream mode was restored. Brownout count rose
24→25 at reboot. Actual peer TX0dBm and USB boot wait130ms are confirmed; OTA off, keyframe disabled,
coexistence balanced. The mirror is now idle/empty and needs a system restart before fresh native
window/cache acceptance can continue. Power root cause is unresolved and requires physical evidence. Automatic tasks stayed stopped; no independent reviewer
completion is claimed.

Remote management requires the app to be running. iOS may suspend network activity when the app is not kept
active by the board's BLE connection; an offline status is then expected, not a firmware failure.
