import SwiftUI
import UIKit

enum Mood: String, Codable, Hashable {
    case sleeping, idle, listening, thinking, acting, success, failure, dizzy, content, wink
}

// The legacy target deliberately links neither ActivityKit nor AppIntents.
@main struct LegacyApp: App {
    @StateObject private var model = LegacyModel()
    var body: some Scene { WindowGroup { LegacyView(model: model, board: model.board, settings: model.settings, agent: model.agent) } }
}

@MainActor final class LegacyModel: ObservableObject, OpsTaskApp, OpsModelKeyApp {
    let board = BoardLink()
    let settings = Settings()
    let feed = VideoFeed()
    let pointer: Pointer
    let agent: AgentLoop
    private(set) lazy var ops = OpsController(app: self)
    var opsRecovering: Bool { agent.running && !feed.live }
    var opsNeedsHelp: Bool { false }
    private var receiving = FrameMode.current == .stream
    @Published var boardMessage = ""
    @Published var message = "先连接开发板，再开启屏幕镜像。"
    @Published var task = ""
    private struct RemoteRun {
        let id: String
        let text: String
        let link: Int
        let stream: Int
        let deadline: Double
        var state = "preparing"
        var steps = 0
        var result = ""
    }
    private var remoteRun: RemoteRun?
    private var seenRemoteIDs = Set<String>()
    private var preparing: Task<Void, Never>?
    private var remoteWatchdog: Task<Void, Never>?
    private var remoteStopping = false
    private var startingLocally = false
    init() {
        if settings.baseURL.isEmpty { settings.baseURL = "https://api.deepseek.com" }
        if settings.model.isEmpty, URL(string: settings.baseURL)?.host == "api.deepseek.com" {
            settings.model = "deepseek-flash"
        }
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        pointer = Pointer(device: board.commands, calibrationFile: file.appendingPathComponent("calibration.json"), screen: feed)
        agent = AgentLoop(phone: pointer, screen: feed, actor: nil, planner: nil, trace: TraceStore())
        disableDeepSeekThinking()
        feed.device = board.commands
        board.onVideo = { [weak self] in self?.feed.receive($0) }
        board.onStatus = { [weak self] status in
            guard let self else { return }
            self.feed.mirroring = status.ap == "streaming"
            if let up = status.up { self.feed.boardClock(ms: up) }
            if !self.feed.mirroring || status.usb != "ok" {
                self.cancelOpsTask(reason: "screen mirroring or USB input stopped")
            }
        }
        board.onLinkPreparing = { [weak self] in self?.feed.resetStream() }
        board.onLinkUp = { [weak self] in
            guard let self else { return }
            if receiving {
                Task {
                    do { try await self.feed.restartStreamAfterLink() }
                    catch { self.say("视频重连失败：\(error.localizedDescription)") }
                }
            }
        }
        board.onLinkDown = { [weak self] in
            self?.feed.linkLost()
            self?.cancelOpsTask(reason: "board connection lost")
        }
        board.log = { [weak self] text in self?.boardMessage = text; DebugLog.write(text) }
        board.commands.log = { DebugLog.write($0) }
        // The BLE debug relay is not a release task transport.
        #if DEBUG
        board.commands.onAppCommand = { [weak self] in self?.handleAppCommand($0) }
        #endif
        agent.onStep = { [weak self] in
            guard let last = self?.agent.steps.last else { return }
            self?.say(PyJSON.dumps(last, ascii: false))
        }
        agent.onFinish = { [weak self] in self?.finished() }
        board.commands.authorizeInput = { [weak self] in
            guard let self, let run = self.remoteRun else { return }
            if run.state == "stopping" { throw CancellationError() }
            if run.state == "running" { try self.checkRemoteInput(run) }
        }
        agent.gate = { [weak self] in
            while UIApplication.shared.applicationState != .background {
                try Task.checkCancellation()
                if let self, self.remoteRun?.state == "running" {
                    throw BlindError(reason: "Agent app is in the foreground; remote task stopped")
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if let self, let run = self.remoteRun, run.state == "running" { try self.checkRemoteInput(run) }
        }
        if ops.enabled { ops.start() }
    }
    func say(_ text: String) { message = text; DebugLog.write(text) }
    func tapForCalibration(x: Int, y: Int) async throws {
        // A finished task keeps its record for status queries; only a live run blocks the calibration tap.
        if let run = remoteRun, ["preparing", "running", "stopping"].contains(run.state) {
            throw DeviceError(message: "a task is running")
        }
        guard !agent.running else { throw DeviceError(message: "a task is running") }
        try await pointer.tap(Double(x) / 1000, Double(y) / 1000, aim: false)
    }

    func setCaptureSize(width: Int, height: Int) async throws {
        guard board.connected else { throw DeviceError(message: "board not connected") }
        _ = try await board.commands.send("res \(width) \(height)")
        say("镜像分辨率已设为 \(width)×\(height)。")
    }

    func setFrameMode(_ mode: FrameMode) {
        FrameMode.current = mode
        Task { do { try await receiveMirror(mode == .stream) } catch { say(error.localizedDescription) } }
    }
    func receiveMirror(_ on: Bool = true) async throws {
        receiving = on
        try await feed.stream(on)
    }
    func stopAgent() async {
        if let state = remoteRun?.state, ["preparing", "running", "stopping"].contains(state) {
            cancelOpsTask(reason: "stopped by operator")
            return
        }
        agent.stop()
        try? await Task.sleep(nanoseconds: 100_000_000)
        if board.connected {
            do { try await board.commands.send("release"); pointer.forgetPosition() }
            catch { say("任务已停止，但未确认按键已释放：\(error.localizedDescription)"); return }
        }
        say("任务已停止。")
    }
    #if DEBUG
    // Local development only; never accept remote provisioning in a release build.
    private func handleAppCommand(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let name = parts.first ?? "", rest = parts.count > 1 ? parts[1] : ""
        switch name {
        case "ops":
            guard let data = rest.data(using: .utf8),
                  let p = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let endpoint = p["endpoint"], OpsController.socketURL(endpoint) != nil,
                  let token = p["token"], token.count >= 24, token.count <= 200 else { return }
            ops.enabled = false
            ops.endpoint = endpoint; ops.token = token; ops.enabled = true
            say("远程运维已启用。")
        case "stop": Task { await stopAgent() }
        case "calibrate": calibrate()
        case "run" where !rest.isEmpty && !agent.running:
            task = rest
            Task { await start() }
        default: break
        }
    }
    #endif
    func calibrate() {
        // This handset was measured with axis-separated moves, 0.79 CSS px/HID unit.
        // No guessed calibration is applied to another model.
        var system = utsname(); uname(&system)
        let id = withUnsafePointer(to: &system.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) } }
        guard id == "iPhone9,4" else { message = "这台机型需要单独测量校准。"; return }
        let sx = 414.0 / 0.79, sy = 736.0 / 0.79
        pointer.applyProbe(x: .init(a: 1 / sx, b: 0, rms: 0), y: .init(a: 1 / sy, b: 0, rms: 0), samples: [])
        message = "已载入本机实测校准；更改指针速度后须重新测量。"
    }
    private func disableDeepSeekThinking() {
        guard URL(string: settings.baseURL)?.host?.lowercased() == "api.deepseek.com" else { return }
        var extra = settings.extra
        extra["thinking"] = ["type": "disabled"]
        if let data = try? JSONSerialization.data(withJSONObject: extra, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) { settings.extraBody = text }
    }
    var opsCanRotateModelKey: Bool {
        !agent.running && preparing == nil && !remoteStopping && !startingLocally
    }

