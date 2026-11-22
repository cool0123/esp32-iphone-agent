import Foundation
import UIKit

/// Shared by the full app and the iOS 15 app; no newer UI/framework dependency.
@MainActor protocol OpsApp: AnyObject {
    var settings: Settings { get }
    var board: BoardLink { get }
    var feed: VideoFeed { get }
    var agent: AgentLoop { get }
    var opsRecovering: Bool { get }
    var opsNeedsHelp: Bool { get }
    func setFrameMode(_ mode: FrameMode)
    func say(_ text: String)
    func stopAgent() async
    /// Mirrored capture size, so the operator can trade frame size against how readable labels are.
    func setCaptureSize(width: Int, height: Int) async throws
    /// One operator-specified tap in grid units, used to calibrate and verify on-screen geometry.
    func tapForCalibration(x: Int, y: Int) async throws
    /// Where the pointer actually ended up after a requested move, for mapping input onto pixels.
    func measurePointer(x: Int, y: Int) async throws -> [String: Any]
    /// Re-solve the pointer span from measurements, so taps stop inheriting a stale factory constant.
    func calibratePointer() async throws -> [String: Any]
}

extension OpsApp {
    func setCaptureSize(width: Int, height: Int) async throws {
        throw DeviceError(message: "capture size is not adjustable on this build")
    }

    func tapForCalibration(x: Int, y: Int) async throws {
        throw DeviceError(message: "calibration taps are not supported on this build")
    }

    func measurePointer(x: Int, y: Int) async throws -> [String: Any] {
        throw DeviceError(message: "pointer measurement is not supported on this build")
    }

    func calibratePointer() async throws -> [String: Any] {
        throw DeviceError(message: "pointer calibration is not supported on this build")
    }
}

/// Optional task capability; the modern App does not advertise or accept this protocol yet.
@MainActor protocol OpsTaskApp: OpsApp {
    func submitOpsTask(id: String, text: String) throws -> [String: Any]
    func opsTaskStatus(id: String) throws -> [String: Any]
    func stopOpsTask(id: String) async throws -> [String: Any]
    func revokeOpsTasks()
    var opsTaskTelemetry: [String: Any] { get }
}

/// Optional: exposes the pointer calibration state for diagnostics (never coordinates of user content).
@MainActor protocol OpsPointerState: OpsApp {
    var pointerState: [String: Any] { get }
}

/// Only the Legacy target opts into model-key rotation (separate from task authorization).
@MainActor protocol OpsModelKeyApp: OpsApp {
    var opsCanRotateModelKey: Bool { get }
}

struct OpsModelKeyRequest {
    let key: String

    static func endpoint(_ raw: String) -> String? {
        guard (1...512).contains(raw.utf8.count), raw.utf8.allSatisfy({ (33...126).contains($0) }),
              !raw.contains("\\"), var c = URLComponents(string: raw), c.scheme?.lowercased() == "https",
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil,
              c.query == nil, c.fragment == nil, (1...65535).contains(c.port ?? 443) else { return nil }
        c.scheme = "https"
        c.host = host.lowercased()
        if c.port == 443 { c.port = nil }
        while c.percentEncodedPath.hasSuffix("/") { c.percentEncodedPath.removeLast() }
        return c.string
    }

    init(_ params: [String: Any], currentEndpoint: String) throws {
        guard Set(params.keys) == ["baseURL", "apiKey"], let provided = params["baseURL"] as? String,
              let key = params["apiKey"] as? String, (8...2048).contains(key.utf8.count),
              key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DeviceError(message: "invalid key rotation request")
        }
        guard let expected = Self.endpoint(provided), expected == Self.endpoint(currentEndpoint) else {
            throw DeviceError(message: "provider endpoint mismatch")
        }
        self.key = key
    }
}

struct OpsTaskRequest {
    let id: String
    let text: String?

    init(_ params: [String: Any], submit: Bool) throws {
        let keys: Set<String> = submit ? ["task_id", "task"] : ["task_id"]
        guard Set(params.keys) == keys, let id = params["task_id"] as? String,
              id.utf8.count == 32, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw DeviceError(message: "invalid task request")
        }
        self.id = id
        if submit {
            guard let value = (params["task"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  (1...800).contains(value.unicodeScalars.count) else { throw DeviceError(message: "invalid task text") }
            text = value
        } else { text = nil }
    }
}

#if !LEGACY_IOS
extension AppModel: OpsApp {
    var opsRecovering: Bool { recovering != nil }
    var opsNeedsHelp: Bool { help != nil }
}
#endif

/// Remote-management config whitelist. Model credentials and the management token are never included.
@MainActor enum OpsConfig {
    static let keys: Set<String> = ["baseURL", "model", "plannerModel", "actorModel", "tokenParam", "extraBody",
                                    "agentName", "frameMode", "captureSize"]

