import Foundation
import UIKit

/// What the agent and the pointer need from the screen (VideoFeed, or a fake in tests). Port of screen.py.
@MainActor protocol ScreenSource: AnyObject {
    var live: Bool { get }
    var frame: Data? { get }
    var updated: Double { get }
    var capturedAt: Double { get }
    var aspect: Double { get }
    /// After a gesture that ended at `since`: wait until the screen shows its result (and fetch it, in snap mode).
    func afterAction(since: Double) async
}

/// How a run gets its frames: the live stream (`stream on`, the default: a frame in under a second), or one
/// snap after each action (`stream off`; waits for the board's whole GOP, often 20-30 s).
enum FrameMode: String {
    case stream, snap
    static let key = "frameModeV2"  // V2: drops the old saved "snap" left by earlier automatic fallbacks
    /// A command timeout switches the current run to snap; not saved, so the next run streams again.
    static var fallback: FrameMode?
    static var current: FrameMode {
        get { fallback ?? FrameMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .stream }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key); fallback = nil }
    }
}

extension ScreenSource {
    func afterAction(since: Double) async { await settled() }

    /// Wait until the screen stops changing (AirPlay only sends frames on change). Mid-animation frames are big and
    /// can reach us late over BLE, so a gap is only "quiet" once it also covers the last frame's transport lag.
    func settled(quiet: Double = 0.5, least: Double = 0.3, most: Double = 4) async {
        let started = now()
        try? await Task.sleep(nanoseconds: UInt64(least * 1e9))
        while now() - updated < quiet + lag && now() - started < most {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// How late the shown frame arrived after the board got it (0 when unknown), capped.
    private var lag: Double { capturedAt > 0 ? min(max(updated - capturedAt, 0), 1) : 0 }

    /// The first frame captured after `since` (received, when capture times are unknown), or nil if none in time.
    func fresh(since: Double, timeout: Double = 0.8) async -> Data? {
        let deadline = now() + timeout
        while (capturedAt > 0 ? capturedAt : updated) <= since {
            if now() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return frame
    }
}

/// The phone's screen, mirrored over AirPlay to the board and forwarded over BLE, as JPEG frames.
@MainActor final class VideoFeed: ObservableObject, ScreenSource {
    @Published private(set) var frame: Data?
    @Published private(set) var size = CGSize.zero
    @Published private(set) var note = ""  // last decoder problem, shown in Diagnostics
    private(set) var updated = 0.0
    /// When the board received the shown frame, in local time (≈; see `boardClock`).
    private(set) var capturedAt = 0.0
    /// A decode error or a lost chunk since the last good frame: the shown frame is stale until the next IDR.
    private(set) var broken = false
    private var clockOffset: Double?  // BLE receive-time upper bound; smallest latency seen
    private var wifiClockOffset: Double?  // HTTP request-start lower bound; greatest conservative bound seen
    var mirroring = false  // board status says ap == streaming
    var metrics: Metrics?
    weak var device: HIDDevice?

    private var assembler = VideoAssembler()
    private let decoder = H264Decoder()
    private(set) var streamID = 0
    private var waitingForIDR = true
    private var wifiJob: Task<Void, Never>?
    private var wifiGeneration = 0
    private var wifiSession: URLSession?
    private(set) var transport = "ble"
    private(set) var networkReady = true
    private var wifiPublishStream: Int?
    private let archive = VideoArchive()

    init() {
        decoder.onFrame = { [weak self] f in DispatchQueue.main.async { self?.publish(f) } }
        decoder.onError = { [weak self] msg, streamID in
            DispatchQueue.main.async { self?.decodeFailed(msg, streamID: streamID) }
        }
    }

    private func invalidateVideo() {
        streamID += 1
        waitingForIDR = true
        broken = true
        frame = nil; updated = 0; capturedAt = 0
        decoder.queue.async { [decoder] in decoder.invalidate() }
    }

    func decodeFailed(_ msg: String, streamID: Int) {
        guard streamID == self.streamID else { return }
        let bg = UIApplication.shared.applicationState == .background
        note = bg ? "\(msg) [in background]" : msg
        metrics?.decodeError(background: bg)
        invalidateVideo()
    }

    var live: Bool {
        networkReady && mirroring && frame != nil && !broken && capturedAt > 0 && now() - capturedAt < 3 && (device?.connected ?? false)
    }

    /// Frame width / height (portrait iPhone as a fallback).
    var aspect: Double { size.width > 0 && size.height > 0 ? size.width / size.height : 9 / 19.5 }

    /// One `video` notify from BoardLink.
    func receive(_ chunk: Data) {
        guard transport == "ble" else { return }
        metrics?.videoBytes(chunk.count)
        let dropsBefore = assembler.drops
        let unit = assembler.add(chunk)
        if assembler.drops > dropsBefore {
            metrics?.videoDrops(assembler.drops - dropsBefore)
            invalidateVideo()
            note = "video data lost; waiting for a complete keyframe"
        }
        guard let unit else { return }
        if unit.config {
            invalidateVideo()
            note = "video restarted; waiting for a complete keyframe"
        }
        if unit.idr { waitingForIDR = false }
        guard unit.config || !waitingForIDR else { return }
        if !unit.snap { boardClock(ms: Int(unit.boardMs)) }  // snap units are resent late: their ages say nothing
        if unit.idr { metrics?.idrSeen() }
        let streamID = streamID
        decoder.queue.async { [decoder] in decoder.decode(unit, streamID: streamID) }
    }

    /// The link (re)connected: chunk numbering starts over.
    func resetStream() {
        stopWiFi()
        assembler.reset(); clockOffset = nil
        invalidateVideo()
        note = "waiting for a complete keyframe"
    }

    /// A board timestamp (status `up`, or a streamed unit) just arrived: keep the smallest offset.
    func boardClock(ms: Int) {
        let offset = now() - Double(ms) / 1000
        clockOffset = min(clockOffset ?? offset, offset)
    }

    /// Show a still frame (demo data).
    func show(_ jpeg: Data, width: Int, height: Int) {
        waitingForIDR = false
        publish(H264Decoder.Frame(jpeg: jpeg, width: width, height: height, decodeMs: 4.2,
                                  unit: AccessUnit(data: Data(), idr: false, config: false, snap: false, boardMs: 0),
                                  streamID: streamID))
    }

    func publish(_ f: H264Decoder.Frame) {
        guard f.streamID == streamID, !waitingForIDR else { return }
        frame = f.jpeg
        updated = now()
        capturedAt = (wifiClockOffset ?? clockOffset).map { Double(f.unit.boardMs) / 1000 + $0 } ?? updated
        broken = false
        if wifiPublishStream == f.streamID { networkReady = true; wifiPublishStream = nil }
        note = ""
        if size.width != CGFloat(f.width) || size.height != CGFloat(f.height) {
            size = CGSize(width: f.width, height: f.height)
        }
        metrics?.frameDecoded(ms: f.decodeMs)
    }

    /// The app asked the board to forward the stream (`stream on`).
    private(set) var streamOn = false

    /// Seconds a snap may take: the buffered GOP over the measured BLE rate, doubled, at least 8 s.
    var snapTimeout: Double {
        let gopBytes = Double(metrics?.board?.gop ?? 0)
        let kbps = max(metrics?.bleKbps ?? 0, metrics?.board?.ble?.kbps ?? 0, 40)
        return max(8, gopBytes * 8 / 1000 / kbps * 2 + 3)
    }

    /// A current frame for the model. A continuous stream must catch up without replaying its history:
    /// a snapshot would reset healthy references and put more old video ahead of the live suffix.
    /// `allowUnchanged` accepts an existing frame only while `live` still certifies its source age.
    /// Snapshots are used only when continuous streaming is off.
    @discardableResult
    func currentFrame(maxAge: Double = 1, wait: Double = 3, allowUnchanged: Bool = false) async throws -> String {
        if streamOn {
            if mirroring && !broken {
                if allowUnchanged && live { return "live (unchanged)" }
                if frame != nil && capturedAt > 0 && now() - capturedAt < maxAge && live { return "live" }
                if await fresh(since: now() - maxAge, timeout: wait) != nil, live { return "live (waited)" }
            }
            throw BlindError(reason: "live screen has not caught up to the present; operation cancelled")
        }
        do {
            try await snap()
        } catch is BoardTimeout {
            DebugLog.write("snap timed out; retrying once with a longer timeout")
            try await snap(timeout: snapTimeout * 1.5)
        }
        if broken || frame == nil || capturedAt <= 0 || now() - capturedAt >= maxAge {
            throw BlindError(reason: "screen has not caught up to the present; operation cancelled")
        }
        return "snap"
    }

    /// Ask the board for the current GOP and wait until it is decoded. Returns the latency in ms.
    @discardableResult
    func snap(timeout: Double? = nil) async throws -> Double {
        guard let device else { throw DeviceError(message: "board not connected") }
        let started = now()
        if let channel = device as? CommandChannel {
            try await channel.send("snap", timeout: timeout ?? snapTimeout)
        } else {
            try await device.send("snap")
        }
        await withCheckedContinuation { c in decoder.queue.async { c.resume() } }  // the GOP is decoded
        try? await Task.sleep(nanoseconds: 30_000_000)  // let the last frame reach the main queue
        let ms = (now() - started) * 1000
        metrics?.snapLatency(ms)
        return ms
    }

    func stream(_ on: Bool) async throws {
        if !on { stopWiFi() }
        else if transport == "wifi" { streamOn = true; return }
        try await device?.send("stream \(on ? "on" : "off")")
        streamOn = on
    }

    /// A new decoder cannot inherit the board's live cursor, including a restored BLE subscription.
    /// Restart continuous forwarding only after the command channel is ready. Preserve the board clock:
    /// a newly decoded historical prefix must keep its original source age.
    func restartStreamAfterLink() async throws {
        guard let device, device.connected else { throw DeviceError(message: "board not connected") }
        let link = device.links
        try await stream(false)
        // The firmware video task polls at 20 ms; let it observe OFF before issuing ON.
        try await Task.sleep(nanoseconds: 200_000_000)
        guard device.connected, device.links == link else { throw DeviceError(message: "board link changed during video restart") }
        if device is CommandChannel {
            do {
                let endpoint = try VideoEndpoint(reply: await device.send("monitor on"))
                guard device.connected, device.links == link else { throw DeviceError(message: "board link changed during video restart") }
                startWiFi(endpoint, link: link)
                return
            } catch {
                guard device.connected, device.links == link else { throw DeviceError(message: "board link changed during video restart") }
                DebugLog.write("Wi-Fi video unavailable; using BLE")
            }
        }
        assembler.reset()
        invalidateVideo()
        note = "waiting for a complete keyframe"
        try await stream(true)
        DebugLog.write("video forwarding restarted after link readiness; waiting for live source")
    }

    private func stopWiFi() {
        wifiGeneration += 1
        wifiJob?.cancel(); wifiJob = nil
        wifiSession?.invalidateAndCancel(); wifiSession = nil
        transport = "ble"; networkReady = true; wifiPublishStream = nil; wifiClockOffset = nil
    }

    private func startWiFi(_ endpoint: VideoEndpoint, link: Int) {
        stopWiFi()
        assembler.reset(); invalidateVideo()
        transport = "wifi"; streamOn = true; networkReady = false
        note = "waiting for a complete keyframe over Wi-Fi"
        let generation = wifiGeneration
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: VideoHTTPDelegate(), delegateQueue: nil)
        wifiSession = session
        DebugLog.write("Wi-Fi video started after link readiness; waiting for live source")
        wifiJob = Task { [weak self] in
            var endpoint = endpoint, cursor = VideoCursor(), renewed = now()
            var saved = await self?.archive.load(host: endpoint.base.absoluteString)
            if let saved { cursor = saved.cursor }
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.wifiGeneration == generation, let device = self.device,
                      device.connected, device.links == link else { return }
                do {
                    if now() - renewed > 600 {
                        endpoint = try VideoEndpoint(reply: await device.send("monitor on"))
                        renewed = now()
                    }
                    let started = now()
                    var request = URLRequest(url: URL(string: endpoint.base.absoluteString + "/gop.h264" + cursor.query)!)
                    request.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    let (bytes, response) = try await session.data(for: request)
                    try Task.checkCancellation()
                    guard self.wifiGeneration == generation, device.connected, device.links == link else { return }
                    guard let response = response as? HTTPURLResponse else { throw DeviceError(message: "invalid video response") }
                    if response.statusCode == 401 {
                        renewed = 0
                        throw VideoHTTPUnavailable(status: 401)
                    }
                    guard response.statusCode == 200 else { throw VideoHTTPUnavailable(status: response.statusCode) }
                    let batch = try cursor.accept(bytes, response: response)
                    // The live board must first accept this boot epoch and exact byte cursor. Only
                    // then may disk references enter the decoder; a board restart sends a new prefix.
                    if let restored = saved, !batch.restarted {
                        DebugLog.write("video: board accepted saved cursor; replaying local references")
                        var replayCursor = VideoCursor()
                        for record in restored.records {
                            let prefix = try replayCursor.accept(record.bytes, response: record.response)
                            self.acceptWiFi(prefix, requestStarted: record.started, emit: false)
                        }
                    }
                    saved = nil
                    self.acceptWiFi(batch, requestStarted: started)
                    let acceptedStream = self.streamID
                    await self.archive.append(.init(host: endpoint.base.absoluteString, started: started,
                                                    response: response, bytes: bytes), restarted: batch.restarted)
                    // Drain this batch before fetching another: bounded queue/memory, final image only.
                    await withCheckedContinuation { c in self.decoder.queue.async { c.resume() } }
                    if self.streamID != acceptedStream { cursor = VideoCursor(); self.networkReady = false }
                    failures = 0
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    if Task.isCancelled || self.wifiGeneration != generation { return }
                    failures += 1
                    self.videoNetworkFailed(invalidChain: !(error is URLError || error is VideoHTTPUnavailable))
                    if !(error is URLError || error is VideoHTTPUnavailable) {
                        cursor = VideoCursor(); saved = nil
                    }
                    if failures == 1 {
                        // Codes/status only: never log URLs, headers, bodies or credentials.
                        let failure: String
                        if let urlError = error as? URLError { failure = "URL error \(urlError.code.rawValue)" }
                        else if let unavailable = error as? VideoHTTPUnavailable { failure = "HTTP \(unavailable.status)" }
                        else { failure = "invalid video chain" }
                        DebugLog.write("Wi-Fi video interrupted (\(failure)); input remains blocked until fresh decoding")
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    func videoNetworkFailed(invalidChain: Bool) {
        // A transport interruption does not consume cursor bytes. Preserve references, but block HID
        // immediately, even if the previously shown frame is less than three seconds old.
        networkReady = false; wifiPublishStream = nil
        note = "Wi-Fi video interrupted; waiting for a verified source"
        if invalidChain { invalidateVideo() }
        else { streamID += 1 }  // reject in-flight output without discarding decoder references
    }

    func acceptWiFi(_ batch: VideoBatch, requestStarted: Double, emit: Bool = true) {
        // Server uptime is sampled AFTER request start. This gives a lower bound on clock offset:
        // larger bounds remove old queue delays without making any capture newer than its source.
        // Keep it separate from BLE's receive-time upper bound. Saved replay uses the same boot clock.
        let offset = requestStarted - Double(batch.boardMs) / 1000
        wifiClockOffset = max(wifiClockOffset ?? offset, offset)
        if batch.restarted { invalidateVideo() }
        if batch.units.contains(where: { $0.idr }) { waitingForIDR = false }
        guard !waitingForIDR else { return }
        let stream = streamID
        if emit && batch.units.contains(where: { !$0.config }) { wifiPublishStream = stream }
        decoder.queue.async { [decoder] in
            for (i, unit) in batch.units.enumerated() {
                decoder.decode(unit, streamID: stream, emit: emit && i == batch.units.count - 1)
            }
        }
    }

    /// Wait for the source to pass the action time. A delayed continuous stream must catch up on its
    /// own; absence of a newer frame does not prove the screen is unchanged and must not queue a GOP replay.
    /// In explicit snap mode, give the UI time to update, then fetch its GOP.
    func afterAction(since: Double) async {
        do {
            if FrameMode.current == .snap {
                try await Task.sleep(nanoseconds: 700_000_000)
                try await currentFrame()
                guard capturedAt < since else { return }
                DebugLog.write(String(format: "frame: snap ends %.1f s before the action; snapping again", since - capturedAt))
                try await Task.sleep(nanoseconds: 500_000_000)
                try await currentFrame()
            } else {
                await settled()
                if await newer(than: since, timeout: 1.5) { return }
                DebugLog.write(broken ? "frame: waiting for a complete keyframe" : "frame: no newer source frame; waiting for live video")
            }
        } catch {
            DebugLog.write("frame after action failed: \(error.localizedDescription)")
        }
        if capturedAt < since { DebugLog.write(String(format: "frame: still %.1f s older than the action", since - capturedAt)) }
    }

    /// Waits until the shown frame was captured after `t`; false on timeout.
    private func newer(than t: Double, timeout: Double) async -> Bool {
        let deadline = now() + timeout
        while capturedAt < t {
            if now() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// The link dropped: the board forgets `stream on`.
    func linkLost() { streamOn = false; resetStream() }
}
