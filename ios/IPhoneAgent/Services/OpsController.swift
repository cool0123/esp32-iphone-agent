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
                                    "agentName", "frameMode"]

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

    static func apply(_ params: [String: Any], to app: any OpsApp) throws -> [String: Any] {
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
        app.say("remote config updated: " + patch.keys.sorted().joined(separator: ", "))
        return get(app)
    }
}

/// Outbound remote-operations channel. The phone connects to the service; no inbound listener is needed.
@MainActor final class OpsController: ObservableObject {
    @Published var endpoint: String { didSet { defaults.set(endpoint, forKey: "opsEndpoint") } }
    @Published var token: String { didSet { Keychain.set(token, for: "ops-device-token") } }
    @Published var enabled: Bool { didSet {
        defaults.set(enabled, forKey: "opsEnabled")
        enabled ? start() : stop()
    } }
    @Published private(set) var state = "Off"
    let deviceID: String

    private weak var app: (any OpsApp)?
    private let defaults: UserDefaults
    private let session: URLSession = .shared
    private var socket: URLSessionWebSocketTask?
    private var job: Task<Void, Never>?
    private var telemetryJob: Task<Void, Never>?
    private let sendLock = AsyncLock()
    private var generation = 0

    init(app: any OpsApp, defaults: UserDefaults = .standard) {
        self.app = app
        self.defaults = defaults
        endpoint = defaults.string(forKey: "opsEndpoint") ?? ""
        token = Keychain.get("ops-device-token") ?? ""
        enabled = defaults.bool(forKey: "opsEnabled")
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

    func start() {
        stop()
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

    func stop() {
        generation += 1
        job?.cancel(); telemetryJob?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        state = "Off"
    }

    private func run(_ socket: URLSessionWebSocketTask, app: any OpsApp, generation gen: Int) async {
        do {
            socket.resume()
            state = "Connected"
            try await send(["type": "hello", "device": deviceID, "app": appVersion()], on: socket)
            telemetryJob = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { break }
                    try? await self?.sendTelemetry(on: socket)
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
                guard let data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                await handle(object, app: app, socket: socket)
            }
        } catch {
            guard !Task.isCancelled, enabled, gen == generation else { return }
            telemetryJob?.cancel()
            state = "Reconnecting in 5 s"
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled, enabled, gen == generation { start() }
        }
    }

    func checkModel() async throws -> String {
        guard let app else { throw DeviceError(message: "app unavailable") }
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
        return ["type": "telemetry", "device": deviceID, "at": now(), "state": state,
                "board": board,
                "app": ["connected": app.board.connected, "mirroring": app.feed.mirroring, "frameAge": age,
                        "running": app.agent.running, "task": app.agent.task, "steps": app.agent.steps.count,
                        "recovering": app.opsRecovering, "needsHelp": app.opsNeedsHelp,
                        "frameLive": app.feed.live, "decoderNote": app.feed.note,
                        "plan": app.agent.plan, "lastStep": app.agent.steps.last.map { PyJSON.dumps($0, ascii: false) } ?? ""]]
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
        try await socket.send(.string(text))
    }

    private func handle(_ message: [String: Any], app: any OpsApp, socket: URLSessionWebSocketTask) async {
        guard message["type"] as? String == "command", let id = message["id"] as? String,
              let name = message["name"] as? String else { return }
        do {
            let params = message["params"] as? [String: Any] ?? [:]
            let data: [String: Any]
            switch name {
            case "status": data = telemetry()
            case "config.get": data = OpsConfig.get(app)
            case "config.set": data = try OpsConfig.apply(params, to: app)
            case "logs.get": data = ["lines": DebugLog.tail(min(params["lines"] as? Int ?? 100, 200))]
            case "snapshot":
                guard app.feed.live, let jpeg = app.feed.frame else { throw DeviceError(message: "no fresh screenshot available") }
                data = ["jpeg": jpeg.base64EncodedString(), "capturedAt": app.feed.capturedAt, "live": app.feed.live]
            case "model.check": data = ["result": try await checkModel()]
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
