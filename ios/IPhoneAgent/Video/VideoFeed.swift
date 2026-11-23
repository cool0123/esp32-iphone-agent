import AVFoundation
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

/// Latency knobs the operator can tune remotely, so a slower screen does not cost whole seconds per step.
enum Latency {
    static let quietKey = "settleQuiet", mostKey = "settleMost", fpsKey = "boardFPS"
    /// How long the screen must stay unchanged before a step counts as settled (default 0.35 s).
    static var settleQuiet: Double {
        get { UserDefaults.standard.object(forKey: quietKey) as? Double ?? 0.35 }
        set { UserDefaults.standard.set(newValue, forKey: quietKey) }
    }
    /// Upper bound on that wait, so a busy screen still lets the run continue (default 3 s).
    static var settleMost: Double {
        get { UserDefaults.standard.object(forKey: mostKey) as? Double ?? 3 }
        set { UserDefaults.standard.set(newValue, forKey: mostKey) }
    }
    /// Board display refresh request; 0 leaves the board's own setting alone.
    static var boardFPS: Int {
        get { UserDefaults.standard.object(forKey: fpsKey) as? Int ?? 0 }
        set { UserDefaults.standard.set(newValue, forKey: fpsKey) }
    }
}

extension ScreenSource {
    func afterAction(since: Double) async { await settled() }

