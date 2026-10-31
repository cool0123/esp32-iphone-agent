import XCTest
@testable import IPhoneAgent

/// A board that answers every command like the firmware does.
@MainActor final class FakeBoard: BoardTransport {
    var isConnected = true
    var lines: [String] = []
    var drops = 0
    var silent = false
    weak var channel: CommandChannel?

    func write(_ line: String) throws {
        lines.append(line)
        guard !silent else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let reply = parts[1] == "bad" ? "\(parts[0]) err unknown command" : "\(parts[0]) ok"
        Task { @MainActor in self.channel?.handleReply(reply) }
    }

    func dropLink() { drops += 1 }
}

/// Port of server/tests/test_device.py, with a fake BLE transport instead of a TCP socket.
@MainActor final class DeviceTests: XCTestCase {
    func testTimeoutGrowsWithMoveDistanceAndTextLength() {
        XCTAssertEqual(CommandChannel.timeout("click"), 5)
        XCTAssertGreaterThan(CommandChannel.timeout("move 1000 -20"), CommandChannel.timeout("move 10 10"))
        XCTAssertGreaterThanOrEqual(CommandChannel.timeout("move 10 10"), 5)
        XCTAssertGreaterThan(CommandChannel.timeout("type " + String(repeating: "x", count: 40)),
                             CommandChannel.timeout("type hi"))
    }

    func testSendWithoutBoardFailsFast() async {
        do {
            try await CommandChannel().send("ping")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not connected"))
        }
    }

    func testRoundTripWithAFakeBoard() async throws {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        channel.linkUp()
        let ok = await channel.waitConnected(2)
        XCTAssertTrue(ok)
        try await channel.send("ping")
        do {
            try await channel.send("bad")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unknown command"))
        }
        XCTAssertEqual(channel.links, 1)
        let ids = board.lines.compactMap { Int($0.split(separator: " ")[0]) }  // request ids: random start, then +1
        XCTAssertEqual(board.lines.map { $0.split(separator: " ")[1] }, ["ping", "bad"])
        XCTAssertEqual(ids.count == 2 ? ids[1] - ids[0] : 0, 1)
    }

    func testCommandsGoOneAtATime() async throws {
        let board = FakeBoard()
        let channel = CommandChannel(transport: board)
        board.channel = channel
        async let a: String = channel.send("move 1 0")
        async let b: String = channel.send("move -1 0")
        _ = try await (a, b)
        XCTAssertEqual(board.lines.count, 2)
    }