    static func get(_ app: any OpsApp) -> [String: Any] { get(app.settings, frameMode: FrameMode.current) }

    static func publicBaseURL(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return "" }
        c.user = nil; c.password = nil; c.query = nil; c.fragment = nil
        return c.string ?? ""
    }

    static func get(_ s: Settings, frameMode: FrameMode) -> [String: Any] {
        ["baseURL": publicBaseURL(s.baseURL), "model": s.model, "plannerModel": s.plannerModel, "actorModel": s.actorModel,
         "tokenParam": s.tokenParam, "extraBody": s.extraBody, "agentName": s.agentName,
         "frameMode": frameMode.rawValue, "hasAPIKey": !s.apiKey.isEmpty,
         "configurationRevision": s.configurationRevision]
    }

    static func validated(_ params: [String: Any]) throws -> [String: String] {
        guard Set(params.keys).isSubset(of: keys) else { throw DeviceError(message: "unsupported remote config key") }
        var patch: [String: String] = [:]
        for (key, raw) in params {
            guard let value = raw as? String, value.count <= 4096 else { throw DeviceError(message: "invalid \(key)") }
            switch key {
            case "baseURL":
                if !value.isEmpty {
                    guard let url = URL(string: value), let host = url.host, !host.isEmpty,
                          url.user == nil, url.password == nil,
                          ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        throw DeviceError(message: "baseURL must be an HTTP(S) URL")
                    }
                }
            case "frameMode":
                guard ["stream", "snap"].contains(value) else { throw DeviceError(message: "invalid frameMode") }
            case "captureSize":
                guard let size = Self.captureSize(value) else {
                    throw DeviceError(message: "captureSize must be WIDTHxHEIGHT between 160 and 1920/2560")
                }
            case "tokenParam":
                guard !value.isEmpty, value.count <= 40 else { throw DeviceError(message: "invalid tokenParam") }
            case "extraBody":
                guard let obj = try? JSONSerialization.jsonObject(with: Data(value.utf8)), obj is [String: Any] else {
                    throw DeviceError(message: "extraBody must be a JSON object")
                }
            case "model", "plannerModel", "actorModel":
                guard value.count <= 200 else { throw DeviceError(message: "\(key) is too long") }
            case "agentName":
                guard value.count <= 80 else { throw DeviceError(message: "agentName is too long") }
            default: break
            }
            patch[key] = value
        }
        return patch
    }

    /// "WIDTHxHEIGHT" for the mirrored capture, bounded like the firmware's own `res` command.
    static func captureSize(_ value: String) -> (Int, Int)? {
        let parts = value.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
              (160...1920).contains(w), (160...2560).contains(h) else { return nil }
        return (w, h)
    }

    static func apply(_ params: [String: Any], to app: any OpsApp) async throws -> [String: Any] {
        let patch = try validated(params)
        let s = app.settings
        if let v = patch["baseURL"] { s.baseURL = v }
        if let v = patch["model"] { s.model = v }
        if let v = patch["plannerModel"] { s.plannerModel = v }
        if let v = patch["actorModel"] { s.actorModel = v }
        if let v = patch["tokenParam"] { s.tokenParam = v }
        if let v = patch["extraBody"] { s.extraBody = v }
        if let v = patch["agentName"] { s.agentName = v }
        if let v = patch["frameMode"] { app.setFrameMode(FrameMode(rawValue: v) ?? .stream) }
        if let v = patch["captureSize"], let size = Self.captureSize(v) {
            try await app.setCaptureSize(width: size.0, height: size.1)
        }
        app.say("remote config updated: " + patch.keys.sorted().joined(separator: ", "))
        return get(app)
    }
}

