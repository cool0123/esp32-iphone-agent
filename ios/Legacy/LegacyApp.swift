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

@MainActor final class LegacyModel: ObservableObject {
    let board = BoardLink()
    let settings = Settings()
    let feed = VideoFeed()
    let pointer: Pointer
    let agent: AgentLoop
    @Published var message = "先连接开发板，再开启屏幕镜像。"
    @Published var task = ""
    init() {
        settings.baseURL = "https://api.deepseek.com"
        settings.model = "deepseek-flash"
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        pointer = Pointer(device: board.commands, calibrationFile: file.appendingPathComponent("calibration.json"), screen: feed)
        agent = AgentLoop(phone: pointer, screen: feed, actor: nil, planner: nil, trace: TraceStore())
        disableDeepSeekThinking()
        feed.device = board.commands
        board.onVideo = { [weak self] in self?.feed.receive($0) }
        board.onStatus = { [weak self] in self?.feed.mirroring = $0.ap == "streaming"; if let up = $0.up { self?.feed.boardClock(ms: up) } }
        board.onLinkUp = { [weak self] in self?.feed.resetStream() }
        board.onLinkDown = { [weak self] in self?.feed.linkLost() }
        board.log = { [weak self] in self?.message = $0 }
        agent.gate = {
            while UIApplication.shared.applicationState == .active {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
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
    func start() async {
        do {
            disableDeepSeekThinking()
            guard pointer.calibrated else { throw DeviceError(message: "先载入本机校准") }
            agent.actor = try await settings.client("actor")
            agent.planner = try await settings.client("planner")
            try await feed.stream(true)
            try agent.start(task)
            message = "任务已准备，请手动返回桌面；App 在前台时暂停操作。"
        } catch { message = error.localizedDescription }
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
                    Button("接收镜像") { Task { do { try await model.feed.stream(true) } catch { model.message = error.localizedDescription } } }
                }
                Section(header: Text("视觉模型")) {
                    if URL(string: settings.baseURL)?.host?.lowercased() == "api.deepseek.com" {
                        Text("DeepSeek 推理已关闭")
                    }
                    TextField("API 地址", text: $settings.baseURL).autocapitalization(.none).disableAutocorrection(true)
                    TextField("模型 ID", text: $settings.model).autocapitalization(.none).disableAutocorrection(true)
                    SecureField("API Key", text: $settings.apiKey)
                }
                Section(header: Text("任务")) {
                    TextField("让手机做什么", text: $model.task)
                    Button("开始") { Task { await model.start() } }.disabled(agent.running || model.task.isEmpty)
                    Button("停止") { agent.stop() }
                    Text(model.message)
                    Text(agent.plan)
                }
            }.navigationTitle("ESP32 Agent 15")
        }.navigationViewStyle(.stack)
    }
}