    func testLinkDownFailsCommandsInFlight() async {
        let board = FakeBoard()
        board.silent = true
        let channel = CommandChannel(transport: board)
        board.channel = channel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            channel.linkDown()
        }
        do {
            try await channel.send("click")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("disconnected"))
        }
    }

    func testReplyParsing() {
        XCTAssertEqual(BoardReply.parse("12 ok"), BoardReply(id: 12, ok: true, text: ""))
        XCTAssertEqual(BoardReply.parse("3 ok 812\n"), BoardReply(id: 3, ok: true, text: "812"))
        XCTAssertEqual(BoardReply.parse("4 err unknown command"), BoardReply(id: 4, ok: false, text: "unknown command"))
        XCTAssertNil(BoardReply.parse("ok"))
    }

    func testStatusDecoding() throws {
        let json = #"{"up":123456,"rst":"power-on","heap":81234,"psram":6200000,"usb":"ok","net":"ap","ip":"192.168.4.1","sta":1,"ap":"streaming","w":480,"h":1040,"kbps":180,"fps":4.8,"idr":2000,"idr_age":500,"gop":42000,"aus":12,"ov":1,"adrop":0,"vwait":0,"ble":{"mtu":247,"phy":2,"kbps":350,"drop":0}}"#
        let s = try XCTUnwrap(BoardStatus.decode(Data(json.utf8)))
        XCTAssertEqual(s.ap, "streaming")
        XCTAssertEqual(s.ble?.mtu, 247)
        XCTAssertEqual(s.fps, 4.8)
        XCTAssertEqual(s.idrAge, 500)
        XCTAssertEqual(s.aus, 12)
        XCTAssertEqual(s.ov, 1)
        XCTAssertEqual(s.vwait, 0)
    }

    func testPointerRehomesEveryTenGestures() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)  // span 400 x 800
        for _ in 0..<11 { try await pointer.point(0.5, 0.5) }
        XCTAssertEqual(device.sent.filter { $0 == "home" }.count, 2)
        XCTAssertEqual(device.sent[0], "release")  // a new link: let go first
        XCTAssertEqual(device.sent[2], "move 200 400")
    }

    func testUnicodeTypingIsRejectedBeforeAnyBoardCommand() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: device, calibrationFile: file)
        for text in ["日历", "café", "A😀B"] {
            do { try await pointer.type(text); XCTFail("non-ASCII text must not become HID bytes") }
            catch let error as DeviceError { XCTAssertTrue(error.message.contains("ASCII")) }
        }
        XCTAssertTrue(device.sent.isEmpty)
        try await pointer.type("Calendar 123")
        XCTAssertEqual(device.sent, ["type Calendar 123"])
    }

    func testForgettingPositionRehomesBeforeTheNextTarget() async throws {
        let device = FakeDevice()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: device, calibrationFile: file)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        try await pointer.point(0.5, 0.5)
        device.sent = []
        pointer.forgetPosition()
        XCTAssertTrue(device.sent.isEmpty)  // invalidating a cache never sends blind HID
        try await pointer.point(0.5, 0.5)
        XCTAssertEqual(device.sent, ["home", "move 200 400"])
    }

    func testShortStatusNotifyIsMergedWithTheFullRead() throws {
        let full = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":1,"heap":81234,"usb":"ok","net":"ap","sta":2,"ap":"idle","kbps":180,"ble":{"mtu":247,"phy":2}}"#.utf8)))
        let short = try XCTUnwrap(BoardStatus.decode(Data(#"{"up":2,"usb":"asleep","net":"ap","ap":"streaming","ble":{"mtu":23}}"#.utf8)))
        let m = full.merged(with: short)
        XCTAssertEqual(m.up, 2)
        XCTAssertEqual(m.usb, "asleep")
        XCTAssertEqual(m.ap, "streaming")
        XCTAssertEqual(m.heap, 81234)  // kept from the full read
        XCTAssertEqual(m.sta, 2)
        XCTAssertEqual(m.ble?.mtu, 23)
        XCTAssertEqual(m.ble?.phy, 2)
    }

    func testReplayedFrameIsNotLiveEvenWhenJustDecoded() async throws {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device
        feed.mirroring = true
        // The board has been up 10 minutes, but this decoded AU was captured at its boot.
        feed.boardClock(ms: 600_000)
        feed.show(Data([0xff, 0xd8]), width: 320, height: 480)
        XCTAssertLessThan(now() - feed.updated, 1)
        XCTAssertGreaterThan(now() - feed.capturedAt, 599)
        XCTAssertFalse(feed.live)
        do {
            _ = try await feed.currentFrame(maxAge: 1, wait: 0)
            XCTFail("replayed frame must be rejected, including a snap that adds no fresh frame")
        } catch is BlindError { }
        feed.linkLost()
        XCTAssertNil(feed.frame)
    }

    func testHealthyStillStreamDoesNotReplayTheWholeGOP() async throws {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        try await feed.stream(true)
        feed.show(Data([0xff, 0xd8]), width: 320, height: 480)
        XCTAssertTrue(feed.live)
        let source = try await feed.currentFrame(maxAge: 0, wait: 0, allowUnchanged: true)
        XCTAssertEqual(source, "live (unchanged)")
        XCTAssertEqual(device.sent, ["stream on"])  // no snap of an old, multi-minute GOP
    }

    func testDelayedStreamRejectsInputWithoutReplayingTheGOP() async throws {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        try await feed.stream(true)
        feed.boardClock(ms: 600_000)
        feed.show(Data([0xff, 0xd8]), width: 320, height: 480)
        let sourceAt = feed.capturedAt
        XCTAssertFalse(feed.live)
        do {
            _ = try await feed.currentFrame(maxAge: 1, wait: 0, allowUnchanged: true)
            XCTFail("a delayed stream must not authorize a gesture")
        } catch is BlindError { }
        XCTAssertEqual(device.sent, ["stream on"])
        XCTAssertEqual(feed.capturedAt, sourceAt)
    }

    func testBrokenContinuousStreamDoesNotQueueSnapshotsAfterAnAction() async throws {
        let previousMode = FrameMode.current
        defer { FrameMode.current = previousMode }
        FrameMode.current = .stream
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        try await feed.stream(true)
        feed.resetStream()
        await feed.afterAction(since: now())
        XCTAssertEqual(device.sent, ["stream on"])
        XCTAssertFalse(feed.live)
        XCTAssertNil(feed.frame)
    }

    func testExplicitSnapshotModeStillRequestsTheGOP() async throws {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        try await feed.stream(false)
        do {
            _ = try await feed.currentFrame(maxAge: 1, wait: 0)
            XCTFail("the fake board supplied no frame")
        } catch is BlindError { }
        XCTAssertEqual(device.sent, ["stream off", "snap"])
    }

    #if LEGACY_IOS
    func testLegacyHomeDoesNotPretendConsumerHomeWorked() async {
        let device = FakeDevice()
        let pointer = Pointer(device: device, calibrationFile: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"))
        do {
            try await pointer.goHome()
            XCTFail("iOS 15 must use the observed AssistiveTouch menu")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("AssistiveTouch"))
        }
        XCTAssertFalse(device.sent.contains("homescreen"))
        XCTAssertFalse(device.sent.contains("key cmd+h"))
    }
    #endif

    func testInvalidVideoChainRejectsQueuedFramesUntilACompleteIDR() async {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        feed.show(Data([0xff, 0xd8]), width: 320, height: 480)
        XCTAssertTrue(feed.live)
        let oldStream = feed.streamID
        func frame(_ streamID: Int) -> H264Decoder.Frame {
            .init(jpeg: Data([0xff, 0xd8]), width: 320, height: 480, decodeMs: 0,
                  unit: .init(data: Data(), idr: false, config: false, snap: false, boardMs: 0), streamID: streamID)
        }
        // Contiguous CONFIG then a predictive AU: fresh timestamps alone cannot restore references.
        feed.receive(Data([0, 0, 11, 0, 0, 0, 0]))
        feed.receive(Data([1, 0, 3, 0, 0, 0, 0]))
        feed.publish(frame(oldStream))
        feed.publish(frame(feed.streamID))
        XCTAssertFalse(feed.live)
        XCTAssertNil(feed.frame)
        feed.receive(Data([2, 0, 7, 0, 0, 0, 0]))  // completed IDR; no fake encoded payload submitted
        feed.publish(frame(feed.streamID))
        XCTAssertTrue(feed.live)
        feed.decodeFailed("bad reference picture", streamID: feed.streamID)
        feed.publish(frame(feed.streamID))
        XCTAssertFalse(feed.live)
        XCTAssertNil(feed.frame)
        feed.receive(Data([3, 0, 7, 0, 0, 0, 0]))
        let completedStream = feed.streamID
        feed.publish(frame(completedStream))
        XCTAssertTrue(feed.live)
        feed.receive(Data([5, 0, 3, 0, 0, 0, 0]))  // chunk 4 lost
        feed.publish(frame(completedStream))
        XCTAssertFalse(feed.live)
        XCTAssertNil(feed.frame)
        feed.linkLost()
        feed.publish(frame(completedStream))
        XCTAssertNil(feed.frame)
    }

    func testReconnectRestartsContinuousForwardingWithoutMakingHistoryFresh() async throws {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        feed.boardClock(ms: 600_000)
        try await feed.restartStreamAfterLink()
        XCTAssertEqual(device.sent, ["stream off", "stream on"])
        XCTAssertTrue(feed.streamOn)
        XCTAssertNil(feed.frame)
        XCTAssertFalse(feed.live)
        feed.show(Data([0xff, 0xd8]), width: 320, height: 480)
        XCTAssertGreaterThan(now() - feed.capturedAt, 599)  // preserved clock rejects the old prefix
        XCTAssertFalse(feed.live)
    }

    func testReconnectDuringVideoRestartDoesNotEnableANewerLink() async {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device
        let change = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 20_000_000)
            device.links += 1
        }
        do { try await feed.restartStreamAfterLink(); XCTFail("old restart must not cross a reconnect") }
        catch { XCTAssertTrue(error.localizedDescription.contains("link changed")) }
        await change.value
        XCTAssertEqual(device.sent, ["stream off"])
        XCTAssertFalse(feed.streamOn)
    }

    func testVideoPrefixBeforeLinkReadySurvivesTheReadinessCallback() {
        #if LEGACY_IOS
        let model = LegacyModel()
        #else
        let model = AppModel.shared
        #endif
        let feed = model.feed, board = model.board
        XCTAssertNotNil(board.onLinkPreparing)
        let device = FakeDevice(), previousDevice = feed.device
        feed.device = device; feed.mirroring = true
        defer { board.onLinkDown?(); feed.device = previousDevice }
        feed.show(Data([1]), width: 320, height: 480)
        let previousStream = feed.streamID
        board.onLinkPreparing?()
        XCTAssertGreaterThan(feed.streamID, previousStream)
        XCTAssertNil(feed.frame)
        // CONFIG and the IDR START can arrive between subscription and the encrypted net read.
        board.onVideo?(Data([0, 0, 11, 0, 0, 0, 0]))
        board.onVideo?(Data([1, 0, 5, 0, 0, 0, 0]))
        let stream = feed.streamID
        board.onLinkUp?()
        XCTAssertEqual(feed.streamID, stream)  // readiness must not discard the partial IDR
        board.onVideo?(Data([2, 0, 6]))
        feed.publish(.init(jpeg: Data([0xff, 0xd8]), width: 320, height: 480, decodeMs: 0,
                           unit: .init(data: Data(), idr: true, config: false, snap: false, boardMs: 0),
                           streamID: stream))
        XCTAssertTrue(feed.live)
        board.onLinkDown?()
        XCTAssertNil(feed.frame)
        XCTAssertFalse(feed.live)
    }

    func testFreshCalibrationHasNoDriftAndSurvivesARestart() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let pointer = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertFalse(pointer.calibrated)
        pointer.finishCalibration(x: 0.5, y: 0.25)
        XCTAssertEqual(pointer.drift, 0)
        let again = Pointer(device: FakeDevice(), calibrationFile: file)
        XCTAssertEqual(again.span, Pointer.Span(w: 400, h: 800))
    }

    func testModelSettingsNeedOnlyAnEndpoint() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let settings = Settings(defaults: defaults, info: nil)  // no build-time preset
        XCTAssertFalse(settings.isConfigured)  // nothing is built in
        settings.baseURL = "https://example.com/v1"
        XCTAssertTrue(settings.isConfigured)  // the model is picked from GET /models
        XCTAssertNil(settings.currentModel)
        settings.model = "some-model"
        XCTAssertEqual(settings.currentModel, "some-model")
    }

    func testProbeFitRecoversScaleAndOffset() {
        let samples: [(Double, Double)] = [150.0, 350, 60].map { u in (u, 0.02 + u / 400) }
        let line = ProbeFit.line(samples)
        XCTAssertEqual(line?.a ?? 0, 1 / 400, accuracy: 1e-9)
        XCTAssertEqual(line?.b ?? 0, 0.02, accuracy: 1e-9)
        XCTAssertEqual(line?.rms ?? 1, 0, accuracy: 1e-9)
        XCTAssertEqual(line?.units(for: 0.52), 200)
        XCTAssertNil(ProbeFit.line([(100, 0.3)]))
        XCTAssertFalse(ProbeFit.usable(0.995))  // stuck at the edge
    }
}
