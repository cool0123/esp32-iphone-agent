import XCTest
@testable import IPhoneAgent

final class VideoArchiveTests: XCTestCase {
    private let host = "http://192.168.1.2:3235"
    private let cfg = Data([0,0,0,1,0x67,1,0,0,0,1,0x68,1])
    private let key = Data([0,0,0,1,0x65,0x80,1])
    private let p = Data([0,0,0,1,0x41,0x80,2])

    private func record(_ bytes: Data, start: Int = 0, config: Int = 12, gen: Int = 4) -> VideoArchive.Record {
        let r = HTTPURLResponse(url: URL(string: host)!, statusCode: 200, httpVersion: "HTTP/1.1",
                               headerFields: ["X-Monitor-Protocol":"3", "X-Gop-Gen":"\(gen)",
                                "X-Gop-Start":"\(start)", "X-Gop-Bytes":"\(start + bytes.count - config)",
                                "X-Gop-Config":"\(config)", "X-Board-Ms":"600000", "X-Frame-Ms":"1000",
                                "Authorization":"Bearer must-not-save"])!
        return .init(host: host, started: 10000, response: r, bytes: bytes)
    }

    private func file() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
    }

    func testSavedIDRCanResumeFromPredictiveRingAfterBoardHistoryOverflow() async throws {
        let url = file(), first = record(cfg + key), suffix = record(p, start: 7, config: 0)
        let archive = VideoArchive(file: url)
        await archive.append(first, restarted: true)
        await archive.append(suffix, restarted: false)
        let restartedApp = VideoArchive(file: url)
        let restored = await restartedApp.load(host: host)
        let state = try XCTUnwrap(restored)
        XCTAssertEqual(state.cursor.query, "?gen=4&offset=14")
        XCTAssertEqual(state.records.count, 2)
        XCTAssertNil(state.records[0].headers["Authorization"])
        // The board's ring has no IDR, but it still has the suffix at our exact last offset.
        var cursor = state.cursor
        let next = record(p, start: 14, config: 0)
        let batch = try cursor.accept(next.bytes, response: next.response)
        XCTAssertFalse(batch.restarted)
        XCTAssertFalse(batch.units[0].idr)
        XCTAssertEqual(batch.units[0].boardMs, 1000)  // age not replaced with new decode time
        var rebooted = state.cursor
        let otherBoot = record(p, start: 14, config: 0, gen: 5)
        XCTAssertThrowsError(try rebooted.accept(otherBoot.bytes, response: otherBoot.response))
    }

    @MainActor func testLocalReplayCannotAuthorizeInputBeforeBoardConfirmsContinuity() {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        feed.videoNetworkFailed(invalidChain: false)
        let unit = AccessUnit(data: Data(), idr: true, config: false, snap: true, boardMs: 1000)
        feed.acceptWiFi(.init(units: [unit], restarted: true, boardMs: 600000), requestStarted: now() - 60, emit: false)
        feed.publish(.init(jpeg: Data([1]), width: 32, height: 32, decodeMs: 0, unit: unit, streamID: feed.streamID))
        XCTAssertFalse(feed.live)
        XCTAssertFalse(feed.networkReady)
        XCTAssertGreaterThan(now() - feed.capturedAt, 658)
    }

    func testPartialTailReusesOnlyCommittedRecordsAndFutureAppendTruncatesTail() async throws {
        let url = file(), archive = VideoArchive(file: url)
        await archive.append(record(cfg + key), restarted: true)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([100,0,0,0,1,2,3])); try handle.close()
        let newApp = VideoArchive(file: url)
        let loaded = await newApp.load(host: host)
        XCTAssertEqual(loaded?.records.count, 1)
        await newApp.append(record(p, start: 7, config: 0), restarted: false)
        let finalApp = VideoArchive(file: url)
        let final = await finalApp.load(host: host)
        XCTAssertEqual(final?.records.count, 2)
        XCTAssertEqual(final?.cursor.query, "?gen=4&offset=14")
    }

    func testCorruptOrWrongBoardCheckpointIsNeverRestored() async throws {
        let url = file(), archive = VideoArchive(file: url)
        await archive.append(record(cfg + key), restarted: true)
        let wrongHost = await VideoArchive(file: url).load(host: "http://192.168.1.3:3235")
        XCTAssertNil(wrongHost)
        var data = try Data(contentsOf: url)
        data[20] ^= 1
        try data.write(to: url)
        let corrupt = await VideoArchive(file: url).load(host: host)
        XCTAssertNil(corrupt)
    }

    func testCheckpointNeverExceedsBoundAndCannotStartWithOnlyPFrames() async throws {
        let url = file(), archive = VideoArchive(file: url, limit: 1024)
        await archive.append(record(cfg + key), restarted: true)
        for i in 0..<20 { await archive.append(record(p, start: 7 + i * 7, config: 0), restarted: false) }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 1024)
        let brokenFile = file(), broken = VideoArchive(file: brokenFile)
        await broken.append(record(cfg + p), restarted: true)
        let loaded = await VideoArchive(file: brokenFile).load(host: host)
        XCTAssertNil(loaded)
    }

    @MainActor func testNetworkInterruptionRetainsReferencesButImmediatelyBlocksLive() {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        feed.show(Data([1]), width: 32, height: 32)
        let stream = feed.streamID, stamp = feed.capturedAt
        XCTAssertTrue(feed.live)
        feed.videoNetworkFailed(invalidChain: false)
        XCTAssertFalse(feed.live)
        XCTAssertEqual(feed.streamID, stream)
        XCTAssertEqual(feed.frame, Data([1]))
        XCTAssertEqual(feed.capturedAt, stamp)
        // A successful empty response can verify connectivity but cannot reset the source age.
        feed.acceptWiFi(.init(units: [], restarted: false, boardMs: 0), requestStarted: now())
        XCTAssertEqual(feed.capturedAt, stamp)
        feed.videoNetworkFailed(invalidChain: true)
        XCTAssertNil(feed.frame)
        XCTAssertGreaterThan(feed.streamID, stream)
        XCTAssertFalse(feed.live)
    }
}