    private var remoteBoardReady: Bool {
        UIApplication.shared.isProtectedDataAvailable && board.connected && board.status?.usb == "ok" && feed.live
    }

    var opsTaskTelemetry: [String: Any] {
        let readiness: String
        if agent.running || preparing != nil || remoteStopping || startingLocally { readiness = "busy" }
        else if !UIApplication.shared.isProtectedDataAvailable { readiness = "protected_data_unavailable" }
        else if UIApplication.shared.applicationState != .background { readiness = "agent_in_foreground" }
        else if !board.connected { readiness = "board_disconnected" }
        else if board.status?.usb != "ok" { readiness = "usb_unavailable" }
        else if !feed.live { readiness = "no_live_frame" }
        else if !pointer.calibrated { readiness = "not_calibrated" }
        else { readiness = "ready" }
        var data: [String: Any] = ["readiness": readiness]
        if let run = remoteRun { data["latest"] = remoteStatus(run) }
        return data
    }

    /// What must stay true for an accepted task to keep running: the app is in the background, the operator still
    /// allows tasks, the deadline has not passed and the board link is the one the pointer state belongs to.
    ///
    /// A momentary loss of video or USB input does not cancel the task: the agent waits for a fresh frame before
    /// acting (AgentLoop.waitForScreen) and never acts blind, so pausing is both safer and more useful than
    /// throwing away a half-finished run.
    private func checkRemoteInput(_ run: RemoteRun) throws {
        guard UIApplication.shared.applicationState == .background, ops.enabled, ops.acceptsTasks,
              ProcessInfo.processInfo.systemUptime < run.deadline,
              board.commands.links == run.link else {
            throw BlindError(reason: "remote task lost its board link, permission, or exceeded its deadline")
        }
    }