    /// Wait until the screen stops changing (AirPlay only sends frames on change). Mid-animation frames are big and
    /// can reach us late over BLE, so a gap is only "quiet" once it also covers the last frame's transport lag.
    func settled(quiet: Double = 0.35, least: Double = 0.2, most: Double = 3) async {
        let quietLimit = Latency.settleQuiet, mostLimit = Latency.settleMost
        let started = now()
        try? await Task.sleep(nanoseconds: UInt64(least * 1e9))
        while !Task.isCancelled && now() - updated < quietLimit + lag && now() - started < mostLimit {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// How late the shown frame arrived after the board got it (0 when unknown), capped.
    private var lag: Double { capturedAt > 0 ? min(max(updated - capturedAt, 0), 1) : 0 }

    /// The first frame captured after `since` (received, when capture times are unknown), or nil if none in time.
    func fresh(since: Double, timeout: Double = 0.8) async -> Data? {
        let deadline = now() + timeout
        while (capturedAt > 0 ? capturedAt : updated) <= since {
            if Task.isCancelled || now() > deadline { return nil }
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
    /// A USB (UVC) camera on the phone's dock watching the screen. It replaces the AirPlay stream: the phone never
    /// has to hand out a keyframe, so a dropped chain cannot wedge a run, and the camera keeps working across app
    /// restarts, reboots and every app being operated.
    private(set) var cameraActive = false
    private(set) var cameraDeviceName = ""
    private var cameraSession: AVCaptureSession?
    private let cameraQueue = DispatchQueue(label: "camera.frames")
    /// The phone screen inside the camera image, normalized (x, y, w, h from the top-left, fractions).
    var cameraCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var lastCameraPublish = 0.0
    private let cameraFrames = CameraFrames()
    /// JPEG snapshot URL of a network camera (a small Linux board or Wi-Fi camera looking at the screen).
    /// iOS never exposes a UVC camera on an iPhone, so a URL source is the way to use an external camera here.
    var cameraURL = ""
    private var cameraPoll: Task<Void, Never>?

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
    private var chainFailures = 0  // consecutive unusable responses while holding a resumable cursor
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
        if cameraActive { return frame != nil && capturedAt > 0 && now() - capturedAt < 3 }
        return networkReady && mirroring && frame != nil && !broken && capturedAt > 0 && now() - capturedAt < 3
            && (device?.connected ?? false)
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
        if cameraActive {
            if frame != nil, capturedAt > 0, now() - capturedAt < maxAge { return "camera" }
            if await fresh(since: now() - maxAge, timeout: wait) != nil { return "camera (waited)" }
            throw BlindError(reason: "camera frame is stale")
        }
        if streamOn {
            if mirroring && !broken {
                if allowUnchanged && live { return "live (unchanged)" }
                if frame != nil && capturedAt > 0 && now() - capturedAt < maxAge && live { return "live" }
                // A static screen pauses the iOS encoder. Wiggle it, then use the frame captured after the
                // wiggle went quiet: frames arriving during the model call would invalidate its decision.
                if await wakePausedEncoder(), frame != nil, capturedAt > 0, now() - capturedAt < 2, live {
                    return "live (woke)"
                }
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

    /// iOS stops sending mirror video after a few seconds of a static screen, and the board then reports AirPlay
    /// as connected rather than streaming; waiting for a frame that never comes looks like a dead screen. A small
    /// pointer wiggle — out and back, so the net position is unchanged — gives the encoder something to send.
    /// Returns once the encoder has gone quiet again, so the decision frame stays the latest one while the model
    /// thinks; a frame that arrives mid-decision makes the agent discard its own decision and loop.
    private func wakePausedEncoder() async -> Bool {
        guard let device, device.connected else { return false }
        try? await device.send("move 8 0")
        try? await Task.sleep(nanoseconds: 40_000_000)
        try? await device.send("move -8 0")
        var previous = capturedAt
        let deadline = now() + 2.0
        while now() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if capturedAt == previous { return true }
            previous = capturedAt
        }
        return true
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
        try Task.checkCancellation()
        guard let device, device.connected else { throw DeviceError(message: "board not connected") }
        let link = device.links
        stopWiFi()
        let restart = wifiGeneration
        streamOn = false
        assembler.reset()
        invalidateVideo()
        note = "waiting for a complete keyframe"
        func checkRestart() throws {
            try Task.checkCancellation()
            guard device.connected, device.links == link else {
                throw DeviceError(message: "board link changed during video restart")
            }
            guard wifiGeneration == restart else { throw CancellationError() }
        }
        try await device.send("stream off")
        // The firmware video task polls at 20 ms; let it observe OFF before issuing ON.
        try await Task.sleep(nanoseconds: 200_000_000)
        try checkRestart()
        if let channel = device as? CommandChannel {
            // BLE can be ready before the board has a usable LAN address. Do not pin the session
            // to BLE after one transient monitor startup failure.
            for attempt in 0..<3 {
                if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                try checkRestart()
                do {
                    let reply = try await channel.send("monitor on", timeout: 3)
                    try checkRestart()
                    let endpoint = try VideoEndpoint(reply: reply)
                    startWiFi(endpoint, link: link)
                    return
                } catch {
                    try checkRestart()
                }
            }
            DebugLog.write("Wi-Fi video unavailable after startup retries; using BLE")
        }
        try checkRestart()
        // Discard any BLE chunks already in flight when the board received stream off.
        assembler.reset()
        invalidateVideo()
        note = "waiting for a complete keyframe"
        try await device.send("stream on")
        try checkRestart()
        streamOn = true
        DebugLog.write("video forwarding restarted after link readiness; waiting for live source")
    }

    private func stopWiFi() {
        wifiGeneration += 1
        wifiJob?.cancel(); wifiJob = nil
        wifiSession?.invalidateAndCancel(); wifiSession = nil
        transport = "ble"; networkReady = true; wifiPublishStream = nil; wifiClockOffset = nil
    }

    private struct MonitorRenewalFailed: Error {}

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
                        let next: VideoEndpoint
                        do {
                            let reply: String
                            if let channel = device as? CommandChannel {
                                reply = try await channel.send("monitor on", timeout: 3)
                            } else {
                                reply = try await device.send("monitor on")
                            }
                            next = try VideoEndpoint(reply: reply)
                        } catch {
                            try Task.checkCancellation()
                            // No video bytes were consumed. Keep the exact cursor and decoder references
                            // so a temporary renewal failure cannot become a cold start without an IDR.
                            throw MonitorRenewalFailed()
                        }
                        try Task.checkCancellation()
                        guard self.wifiGeneration == generation, device.connected, device.links == link else { return }
                        if next.base != endpoint.base {
                            cursor = VideoCursor(); saved = nil
                            self.wifiClockOffset = nil
                            self.videoNetworkFailed(invalidChain: true)
                        }
                        endpoint = next
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
                    chainFailures = 0
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    if Task.isCancelled || self.wifiGeneration != generation || !device.connected || device.links != link { return }
                    failures += 1
                    // Only a proven discontinuity costs the decoder its references. A truncated or unusable body,
                    // a timeout or a 503 leaves the cursor and the reference pictures intact, and the next attempt
                    // continues from the same byte offset - that is what keeps a long session alive without iOS
                    // ever sending another IDR.
                    let lost = error is VideoCursorLost
                    let rejected = (error as? VideoHTTPUnavailable).map { (400...499).contains($0.status) } ?? false
                    if lost || rejected { chainFailures = 3 } else if error is VideoChainCorrupt { chainFailures += 1 }
                    self.videoNetworkFailed(invalidChain: lost || rejected)
                    if lost || rejected {
                        cursor = VideoCursor(); saved = nil; chainFailures = 0
                    }
                    if failures == 1 {
                        // Codes/status only: never log URLs, headers, bodies or credentials.
                        let failure: String
                        if let urlError = error as? URLError { failure = "URL error \(urlError.code.rawValue)" }
                        else if let unavailable = error as? VideoHTTPUnavailable { failure = "HTTP \(unavailable.status)" }
                        else if error is MonitorRenewalFailed { failure = "monitor renewal failed" }
                        else if error is VideoChainCorrupt { failure = "unusable video body; retrying the same cursor" }
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
        if cameraActive {
            // The camera keeps delivering frames; a short settle is enough to show the gesture's effect.
            try? await Task.sleep(nanoseconds: 450_000_000)
            _ = try? await currentFrame()
            return
        }
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
                if await newer(than: since, timeout: 1.2) { return }
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
            if Task.isCancelled || now() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    /// The link dropped: the board forgets `stream on`.
    func linkLost() { streamOn = false; resetStream() }
}


// MARK: - External USB camera

extension VideoFeed {
    /// Start the dock camera. Frames are cropped to `cameraCrop` so the model's fractions match the phone screen.
    func startCamera() async throws {
        if cameraActive { return }
        if !cameraURL.isEmpty {
            startNetworkCamera()
            return
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard granted else { throw DeviceError(message: "camera permission denied") }
        }
        // The SDK renames the external device type on iOS 17 (externalUnknown -> external, same raw value),
        // and the old name is unavailable when building with that SDK, so look it up by raw value.
        let external = AVCaptureDevice.DeviceType(rawValue: "AVCaptureDeviceTypeExternalUnknown")
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [external], mediaType: .video, position: .unspecified).devices
        guard let camera = devices.first else { throw DeviceError(message: "no external USB camera found") }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw DeviceError(message: "camera input rejected") }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        cameraFrames.onImage = { [weak self] image in
            Task { @MainActor in self?.publishCamera(image) }
        }
        output.setSampleBufferDelegate(cameraFrames, queue: cameraQueue)
        guard session.canAddOutput(output) else { throw DeviceError(message: "camera output rejected") }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        session.startRunning()
        cameraSession = session
        cameraActive = true
        cameraDeviceName = camera.localizedName
        mirroring = true
        broken = false
        waitingForIDR = false
        note = ""
    }

    func stopCamera() {
        cameraPoll?.cancel(); cameraPoll = nil
        cameraSession?.stopRunning()
        cameraSession = nil
        cameraActive = false
        cameraDeviceName = ""
        lastCameraPublish = 0
        frame = nil; updated = 0; capturedAt = 0
    }

    /// Poll a JPEG snapshot URL ~7 times a second and publish it as the live screen (cropped).
    private func startNetworkCamera() {
        cameraActive = true
        cameraDeviceName = cameraURL
        mirroring = true
        broken = false
        waitingForIDR = false
        note = ""
        cameraPoll?.cancel()
        cameraPoll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let url = self.cameraURL
                if let parsed = URL(string: url) {
                    var request = URLRequest(url: parsed)
                    request.timeoutInterval = 5
                    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                    if let (data, response) = try? await URLSession.shared.data(for: request),
                       let http = response as? HTTPURLResponse, http.statusCode == 200,
                       data.count > 1000, data.first == 0xFF, data.dropFirst().first == 0xD8 {
                        self.publishCameraJPEG(data)
                    }
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        }
    }

    /// Crop a camera JPEG to the configured screen rectangle and publish it.
    private func publishCameraJPEG(_ data: Data) {
        guard cameraActive else { return }
        let stamp = now()
        guard stamp - lastCameraPublish >= 0.1 else { return }
        lastCameraPublish = stamp
        var jpeg = data
        let image = UIImage(data: data)
        if let cg = image?.cgImage {
            let rect = cameraCrop
            if rect.minX > 0.001 || rect.minY > 0.001 || rect.width < 0.999 || rect.height < 0.999 {
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                let r = CGRect(x: rect.minX * w, y: rect.minY * h,
                               width: max(1, rect.width * w), height: max(1, rect.height * h)).integral
                if let cropped = cg.cropping(to: r), let encoded = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.65) {
                    jpeg = encoded
                }
            }
        }
        frame = jpeg
        updated = now()
        capturedAt = updated
        broken = false
        note = ""
        if let size = UIImage(data: jpeg)?.size, size.width > 0, size.height > 0, self.size != size {
            self.size = size
        }
    }

    /// Encode one camera buffer to JPEG (cropped), throttled to the agent's cadence, on the main actor.
    fileprivate func publishCamera(_ image: CGImage) {
        let stamp = now()
        guard stamp - lastCameraPublish >= 0.12 else { return }  // ~8 fps is plenty for the agent
        lastCameraPublish = stamp
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let rect = cameraCrop
        let cropped: CGImage
        if rect.minX <= 0.001 && rect.minY <= 0.001 && rect.width >= 0.999 && rect.height >= 0.999 {
            cropped = image
        } else {
            let r = CGRect(x: rect.minX * width, y: rect.minY * height,
                           width: max(1, rect.width * width), height: max(1, rect.height * height)).integral
            cropped = image.cropping(to: r) ?? image
        }
        guard let jpeg = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.65) else { return }
        frame = jpeg
        updated = now()
        capturedAt = updated
        broken = false
        note = ""
        let size = CGSize(width: cropped.width, height: cropped.height)
        if self.size != size { self.size = size }
    }
}

/// Turns camera sample buffers into CGImages off the main thread. A plain NSObject because
/// AVCaptureVideoDataOutputSampleBufferDelegate inherits NSObjectProtocol.
final class CameraFrames: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onImage: ((CGImage) -> Void)?
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixel)
        guard let image = context.createCGImage(ci, from: ci.extent) else { return }
        onImage?(image)
    }
}
