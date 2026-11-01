import CryptoKit
import Foundation

/// Local reference pictures, not a fresh screenshot. No token/key/command is stored here.
/// Each length-delimited, checksummed record commits one fully validated HTTP response. A crash can
/// leave an incomplete last record; the earlier complete chain remains usable if the board ring agrees.
actor VideoArchive {
    struct Record: Codable {
        let host: String
        let started: Double
        let headers: [String: String]
        let bytes: Data

        init(host: String, started: Double, response: HTTPURLResponse, bytes: Data) {
            self.host = host; self.started = started; self.bytes = bytes
            var fields: [String: String] = [:]
            for name in ["X-Monitor-Protocol", "X-Gop-Gen", "X-Gop-Start", "X-Gop-Bytes", "X-Gop-Config", "X-Board-Ms", "X-Frame-Ms"] {
                fields[name] = response.value(forHTTPHeaderField: name)
            }
            headers = fields
        }

        var response: HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "http://127.0.0.1/")!, statusCode: 200,
                            httpVersion: "HTTP/1.1", headerFields: headers)!
        }
    }

    struct Restored {
        let records: [Record]
        let cursor: VideoCursor
    }

    private let file: URL
    private let limit: Int
    private var committed = 0
    private var writable = false

    init(file: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("video-reference-v1.bin"), limit: Int = 64 << 20) {
        self.file = file; self.limit = limit
    }

    func load(host: String) -> Restored? {
        writable = false; committed = 0
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int,
              size > 0, size <= limit, let data = try? Data(contentsOf: file) else { return nil }
        var cursor = VideoCursor(), records: [Record] = [], at = 0
        do {
            while at + 4 <= data.count {
                let length = (0..<4).reduce(0) { $0 | Int(data[at + $1]) << ($1 * 8) }
                guard length > 0, length <= (4 << 20) + 16384 else { return nil }
                if length + 36 > data.count - at { break }  // interrupted last append, not a complete record
                let packet = data.subdata(in: at + 4..<at + 4 + length)
                let digest = data.subdata(in: at + 4 + length..<at + 36 + length)
                guard Data(SHA256.hash(data: packet)) == digest else { return nil }
                let record = try PropertyListDecoder().decode(Record.self, from: packet)
                guard record.host == host, record.started.isFinite, record.started > 0 else { return nil }
                let batch = try cursor.accept(record.bytes, response: record.response)
                guard records.isEmpty ? batch.restarted : !batch.restarted else { return nil }
                records.append(record)
                at += length + 36
            }
        } catch { return nil }
        guard !records.isEmpty else { return nil }
        committed = at; writable = true
        return Restored(records: records, cursor: cursor)
    }

    func append(_ record: Record, restarted: Bool) {
        guard !record.bytes.isEmpty else { return }
        do {
            if restarted {
                try Data().write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                committed = 0; writable = true
            }
            guard writable else { return }
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            let packet = try encoder.encode(record)
            guard committed + packet.count + 36 <= limit else { writable = false; return }
            let count = UInt32(packet.count)
            var data = Data((0..<4).map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) })
            data.append(packet); data.append(contentsOf: SHA256.hash(data: packet))
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.truncate(atOffset: UInt64(committed))
            try handle.seek(toOffset: UInt64(committed))
            try handle.write(contentsOf: data)
            committed += data.count
        } catch {
            writable = false
            DebugLog.write("video reference checkpoint unavailable; continuing with memory references")
        }
    }
}