    private func remoteStatus(_ run: RemoteRun) -> [String: Any] {
        ["task_id": run.id, "state": run.state, "steps": run.state == "running" ? agent.steps.count : run.steps,
         "result": run.result]
    }

    func submitOpsTask(id: String, text: String) throws -> [String: Any] {
        if let run = remoteRun, id == run.id {
            guard text == run.text else { throw DeviceError(message: "task ID already used with different text") }
            return remoteStatus(run)
        }
        guard !seenRemoteIDs.contains(id), seenRemoteIDs.count < 256 else {
            throw DeviceError(message: "task ID already used or session task limit reached")
        }
        guard !agent.running, preparing == nil, !remoteStopping, !startingLocally else {
            throw DeviceError(message: "agent already busy")
        }
        guard UIApplication.shared.applicationState == .background else {
            throw DeviceError(message: "leave the Agent app in the background before submitting a remote task")
        }
        guard remoteBoardReady, pointer.calibrated else {
            throw DeviceError(message: "unlock the phone and check calibration, board and live mirroring")
        }
        let run = RemoteRun(id: id, text: text, link: board.commands.links, stream: feed.streamID,
                            deadline: ProcessInfo.processInfo.systemUptime + 300)
        try checkRemoteInput(run)
        seenRemoteIDs.insert(id)
        remoteRun = run
        remoteWatchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
                guard let self, let current = self.remoteRun, current.id == id,
                      current.state == "preparing" || current.state == "running" else { return }
                do { try self.checkRemoteInput(current) }
                catch {
                    self.cancelOpsTask(reason: error.localizedDescription)
                    return
                }
            }
        }
        preparing = Task { [weak self] in
            guard let self else { return }
            defer { self.preparing = nil }
            do {
                let actor = try await settings.client("actor")
                let planner = try await settings.client("planner")
                try Task.checkCancellation()
                guard remoteRun?.id == id, remoteRun?.state == "preparing", !agent.running else {
                    throw DeviceError(message: "task changed during preparation")
                }
                try checkRemoteInput(run)
                agent.actor = actor
                agent.planner = planner
                pointer.forgetPosition()
                try agent.start(text)
                remoteRun?.state = "running"
            } catch {
                if remoteRun?.state == "preparing" {
                    remoteRun?.state = "failed"
                    remoteRun?.result = String(error.localizedDescription.prefix(300))
                }
                remoteWatchdog?.cancel()
            }
        }
        return remoteStatus(run)
    }

    func opsTaskStatus(id: String) throws -> [String: Any] {
        guard let run = remoteRun, run.id == id else { throw DeviceError(message: "task not found") }
        return remoteStatus(run)
    }

    func stopOpsTask(id: String) async throws -> [String: Any] {
        _ = try opsTaskStatus(id: id)
        cancelOpsTask(reason: "stopped by operator")
        return try opsTaskStatus(id: id)
    }

    func revokeOpsTasks() { cancelOpsTask(reason: "remote tasks disabled by operator") }

    private func cancelOpsTask(reason: String) {
        guard let run = remoteRun, run.state == "preparing" || run.state == "running" else { return }
        remoteWatchdog?.cancel()
        preparing?.cancel()
        if run.state == "running" { agent.stop() }
        remoteRun?.steps = run.state == "running" ? agent.steps.count : 0
        remoteRun?.state = run.state == "running" ? "stopping" : "stopped"
        remoteRun?.result = reason
    }

    private func finished() {
        guard let run = remoteRun, run.state == "running" || run.state == "stopping" else {
            say("任务已结束；请查看最后一步。")
            return
        }
        say("远程任务已结束；请在电脑查看状态。")
        remoteWatchdog?.cancel()
        remoteRun?.steps = agent.steps.count
        if run.state == "stopping" {
            remoteStopping = true
            Task { [weak self] in
                guard let self else { return }
                defer { self.remoteStopping = false }
                if board.connected, board.commands.links == run.link {
                    do { try await board.commands.send("release"); pointer.forgetPosition() }
                    catch { remoteRun?.result += "; HID release not confirmed" }
                } else { remoteRun?.result += "; original board link unavailable" }
                remoteRun?.state = "stopped"
            }
            return
        }
        let last = agent.steps.last
        let action = last?["action"]?.str
        let answer = last?["answer"]?.str?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAnswer = !(answer ?? "").isEmpty
        remoteRun?.state = action == "done" && hasAnswer ? "completed" : action == "stopped" ? "stopped" : "failed"
        remoteRun?.result = String((hasAnswer ? answer ?? "" : last?["reason"]?.str ?? "no verified result").prefix(800))
    }

    func start() async {
        guard !startingLocally, preparing == nil, !remoteStopping, !agent.running else { return }
        startingLocally = true
        defer { startingLocally = false }
        do {
            disableDeepSeekThinking()
            guard pointer.calibrated else { throw DeviceError(message: "先载入本机校准") }
            agent.actor = try await settings.client("actor")
            agent.planner = try await settings.client("planner")
            try await receiveMirror()
            pointer.forgetPosition()
            try agent.start(task)
            say("任务已准备，返回桌面后运行；App 在前台时暂停操作。")
        } catch { say(error.localizedDescription) }
    }
}