/// Outbound remote-operations channel. The phone connects to the service; no inbound listener is needed.
@MainActor final class OpsController: ObservableObject {
    @Published var endpoint: String { didSet {
        defaults.set(endpoint, forKey: "opsEndpoint")
        if endpoint != oldValue { managementIdentityChanged() }
    } }
    @Published var token: String { didSet {
        Keychain.set(token, for: "ops-device-token")
        if token != oldValue { managementIdentityChanged() }
    } }
    @Published var enabled: Bool { didSet {
        defaults.set(enabled, forKey: "opsEnabled")
        if enabled != oldValue { enabled ? start() : stop() }
    } }
    @Published var acceptsTasks: Bool { didSet {
        defaults.set(acceptsTasks, forKey: "opsTasksEnabled")
        if oldValue && !acceptsTasks { (app as? any OpsTaskApp)?.revokeOpsTasks() }
    } }
    @Published var allowsKeyRotation: Bool { didSet { defaults.set(allowsKeyRotation, forKey: "opsKeyRotationEnabled") } }
    var secureEndpoint: Bool { Self.socketURL(endpoint)?.scheme == "wss" }

    /// Where rotation may travel. WSS always; plain WS only to a private IPv4 literal, so an operator
    /// who enables the dedicated rotation switch can hand this phone a key without first installing a
    /// CA profile. Nothing else on the management connection gains from this: the switch is separate
    /// from task submission, and the service still binds administration to loopback.
    static func privateIPv4Host(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard parts.count == 4, host == parts.map(String.init).joined(separator: ".") else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    var rotateAllowedTransport: Bool {
        guard let url = Self.socketURL(endpoint), let host = url.host else { return false }
        return url.scheme == "wss" || (url.scheme == "ws" && Self.privateIPv4Host(host))
    }
    @Published private(set) var state = "Off"
    let deviceID: String

    private weak var app: (any OpsApp)?
    private let defaults: UserDefaults
    private let session = URLSession(configuration: .ephemeral, delegate: NoHTTPRedirects(), delegateQueue: nil)
    private var socket: URLSessionWebSocketTask?
    private var job: Task<Void, Never>?
    private var telemetryJob: Task<Void, Never>?
    private var modelCheckJob: Task<Void, Never>?
    private var checkingModel = false
    private let sendLock = AsyncLock()
    private var generation = 0

    init(app: any OpsApp, defaults: UserDefaults = .standard) {
        self.app = app
        self.defaults = defaults
        endpoint = defaults.string(forKey: "opsEndpoint") ?? ""
        token = Keychain.get("ops-device-token") ?? ""
        enabled = defaults.bool(forKey: "opsEnabled")
        acceptsTasks = defaults.bool(forKey: "opsTasksEnabled")
        allowsKeyRotation = defaults.bool(forKey: "opsKeyRotationEnabled")
        deviceID = defaults.string(forKey: "opsDeviceID") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "opsDeviceID")
    }

