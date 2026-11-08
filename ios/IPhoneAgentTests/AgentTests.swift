import XCTest
@testable import IPhoneAgent

/// Port of server/tests/test_agent.py.
@MainActor final class AgentTests: XCTestCase {
    func testPlannerTimeoutRetriesOnceAndChecksGateAgain() async throws {
        let model = TimeoutModel(failures: 1)
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var gates = 0
        var retryShown = false
        agent.gate = { gates += 1 }
        agent.onDoing = { if case .retrying = $0 { retryShown = true } }
        try await agent.replan()
        XCTAssertEqual(model.calls, 2)
        XCTAssertEqual(gates, 2)
        XCTAssertTrue(retryShown)
        XCTAssertEqual(agent.plan, "1. Observe the screen")
    }

    func testPlannerTimeoutStopsAfterOneRetry() async {
        let model = TimeoutModel(failures: 10)
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        do { try await agent.replan(); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(ModelRequestFailure.isTimeout(error)) }
        XCTAssertEqual(model.calls, 2)
        XCTAssertTrue(agent.steps.isEmpty)
    }

    func testPlannerAndActorHaveDistinctPendingAndReceivingStates() async throws {
        let model = ProgressModel()
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: model, planner: model, trace: nil)
        var states: [String] = []
        agent.onDoing = {
            switch $0 {
            case .waiting: states.append("waiting")
            case .planning: states.append("planning")
            case .thinking: states.append("thinking")
            default: break
            }
        }
        try await agent.replan()
        XCTAssertEqual(states.last, "planning")
        XCTAssertEqual(states.first, "waiting")
        XCTAssertNil(model.onProgress)
        states = []
        _ = try await agent.nextActions()
        XCTAssertEqual(states.first, "waiting")
        XCTAssertEqual(states.last, "thinking")
        XCTAssertFalse(states.contains("planning"))
        XCTAssertNil(model.onProgress)
    }

    func testParseSingleAction() throws {
        let acts = try Actions.parseActions("THINK: The Search pill is visible, so I tap it.\nDO: tap 500 814")
        XCTAssertEqual(acts, [["thought": .str("The Search pill is visible, so I tap it."), "thought_zh": .str(""),
                               "action": .str("tap"), "x": .int(500), "y": .int(814)]])
        XCTAssertEqual(acts[0].keys, ["thought", "thought_zh", "action", "x", "y"])
    }

    func testParseSeveralActionsKeepsThoughtOnFirst() throws {
        let acts = try Actions.parseActions("THINK: Type and search.\nDO: type Whiteboard\nDO: key enter")
        XCTAssertEqual(acts.map { $0["action"]?.str }, ["type", "key"])
        XCTAssertEqual(acts[0]["text"], .str("Whiteboard"))
        XCTAssertEqual(acts[1]["combo"], .str("enter"))
        XCTAssertNil(acts[1]["thought"])
    }

    func testParseCapsAtSixActions() throws {
        let reply = "THINK: draw\n" + (0..<10).map { "DO: tap \($0) \($0)" }.joined(separator: "\n")
        XCTAssertEqual(try Actions.parseActions(reply).count, 6)
    }

    func testParsePathAndCircle() throws {
        XCTAssertEqual(try Actions.parseCommand("path 100 200 300 400 500 600")["points"],
                       .arr([.arr([.int(100), .int(200)]), .arr([.int(300), .int(400)]), .arr([.int(500), .int(600)])]))
        XCTAssertEqual(try Actions.parseCommand("circle 500 450 200"),
                       ["action": .str("circle"), "x": .int(500), "y": .int(450), "r": .int(200)])
    }

    func testParseRejectsBadCommands() {
        for line in ["fly 1 2", "tap 500", "path 1 2 3"] {
            XCTAssertThrowsError(try Actions.parseCommand(line), line)
        }
    }

    func testParseRequiresADoLine() {
        XCTAssertThrowsError(try Actions.parseActions("THINK: I am not sure what to do."))
    }

    func testParsePlanWithAndWithoutLanguages() {
        XCTAssertTrue(Actions.parsePlan("EN:\n1. Tap Search\nZH:\n1. 点搜索") == ("1. Tap Search", "1. 点搜索"))
        XCTAssertTrue(Actions.parsePlan("1. Tap Search") == ("1. Tap Search", "1. Tap Search"))
    }

    func testCircleIsClosedAndRoundOnATallScreen() {
        let aspect = 0.46  // width / height of a portrait iPhone frame
        let pts = circle(0.5, 0.5, 0.2, aspect: aspect)
        XCTAssertEqual(pts[0].x, pts.last!.x, accuracy: 1e-9)
        XCTAssertEqual(pts[0].y, pts.last!.y, accuracy: 1e-9)
        for p in pts {  // equal radius in pixels: y offsets shrink by the aspect ratio
            XCTAssertEqual(hypot(p.x - 0.5, (p.y - 0.5) / aspect), 0.2, accuracy: 1e-9)
        }
    }

    func testActorMayNotRepeatAMoveThatChangedNothing() async throws {
        let actor = FakeModel { n in
            n == 1 ? "THINK: again\nDO: swipe 382 253 382 150" : "THINK: other\nDO: tap 1 2"
        }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [["action": .str("swipe"), "x1": .int(382), "y1": .int(253), "x2": .int(382), "y2": .int(150),
                        "changed": .bool(false)]]
        let acts = try await agent.nextActions()
        XCTAssertEqual(acts[0].act["action"], .str("tap"))
        XCTAssertTrue(actor.prompts[1].contains("changed nothing"))
    }

    func testRepeatingAMoveThatKeepsChangingTheScreenIsNotStuck() {
        let agent = AgentLoop(phone: nil, screen: nil, actor: nil, planner: nil, trace: nil)
        let swipe: JObject = ["action": .str("swipe"), "x1": .int(500), "y1": .int(800), "x2": .int(500), "y2": .int(400)]
        agent.steps = [swipe.merging(["changed": .bool(true)]), swipe.merging(["changed": .bool(true)])]
        XCTAssertFalse(agent.repeating(swipe))
        agent.steps[1]["changed"] = .bool(false)  // reached the end of the list
        XCTAssertTrue(agent.repeating(swipe))
    }

    func testRepeatingANudgedTapOnTheSameTargetIsStuck() {
        let agent = AgentLoop(phone: nil, screen: nil, actor: nil, planner: nil, trace: nil)
        let tap: JObject = ["action": .str("tap"), "x": .int(500), "y": .int(120)]
        agent.steps = [tap.merging(["changed": .bool(false)]),
                       ["action": .str("tap"), "x": .int(503), "y": .int(118), "changed": .bool(false)]]
        XCTAssertTrue(agent.repeating(tap))  // a few units of nudge is the same target
        XCTAssertFalse(agent.repeating(["action": .str("tap"), "x": .int(700), "y": .int(120)]))  // another target
    }

    func testActorGridNotePrecedesNextAction() {
        let prompt = ScreenGrid.prompt("Goal: tap an icon.\n\nNext action?")
        XCTAssertTrue(prompt.contains("0-1000 grid"))
        XCTAssertTrue(prompt.hasSuffix("\n\nNext action?"))
    }

    func testPreciseTapFlag() throws {
        XCTAssertEqual(try Actions.parseCommand("tap 120 640 precise"),
                       ["action": .str("tap"), "x": .int(120), "y": .int(640), "precise": .bool(true)])
        XCTAssertNil(try Actions.parseCommand("tap 120 640")["precise"])
    }

    // MARK: - beyond the Python tests

    func testHistoryIsFormattedLikePythonJSONDumps() async throws {
        let actor = FakeModel { _ in "THINK: ok\nDO: wait" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [
            ["t": .num(1), "shot": .bool(true), "action": .str("plan"), "plan": .str("1. x")],
            ["t": .num(2), "shot": .bool(true), "thought": .str("hi"), "action": .str("tap"), "x": .int(1), "y": .int(2),
             "think_s": .num(1.5), "changed": .bool(true)],
            ["t": .num(3), "shot": .bool(false), "action": .str("type"), "text": .str("café")],
        ]
        _ = try await agent.nextActions()
        XCTAssertTrue(actor.prompts[0].hasSuffix(
            "Recent actions:\n{\"action\": \"tap\", \"x\": 1, \"y\": 2} -> screen changed\n"
            + "{\"action\": \"type\", \"text\": \"caf\\u00e9\"}\n\nNext action?"))
    }

    func testPriorObservedProgressSurvivesReturningToTheInitialScreen() async throws {
        let actor = FakeModel { _ in "THINK: the requested return is complete\nDO: done ok" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = [
            ["shot": .bool(true), "thought": .str("The requested app is open; its content is visible."),
             "action": .str("tap"), "x": .int(920), "y": .int(650)],
            ["shot": .bool(true), "thought": .str("The system menu is open; return to the starting screen now."),
             "action": .str("tap"), "x": .int(640), "y": .int(790)],
            ["shot": .bool(false), "action": .str("reconnected")],
        ]
        _ = try await agent.nextActions()
        let prompt = actor.prompts[0]
        XCTAssertTrue(prompt.contains("The requested app is open; its content is visible."))
        XCTAssertTrue(prompt.contains("The system menu is open; return to the starting screen now."))
        XCTAssertTrue(prompt.contains("historical; the current image is authoritative"))
        XCTAssertTrue(prompt.contains("confirm completion instead of repeating completed steps"))
        XCTAssertTrue(prompt.hasSuffix("Next action?"))
    }

    func testObservationMemoryIsBoundedAndExcludesStepsWithoutAnImage() async throws {
        let actor = FakeModel { _ in "THINK: observe\nDO: wait" }
        let agent = AgentLoop(phone: nil, screen: FakeScreen(), actor: actor, planner: actor, trace: nil)
        agent.steps = (0..<10).map { n -> JObject in
            ["shot": .bool(true), "thought": .str("Observed state \(n): " + String(repeating: "x", count: 400) + "OVERFLOW"),
             "action": .str("tap")]
        }
        agent.steps.append(["shot": .bool(false), "thought": .str("UNOBSERVED"), "action": .str("hiccup")])
        _ = try await agent.nextActions()
        let memory = actor.prompts[0].components(separatedBy: "Earlier screen observations")[1]
            .components(separatedBy: "Recent actions:")[0]
        let entries = try memory.split(separator: "\n").filter { $0.hasPrefix("{") }.map {
            let value = try JSONSerialization.jsonObject(with: Data($0.utf8))
            return try XCTUnwrap(value as? [String: String])
        }
        XCTAssertEqual(entries.count, 8)
        XCTAssertTrue(entries.first?["observation"]?.hasPrefix("Observed state 2:") == true)
        XCTAssertTrue(entries.last?["observation"]?.hasPrefix("Observed state 9:") == true)
        XCTAssertTrue(entries.allSatisfy { ($0["observation"]?.count ?? 0) <= 300 })
        XCTAssertFalse(memory.contains("OVERFLOW"))
        XCTAssertFalse(memory.contains("UNOBSERVED"))
    }

    func testPromptsAreVerbatimFromThePythonServer() throws {
        let agentPy = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../server/hidagent/agent.py").standardized
        guard let source = try? String(contentsOf: agentPy, encoding: .utf8) else {
            throw XCTSkip("server source not reachable from the test runner")
        }
        XCTAssertTrue(source.contains("PLANNER_PROMPT = \"\"\"" + Prompts.planner + "\"\"\""))
        XCTAssertTrue(source.contains("ACTOR_PROMPT = \"\"\"" + Prompts.actorServer + "\"\"\""))
    }

    func testRunStopsAfterThreeErrorsInARow() async {
        let model = FakeModel { n in n == 1 ? "1. do it" : "no action here" }
        let agent = AgentLoop(phone: FakeGestures(), screen: FakeScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(agent.steps.last?["action"], .str("fail"))
        XCTAssertEqual(agent.steps.last?["reason"], .str("3 errors in a row"))
    }

    func testDelayedActorDecisionIsDiscardedBeforeAnyGesture() async throws {
        let screen = FakeScreen(), phone = FakeGestures()
        let model = FakeModel { n in
            if n == 1 {
                screen.live = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    screen.frame = Data([0xff, 0xd8, 1])
                    screen.updated = now(); screen.capturedAt = now(); screen.live = true
                }
                return "THINK: tap based on the old screen\nDO: tap 100 200"
            }
            return "THINK: the recovered screen is different\nDO: done fresh screen"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        let first = try await agent.step()
        XCTAssertFalse(first)
        XCTAssertEqual(agent.steps.last?["action"], .str("reconnected"))
        XCTAssertTrue(phone.calls.isEmpty)
        let finished = try await agent.step()
        XCTAssertTrue(finished)
        XCTAssertEqual(agent.steps.last?["answer"], .str("fresh screen"))
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testUnrecoveredStreamNeverExecutesAnActorGesture() async {
        let screen = FakeScreen(), phone = FakeGestures()
        let model = FakeModel { _ in
            screen.live = false
            return "THINK: old screen\nDO: tap 100 200"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: model, planner: model, trace: nil)
        agent.recoveryLimit = 0
        do {
            _ = try await agent.step()
            XCTFail("a lost screen must stop the gesture")
        } catch is BlindError { }
        catch { XCTFail("unexpected error: \(error)") }
        XCTAssertTrue(phone.calls.isEmpty)
    }

    func testLiveButPreActionFrameNeverReachesTheNextActorCall() async throws {
        let screen = FakeScreen(), phone = FakeGestures()
        screen.capturedAt = now()
        let actor = FakeModel { _ in "THINK: open the menu\nDO: tap 100 200" }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: actor, trace: nil)
        _ = try await agent.step()
        XCTAssertTrue(screen.live)  // still inside the source-age limit, but from before the tap
        XCTAssertLessThan(screen.capturedAt, agent.lastActed)
        // Even a newer transport notification cannot certify an old source image.
        agent.link = { Recovery.Link(connected: true, sta: 1, ap: "streaming", frameAt: now()) }
        agent.recoveryLimit = 0
        do {
            _ = try await agent.nextActions()
            XCTFail("the actor must not receive the old menu screenshot")
        } catch is BlindError { }
        catch { XCTFail("unexpected error: \(error)") }
        XCTAssertEqual(actor.prompts.count, 1)
        XCTAssertEqual(phone.calls, ["tap"])
    }

    func testActorWaitsForAnActualPostActionFrame() async throws {
        let screen = FakeScreen(), phone = FakeGestures()
        screen.capturedAt = now()
        let fresh = Data([0xff, 0xd8, 7])
        let actor = FakeModel { n in
            if n == 1 { return "THINK: open the menu\nDO: tap 100 200" }
            XCTAssertEqual(screen.frame, fresh)
            return "THINK: the new screen confirms completion\nDO: done ok"
        }
        let agent = AgentLoop(phone: phone, screen: screen, actor: actor, planner: actor, trace: nil)
        _ = try await agent.step()
        let looking = Task { try await agent.nextActions() }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(actor.prompts.count, 1)
        screen.frame = fresh; screen.capturedAt = now(); screen.updated = now()
        let actions = try await looking.value
        XCTAssertEqual(actions.first?.act["action"], .str("done"))
        XCTAssertEqual(phone.calls, ["tap"])
    }

    func testRunFinishesOnDone() async {
        let model = FakeModel { n in n == 1 ? "1. go home" : n == 2 ? "THINK: home\nDO: home" : "THINK: there\nDO: done ok" }
        let phone = FakeGestures()
        let agent = AgentLoop(phone: phone, screen: AdvancingScreen(), actor: model, planner: model, trace: nil)
        await agent.run()
        XCTAssertEqual(phone.calls, ["home"])
        XCTAssertEqual(agent.steps.map { $0["action"]?.str }, ["plan", "home", "done"])
        XCTAssertEqual(agent.steps.last?["answer"], .str("ok"))
    }
}

// MARK: - fakes

@MainActor final class FakeModel: ChatModel {
    let model = "fake"
    private(set) var prompts: [String] = []
    private let reply: (Int) -> String

    init(_ reply: @escaping (Int) -> String) { self.reply = reply }

    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        prompts.append(text)
        return ChatResult(text: reply(prompts.count), firstToken: nil, total: 0)
    }
}

@MainActor final class FakeScreen: ScreenSource {
    var live = true
    var frame: Data? = Data([0xff, 0xd8])
    var updated = 0.0
    var capturedAt = 0.0
    var aspect = 0.46
}

/// The successful full-run scenario has a source frame captured after each completed gesture.
@MainActor private final class AdvancingScreen: ScreenSource {
    var live = true
    var frame: Data? = Data([0xff, 0xd8])
    var updated = now()
    var capturedAt = now()
    var aspect = 0.46
    func afterAction(since: Double) async { capturedAt = now(); updated = now() }
}

@MainActor final class FakeDevice: HIDDevice {
    var links = 1
    var connected = true
    var sent: [String] = []
    func send(_ command: String) async throws -> String { sent.append(command); return "" }
    func waitConnected(_ timeout: TimeInterval) async -> Bool { connected }
}

@MainActor final class FakeGestures: Gestures {
    let device: HIDDevice = FakeDevice()
    var calls: [String] = []
    func tap(_ x: Double, _ y: Double, aim: Bool) async throws { calls.append("tap") }
    func swipe(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, hold: Bool) async throws { calls.append("swipe") }
    func drag(_ points: [CGPoint], hold: Bool) async throws { calls.append("drag") }
    func type(_ text: String) async throws { calls.append("type") }
    func key(_ combo: String) async throws { calls.append("key") }
    func goHome() async throws { calls.append("home") }
    func goBack() async throws { calls.append("back") }
    func reset() async throws { calls.append("reset") }
}

@MainActor private final class TimeoutModel: ChatModel {
    let model = "timeout-test"
    let failures: Int
    var calls = 0
    init(failures: Int) { self.failures = failures }
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        calls += 1
        if calls <= failures { throw URLError(.timedOut) }
        return ChatResult(text: "1. Observe the screen", total: 0)
    }
}

@MainActor private final class ProgressModel: ChatModel, ModelProgressReporting {
    let model = "progress-test"
    var onProgress: ((ModelResponseProgress) -> Void)?
    func chat(system: String, text: String, image: Data?, maxTokens: Int, temperature: Double) async throws -> ChatResult {
        onProgress?(.waiting)
        onProgress?(.receiving)
        return ChatResult(text: "THINK: Wait for the screen\nDO: wait", total: 0)
    }
}