struct LegacyView: View {
    @ObservedObject var model: LegacyModel
    @ObservedObject var board: BoardLink
    @ObservedObject var settings: Settings
    @ObservedObject var agent: AgentLoop
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("连接")) {
                    Text(board.connected ? "开发板已连接" : board.lastError.isEmpty ? "尚未连接" : board.lastError)
                    Button("搜索开发板") { board.scan() }
                    ForEach(board.found) { device in Button(device.name) { board.pair(device.id) } }
                    Button("载入本机实测校准") { model.calibrate() }
                    Button("接收镜像") { Task { do { try await model.receiveMirror() } catch { model.say(error.localizedDescription) } } }
                }
                Section(header: Text("视觉模型")) {
                    if URL(string: settings.baseURL)?.host?.lowercased() == "api.deepseek.com" {
                        Text("DeepSeek 推理已关闭")
                    }
                    TextField("API 地址", text: $settings.baseURL).autocapitalization(.none).disableAutocorrection(true)
                    TextField("模型 ID", text: $settings.model).autocapitalization(.none).disableAutocorrection(true)
                    SecureField("API Key", text: $settings.apiKey).autocapitalization(.none).disableAutocorrection(true)
                    Button("测试模型连接") {
                        Task {
                            do { model.say(try await model.ops.checkModel()) }
                            catch { model.say(ModelRequestFailure.message(error)) }
                        }
                    }
                }
                Section(header: Text("任务")) {
                    TextField("让手机做什么", text: $model.task)
                    Button("开始") { Task { await model.start() } }.disabled(agent.running || model.task.isEmpty)
                    Button("停止") { Task { await model.stopAgent() } }
                    Text(model.message)
                    Text(agent.plan)
                    if let step = agent.steps.last { Text(PyJSON.dumps(step, ascii: false)).font(.caption) }
                }
                LegacyOpsSection(ops: model.ops)
                Section(header: Text("蓝牙状态")) { Text(model.boardMessage) }
            }.navigationTitle("ESP32 Agent 15")
        }.navigationViewStyle(.stack)
    }
}
