import Foundation

/// Board-local read-only monitor. Credentials are learned over BLE and never persisted or logged.
struct VideoEndpoint {
    let base: URL
    let token: String

    init(reply: String) throws {
        let p = reply.split(separator: " ").map(String.init)
        guard p.count == 3, p[1] == "3235", p[2].count == 48,
              p[2].allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
            throw DeviceError(message: "invalid video endpoint")
        }
        let ip = p[0].split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        guard ip.count == 4, p[0] == ip.map(String.init).joined(separator: "."),
              ip[0] == 10 || (ip[0] == 192 && ip[1] == 168) || (ip[0] == 172 && (16...31).contains(ip[1])),
              let url = URL(string: "http://\(p[0]):3235") else { throw DeviceError(message: "video endpoint must be private IPv4") }
        base = url; token = p[2]
    }
}

/// HTTP/network failure before any bytes were accepted; the current cursor remains retryable.
struct VideoHTTPUnavailable: Error { let status: Int }

struct VideoBatch {
    let units: [AccessUnit]
    let restarted: Bool
    let boardMs: UInt32
}

/// Validate the byte cursor and complete response before touching the decoder. Each response ends at
/// an AU boundary. Intermediate pictures are reference-only; only the final picture gets X-Frame-Ms.
struct VideoCursor {
    private(set) var generation: UInt32?
    private(set) var offset: UInt64 = 0

    var query: String { generation.map { "?gen=\($0)&offset=\(offset)" } ?? "" }

    mutating func accept(_ data: Data, response: HTTPURLResponse) throws -> VideoBatch {
        func number(_ key: String) throws -> UInt64 {
            guard let s = response.value(forHTTPHeaderField: key), !s.isEmpty,
                  s.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt64(s) else {
                throw DeviceError(message: "invalid video metadata")
            }
            return n
        }
        guard response.statusCode == 200, response.value(forHTTPHeaderField: "X-Monitor-Protocol") == "3" else {
            throw DeviceError(message: "video HTTP \(response.statusCode)")
        }
        let gen = try number("X-Gop-Gen"), start = try number("X-Gop-Start"), end = try number("X-Gop-Bytes")
        let config = try number("X-Gop-Config"), up = try number("X-Board-Ms"), stamp = try number("X-Frame-Ms")
        guard gen <= UInt32.max, up <= UInt32.max, stamp <= UInt32.max, start <= end,
              end - start <= 4 * 1024 * 1024, config <= 512,
              UInt64(data.count) == end - start + config else { throw DeviceError(message: "incomplete video response") }
        let restarted = config > 0
        guard restarted || (generation == UInt32(gen) && offset == start) else {
            throw DeviceError(message: "video cursor lost continuity")
        }
        var units: [AccessUnit] = []
        var picture = Data(), idr = false
        let code = Data([0, 0, 0, 1])
        if restarted {
            let cfg = Data(data.prefix(Int(config)))
            let types = annexBUnits(cfg).compactMap { $0.first.map { $0 & 31 } }
            guard types.contains(7), types.contains(8) else { throw DeviceError(message: "video prefix has no SPS/PPS") }
            units.append(.init(data: cfg, idr: false, config: true, snap: true, boardMs: UInt32(stamp)))
        }
        func flush() {
            if !picture.isEmpty {
                units.append(.init(data: picture, idr: idr, config: false, snap: true, boardMs: UInt32(stamp)))
                picture = Data(); idr = false
            }
        }
        for nal in annexBUnits(Data(data.dropFirst(Int(config)))) {
            guard let first = nal.first else { continue }
            let type = first & 31
            if type == 1 || type == 5 {
                guard nal.count > 1 else { throw DeviceError(message: "truncated video slice") }
                // Exp-Golomb first_mb_in_slice == 0 starts with 1; later slices retain this AU.
                if nal[nal.startIndex + 1] & 0x80 != 0 { flush() }
                else if picture.isEmpty { throw DeviceError(message: "video starts in the middle of a picture") }
                idr = idr || type == 5
                picture.append(code); picture.append(nal)
            } else if type == 9 { flush() }
            else if type == 7 || type == 8 {
                throw DeviceError(message: "unexpected video configuration")
            }  // SEI/filler do not carry reference pictures
        }
        flush()
        guard data.count == Int(config) || units.contains(where: { !$0.config }) else {
            throw DeviceError(message: "video response has no pictures")
        }
        if restarted {
            guard units.first(where: { !$0.config })?.idr == true else { throw DeviceError(message: "video prefix has no IDR") }
        }
        // Commit only once the entire response is consistent.
        generation = UInt32(gen); offset = end
        return VideoBatch(units: units, restarted: restarted, boardMs: UInt32(up))
    }
}

/// Never forward the local monitor bearer credential across a redirect.
final class VideoHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
