import XCTest
import UIKit
import CoreImage
@testable import IPhoneAgent

final class VideoHTTPTests: XCTestCase {
    private let cfg = Data([0,0,0,1,0x67,1,0,0,0,1,0x68,1])
    private let key = Data([0,0,0,1,0x65,0x80,1])
    private let p = Data([0,0,0,1,0x41,0x80,2])

    private func response(_ data: Data, gen: UInt64 = 1, start: UInt64 = 0, config: Int = 12,
                          age: UInt32 = 0, end: UInt64? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://192.168.1.2:3235/gop.h264")!, statusCode: 200,
                        httpVersion: "HTTP/1.1", headerFields: ["X-Monitor-Protocol":"3", "X-Gop-Gen":"\(gen)",
                         "X-Gop-Start":"\(start)", "X-Gop-Bytes":"\(end ?? (start + UInt64(data.count - config)))",
                         "X-Gop-Config":"\(config)", "X-Board-Ms":"600000", "X-Frame-Ms":"\(600000 - age)"])!
    }

    func testCredentialsRequirePrivateLiteralIPv4AndFixedPort() throws {
        let token = String(repeating: "a", count: 48)
        for host in ["192.168.1.2", "10.0.0.1", "172.16.0.1", "172.31.255.254"] {
            XCTAssertNoThrow(try VideoEndpoint(reply: "\(host) 3235 \(token)"))
        }
        for host in ["127.0.0.1", "8.8.8.8", "172.32.0.1", "example.com", "192.168.1.2@evil.test", "192.168.1.999"] {
            XCTAssertThrowsError(try VideoEndpoint(reply: "\(host) 3235 \(token)"))
        }
        XCTAssertThrowsError(try VideoEndpoint(reply: "192.168.1.2 80 \(token)"))
    }

    func testCompletePrefixThenPredictiveSuffixKeepsCursorAndSourceTime() throws {
        var cursor = VideoCursor()
        let first = cfg + key + p
        let batch = try cursor.accept(first, response: response(first, age: 600000))
        XCTAssertTrue(batch.restarted)
        XCTAssertEqual(batch.units.map(\.idr), [false, true, false])
        XCTAssertTrue(batch.units.allSatisfy { $0.boardMs == 0 })
        XCTAssertEqual(cursor.query, "?gen=1&offset=14")
        let suffix = try cursor.accept(p, response: response(p, start: 14, config: 0))
        XCTAssertFalse(suffix.restarted)
        XCTAssertEqual(suffix.units.count, 1)
        XCTAssertEqual(suffix.units[0].boardMs, 600000)
        let empty = Data()
        XCTAssertTrue(try cursor.accept(empty, response: response(empty, start: 21, config: 0)).units.isEmpty)
    }

    func testTruncationAndLostCursorDoNotAdvanceOrAcceptPOnlyPrefix() throws {
        var cursor = VideoCursor()
        let first = cfg + key
        _ = try cursor.accept(first, response: response(first))
        let old = cursor.query
        XCTAssertThrowsError(try cursor.accept(p, response: response(p, start: 7, config: 0, end: 100)))
        XCTAssertEqual(cursor.query, old)
        XCTAssertThrowsError(try cursor.accept(p, response: response(p, gen: 2, start: 7, config: 0)))
        XCTAssertEqual(cursor.query, old)
        let noIDR = cfg + p
        XCTAssertThrowsError(try cursor.accept(noIDR, response: response(noIDR, gen: 2)))
        let partialSlice = cfg + Data([0,0,0,1,0x65,0x40])
        XCTAssertThrowsError(try cursor.accept(partialSlice, response: response(partialSlice)))
    }

    func testRealH264HistoryDecodesReferencesButEmitsOnlyLastPicture() throws {
        // ffmpeg-generated 4-frame red -> blue stream, GOP=50, so blue depends on the old references.
        let raw = Data(base64Encoded: "AAAAAWdCwAraJbARAAADAAEAAAMABI8SJqAAAAABaM4PyAAAAQYF//9O3EXpvebZSLeWLNgg2SPu73gyNjQgLSBjb3JlIDE2NCByMzEwOCAzMWUxOWY5IC0gSC4yNjQvTVBFRy00IEFWQyBjb2RlYyAtIENvcHlsZWZ0IDIwMDMtMjAyMyAtIGh0dHA6Ly93d3cudmlkZW9sYW4ub3JnL3gyNjQuaHRtbCAtIG9wdGlvbnM6IGNhYmFjPTAgcmVmPTEgZGVibG9jaz0wOjA6MCBhbmFseXNlPTA6MCBtZT1kaWEgc3VibWU9MCBwc3k9MSBwc3lfcmQ9MS4wMDowLjAwIG1peGVkX3JlZj0wIG1lX3JhbmdlPTE2IGNocm9tYV9tZT0xIHRyZWxsaXM9MCA4eDhkY3Q9MCBjcW09MCBkZWFkem9uZT0yMSwxMSBmYXN0X3Bza2lwPTEgY2hyb21hX3FwX29mZnNldD0wIHRocmVhZHM9MSBsb29rYWhlYWRfdGhyZWFkcz0xIHNsaWNlZF90aHJlYWRzPTAgbnI9MCBkZWNpbWF0ZT0xIGludGVybGFjZWQ9MCBibHVyYXlfY29tcGF0PTAgY29uc3RyYWluZWRfaW50cmE9MCBiZnJhbWVzPTAgd2VpZ2h0cD0wIGtleWludD01MCBrZXlpbnRfbWluPTIgc2NlbmVjdXQ9MCBpbnRyYV9yZWZyZXNoPTAgcmM9Y3JmIG1idHJlZT0wIGNyZj0yMy4wIHFjb21wPTAuNjAgcXBtaW49MCBxcG1heD02OSBxcHN0ZXA9NCBpcF9yYXRpbz0xLjQwIGFxPTAAgAAAAWWIhDoRigACGPHAAED2OAAIeUnXXgAAAAFBmiASosAAAAABQZpAEa8KRQABDfigACG/FAAEN+KAAIb8UAAQ34oAAhvxQABDfigACG/FAAEN+KAAIb8UAAQ34oAAhvxQABDfigACG/FAAEN+KAAIb8cAAXWI4AAss4nz+fwAAAABQZpgEqLA")!
        let nals = annexBUnits(raw), code = Data([0,0,0,1])
        var config = Data(), pictures = Data()
        for nal in nals {
            let type = nal.first! & 31
            if type == 7 || type == 8 { config.append(code); config.append(nal) }
            else { pictures.append(code); pictures.append(nal) }
        }
        let bytes = config + pictures
        var cursor = VideoCursor()
        let batch = try cursor.accept(bytes, response: response(bytes, config: config.count))
        XCTAssertEqual(batch.units.filter { !$0.config }.count, 4)
        XCTAssertEqual(batch.units.filter { $0.idr }.count, 1)
        let done = expectation(description: "only final decoded frame"), decoder = H264Decoder()
        done.assertForOverFulfill = true
        decoder.onError = { msg, _ in XCTFail(msg) }
        decoder.onFrame = { frame in
            XCTAssertEqual(frame.unit.boardMs, 600000)
            XCTAssertEqual(frame.width, 32)
            let context = CIContext()
            let ci = CIImage(data: frame.jpeg)!
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(ci, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0,y: 0,width: 1,height: 1),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
            XCTAssertGreaterThan(pixel[2], 220)
            XCTAssertLessThan(pixel[0], 25)
            done.fulfill()
        }
        decoder.queue.async {
            for (i, unit) in batch.units.enumerated() {
                decoder.decode(unit, emit: i == batch.units.count - 1)
            }
        }
        wait(for: [done], timeout: 10)
    }

    @MainActor func testTransferCompletionCannotMakeOldBatchFresh() {
        let feed = VideoFeed(), device = FakeDevice()
        feed.device = device; feed.mirroring = true
        let unit = AccessUnit(data: Data(), idr: true, config: false, snap: true, boardMs: 0)
        feed.acceptWiFi(.init(units: [unit], restarted: true, boardMs: 600000), requestStarted: now() - 20)
        feed.show(Data([1]), width: 32, height: 32)
        XCTAssertGreaterThan(now() - feed.capturedAt, 619)
        XCTAssertFalse(feed.live)
    }
}