    private static func localTestHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(h) || h.hasSuffix(".local") { return true }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 169 && parts[1] == 254) || (parts[0] == 172 && (16...31).contains(parts[1]))
    }

    static func socketURL(_ endpoint: String) -> URL? {
        guard var c = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = c.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = c.host, !host.isEmpty, c.user == nil, c.password == nil else { return nil }
        if scheme == "http" && !localTestHost(host) { return nil }
        c.scheme = scheme == "https" ? "wss" : "ws"
        c.path = (c.path.hasSuffix("/") ? c.path : c.path + "/") + "ws/device"
        c.query = nil
        c.fragment = nil
        return c.url
    }

    private func managementIdentityChanged() {
        acceptsTasks = false
        allowsKeyRotation = false
        closeConnection()
        if enabled { state = "Reconnect to apply the management settings" }
    }

    func start() {
        closeConnection()
        guard enabled, let app else { return }
        guard let url = Self.socketURL(endpoint), !token.isEmpty else {
            state = "Set a management URL and device token"
            return
        }
        generation += 1
        let gen = generation
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        state = "Connecting"
        job = Task { [weak self] in await self?.run(socket, app: app, generation: gen) }
    }

    private func stop() {
        (app as? any OpsTaskApp)?.revokeOpsTasks()
        closeConnection()
    }

    // Restarting just the transport must not interrupt a phone-local task.
    private func closeConnection() {
        generation += 1
        job?.cancel(); telemetryJob?.cancel(); modelCheckJob?.cancel()
        job = nil; telemetryJob = nil; modelCheckJob = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        state = "Off"
    }

    private func run(_ socket: URLSessionWebSocketTask, app: any OpsApp, generation gen: Int) async {
        do {
            guard !Task.isCancelled, gen == generation else { return }
            socket.resume()
            var hello: [String: Any] = ["type": "hello", "device": deviceID, "app": appVersion()]
            if app is any OpsTaskApp { hello["taskProtocol"] = "legacy-task-v1" }
            if app is any OpsModelKeyApp, rotateAllowedTransport {
                hello["keyProtocol"] = "model-key-v1"
            }
            try await send(hello, on: socket)
            guard !Task.isCancelled, gen == generation else { return }
            state = "Connected"
            telemetryJob = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard let self, !Task.isCancelled, self.generation == gen else { break }
                    do { try await self.sendTelemetry(on: socket) }
                    catch {
                        guard !Task.isCancelled, self.generation == gen else { break }
                        socket.cancel(with: .goingAway, reason: nil)
                        break
                    }
                }
            }
            try await sendTelemetry(on: socket)
            while !Task.isCancelled {
                let message = try await socket.receive()
                let data: Data?
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: data = nil
                }
                guard gen == generation, !Task.isCancelled,
                      let data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if object["type"] as? String == "command", object["name"] as? String == "model.check" {
                    if modelCheckJob == nil {
                        modelCheckJob = Task { [weak self] in
                            guard let self else { return }
                            await self.handle(object, app: app, socket: socket)
                            if self.generation == gen { self.modelCheckJob = nil }
                        }
                    } else if let id = object["id"] as? String {
                        try await send(["type": "result", "id": id, "ok": false,
                                        "error": "model check already running"], on: socket)
                    }
                    continue
                }
                if object["type"] as? String == "command", object["name"] as? String == "agent.stop" {
                    modelCheckJob?.cancel()
                }
                await handle(object, app: app, socket: socket)
            }
        } catch {
            guard !Task.isCancelled, enabled, gen == generation else { return }
            telemetryJob?.cancel()
            modelCheckJob?.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            self.socket = nil
            state = "Reconnecting in 5 s"
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled, enabled, gen == generation { start() }
        }
    }

    func checkModel() async throws -> String {
        guard let app else { throw DeviceError(message: "app unavailable") }
        guard !checkingModel else { throw DeviceError(message: "model check already running") }
        checkingModel = true
        defer { checkingModel = false }
        let client = try await app.settings.client("actor")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        }.jpegData(compressionQuality: 0.8)
        let reply = try await client.chat(system: "Name the dominant color. Reply with one English word.",
                                          text: "What color is this image?", image: image, maxTokens: 100, temperature: 0)
        try ModelConnectionCheck.validate(reply)
        return "model=\(client.model), image=red, reasoning_chars=\(reply.reasoningChars)"
    }

    private func appVersion() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    private func telemetry() -> [String: Any] {
        guard let app else { return [:] }
        var board: [String: Any] = [:]
        if let status = app.board.status, let data = try? JSONEncoder().encode(status),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { board = object }
        let age = app.feed.capturedAt > 0 ? max(0, now() - app.feed.capturedAt) : -1
        var payload: [String: Any] = [
            "type": "telemetry", "device": deviceID, "at": now(), "state": state, "version": appVersion(),
            "board": board,
            "app": ["connected": app.board.connected, "mirroring": app.feed.mirroring, "frameAge": age,
                    "running": app.agent.running, "task": app.agent.task, "steps": app.agent.steps.count,
                    "recovering": app.opsRecovering, "needsHelp": app.opsNeedsHelp,
                    "frameLive": app.feed.live, "decoderNote": app.feed.note, "videoTransport": app.feed.transport,
                    "plan": app.agent.plan, "lastStep": app.agent.steps.last.map { PyJSON.dumps($0, ascii: false) } ?? ""]]
        if let pointer = (app as? any OpsPointerState)?.pointerState {
            payload["pointer"] = pointer
        }
        if let tasks = app as? any OpsTaskApp {
            payload["taskControl"] = ["enabled": enabled && acceptsTasks, "phone": tasks.opsTaskTelemetry] as [String: Any]
        }
        return payload
    }

    private func sendTelemetry(on socket: URLSessionWebSocketTask) async throws {
        try await send(telemetry(), on: socket)
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var text = String(decoding: data, as: UTF8.self)
        for secret in [app?.settings.apiKey ?? "", token] where secret.count >= 6 {
            text = text.replacingOccurrences(of: secret, with: "[redacted]")
        }
        await sendLock.lock()
        defer { sendLock.unlock() }
        guard self.socket === socket, !Task.isCancelled else { throw CancellationError() }
        try await socket.send(.string(text))
    }

    private func handle(_ message: [String: Any], app: any OpsApp, socket: URLSessionWebSocketTask) async {
        guard self.socket === socket, !Task.isCancelled, message["type"] as? String == "command",
              let id = message["id"] as? String, let name = message["name"] as? String else { return }
        do {
            let params = message["params"] as? [String: Any] ?? [:]
            let data: [String: Any]
            switch name {
            case "model.key.rotate":
                guard enabled, allowsKeyRotation, rotateAllowedTransport, self.socket === socket,
                      let target = app as? any OpsModelKeyApp else {
                    throw DeviceError(message: "rotation disabled")
                }
                guard target.opsCanRotateModelKey, modelCheckJob == nil, !checkingModel, !Task.isCancelled,
                      UIApplication.shared.isProtectedDataAvailable else {
                    throw DeviceError(message: "app busy or phone locked")
                }
                let request = try OpsModelKeyRequest(params, currentEndpoint: app.settings.baseURL)
                try app.settings.rotateModelKey(request.key)
                data = ["updated": true]
            case "task.submit", "task.status", "task.stop":
                guard let tasks = app as? any OpsTaskApp else { throw DeviceError(message: "remote tasks unsupported") }
                let request = try OpsTaskRequest(params, submit: name == "task.submit")
                if name == "task.submit", let text = request.text {
                    guard acceptsTasks, enabled else { throw DeviceError(message: "remote tasks are disabled on the phone") }
                    data = try tasks.submitOpsTask(id: request.id, text: text)
                } else if name == "task.stop" {
                    data = try await tasks.stopOpsTask(id: request.id)
                } else { data = try tasks.opsTaskStatus(id: request.id) }
            case "status": data = telemetry()
            case "config.get": data = OpsConfig.get(app)
            case "config.set": data = try await OpsConfig.apply(params, to: app)
            case "logs.get": data = ["lines": DebugLog.tail(min(params["lines"] as? Int ?? 100, 200))]
            case "snapshot":
                guard app.feed.live, let jpeg = app.feed.frame else { throw DeviceError(message: "no fresh screenshot available") }
                data = ["jpeg": jpeg.base64EncodedString(), "capturedAt": app.feed.capturedAt, "live": app.feed.live]
            case "model.check": data = ["result": try await checkModel()]
            case "pointer.calibrate":
                guard !app.agent.running, UIApplication.shared.isProtectedDataAvailable, app.feed.live else {
                    throw DeviceError(message: "pointer calibration needs an idle app and a live frame")
                }
                data = try await app.calibratePointer()
            case "pointer.measure":
                guard let params = message["params"] as? [String: Any],
                      let x = params["x"] as? Int, let y = params["y"] as? Int,
                      (0...1000).contains(x), (0...1000).contains(y) else {
                    throw DeviceError(message: "invalid measurement point")
                }
                guard !app.agent.running, UIApplication.shared.isProtectedDataAvailable, app.feed.live else {
                    throw DeviceError(message: "pointer measurement needs an idle app and a live frame")
                }
                data = try await app.measurePointer(x: x, y: y)
            case "cal.tap":
                // Only a deliberate calibration step: the app must be idle, unlocked and showing a live frame, so a
                // stray coordinate cannot move the phone without an observed screen.
                guard let params = message["params"] as? [String: Any],
                      let x = params["x"] as? Int, let y = params["y"] as? Int,
                      (0...1000).contains(x), (0...1000).contains(y) else {
                    throw DeviceError(message: "invalid calibration point")
                }
                guard !app.agent.running, UIApplication.shared.isProtectedDataAvailable, app.feed.live else {
                    throw DeviceError(message: "calibration tap needs an idle app and a live frame")
                }
                try await app.tapForCalibration(x: x, y: y)
                data = ["tapped": ["x": x, "y": y]]
            case "agent.stop":
                await app.stopAgent()
                data = ["stopped": true]
            default: throw DeviceError(message: "unsupported remote command")
            }
            try await send(["type": "result", "id": id, "ok": true, "data": data], on: socket)
        } catch {
            try? await send(["type": "result", "id": id, "ok": false,
                             "error": String(error.localizedDescription.prefix(300))], on: socket)
        }
    }
}
