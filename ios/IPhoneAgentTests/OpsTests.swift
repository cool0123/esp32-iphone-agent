import XCTest
@testable import IPhoneAgent

@MainActor final class OpsTests: XCTestCase {
    func testReconnectDoesNotRevokeTasksAndExplicitDisableDoes() throws {
        let suite = "ops-reconnect-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = TaskOpsStub()
        let ops = OpsController(app: app, defaults: defaults)
        XCTAssertFalse(ops.acceptsTasks)
        ops.enabled = true
        ops.acceptsTasks = true
        ops.start()
        XCTAssertEqual(app.revocations, 0)
        XCTAssertTrue(OpsController(app: app, defaults: defaults).acceptsTasks)

        ops.enabled = false
        XCTAssertEqual(app.revocations, 1)
        ops.enabled = true
        ops.allowsKeyRotation = true
        ops.endpoint = "https://ops.example.com"
        XCTAssertFalse(ops.acceptsTasks)
        XCTAssertFalse(ops.allowsKeyRotation)
        XCTAssertEqual(app.revocations, 2)
        XCTAssertFalse(OpsController(app: app, defaults: defaults).acceptsTasks)
    }

    func testRotateTransportIsWSSOrExplicitPrivateLANPlaintext() throws {
        let suite = "ops-rotate-transport-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ops = OpsController(app: TaskOpsStub(), defaults: defaults)
        for endpoint in ["https://ops.example.com", "https://192.168.3.2:3233"] {
            ops.endpoint = endpoint
            XCTAssertTrue(ops.rotateAllowedTransport, endpoint)
        }
        for endpoint in ["http://192.168.3.2:3233", "http://10.1.2.3:8787", "http://172.16.0.9"] {
            ops.endpoint = endpoint
            XCTAssertTrue(ops.rotateAllowedTransport, endpoint)
            XCTAssertFalse(ops.secureEndpoint)
        }
        for endpoint in ["http://ops.example.com", "http://192.168.3.2.evil.com", "http://8.8.8.8"] {
            ops.endpoint = endpoint
            XCTAssertFalse(ops.rotateAllowedTransport, endpoint)
        }
        XCTAssertTrue(OpsController.privateIPv4Host("192.168.3.2"))
        for host in ["localhost", "127.0.0.1", "192.168.3", "192.168.3.256", "10.0.0.1.evil",
                     "203.0.113.9", "::1", "192.168.3.02"] {
            XCTAssertFalse(OpsController.privateIPv4Host(host), host)
        }
    }

    func testSocketRequiresHTTPSExceptForLocalTests() throws {
        let secure = try XCTUnwrap(OpsController.socketURL("https://ops.example.com/base"))
        XCTAssertEqual(secure.scheme, "wss")
        XCTAssertEqual(secure.path, "/base/ws/device")
        XCTAssertNil(OpsController.socketURL("http://ops.example.com"))
        XCTAssertNil(OpsController.socketURL("http://10.evil.com"))
        XCTAssertEqual(OpsController.socketURL("http://127.0.0.1:8787")?.scheme, "ws")
        XCTAssertEqual(OpsController.socketURL("http://192.168.1.10:8787")?.scheme, "ws")
        XCTAssertNil(OpsController.socketURL("https://user:pass@ops.example.com"))
    }

    func testTaskRequestRejectsMalformedIDsAndExtraFields() throws {
        let id = String(repeating: "a", count: 32)
        let request = try OpsTaskRequest(["task_id": id, "task": "  打开日历  "], submit: true)
        XCTAssertEqual(request.id, id)
        XCTAssertEqual(request.text, "打开日历")
        XCTAssertNil(try OpsTaskRequest(["task_id": id], submit: false).text)
        XCTAssertThrowsError(try OpsTaskRequest(["task_id": "bad", "task": "test"], submit: true))
        XCTAssertThrowsError(try OpsTaskRequest(["task_id": id, "task": " "], submit: true))
        XCTAssertThrowsError(try OpsTaskRequest(["task_id": id, "task": "a", "click": true], submit: true))
    }

    func testModelKeyRotationRequiresMatchingHTTPSEndpointAndStrictPayload() throws {
        let key = "test-only-model-key"
        let payload = ["baseURL": "https://API.example.com:443/v1/", "apiKey": key]
        let request = try OpsModelKeyRequest(payload, currentEndpoint: "https://api.example.com/v1")
        XCTAssertEqual(request.key, key)
        for endpoint in ["http://api.example.com/v1", "https://api.example.com:8443/v1",
                         "https://api.example.com/v2", "https://other.example.com/v1",
                         "https://user@api.example.com/v1", "https://api.example.com/v1?key=old"] {
            XCTAssertThrowsError(try OpsModelKeyRequest(payload, currentEndpoint: endpoint)) { error in
                XCTAssertEqual(error.localizedDescription, "provider endpoint mismatch")
            }
        }
        for invalid in ["short", key + "\n", " " + key] {
            XCTAssertThrowsError(try OpsModelKeyRequest(["baseURL": payload["baseURL"]!, "apiKey": invalid],
                                                        currentEndpoint: "https://api.example.com/v1"))
        }
        XCTAssertThrowsError(try OpsModelKeyRequest(payload.merging(["model": "other"]) { a, _ in a },
                                                    currentEndpoint: "https://api.example.com/v1"))
    }

    func testRotatedKeyPersistsOnlyForMatchingEndpoint() throws {
        let key = "mock-rotation-key"
        let endpoint = "https://api.example.com/v1"
        let entry = try StoredModelKey(endpoint: endpoint, key: key).encoded()
        let account = "rotation-test-" + UUID().uuidString
        defer { Keychain.set("", for: account) }
        Keychain.set("legacy-key", for: account)
        XCTAssertEqual(Keychain.get(account), "legacy-key")
        XCTAssertTrue(Keychain.replace(entry, for: account))
        let persisted = Keychain.get(account)
        XCTAssertEqual(StoredModelKey.resolve(persisted, endpoint: "https://API.example.com:443/v1/", preset: nil), key)
        XCTAssertEqual(StoredModelKey.resolve(persisted, endpoint: "https://api.example.com/v2", preset: "preset"), "")
        XCTAssertEqual(StoredModelKey.resolve("legacy-key", endpoint: endpoint, preset: nil), "legacy-key")
    }

    func testConfigValidationRejectsSecretsAndBadValues() {
        XCTAssertThrowsError(try OpsConfig.validated(["apiKey": "secret"]))
        XCTAssertThrowsError(try OpsConfig.validated(["extraBody": "[]"]))
        XCTAssertThrowsError(try OpsConfig.validated(["frameMode": "other"]))
        XCTAssertEqual(try OpsConfig.validated(["model": "vision-model"]), ["model": "vision-model"])
    }

    func testCaptureSizeIsBoundedAndParsed() {
        XCTAssertEqual(OpsConfig.captureSize("414x736")?.0, 414)
        XCTAssertEqual(OpsConfig.captureSize("414X736")?.1, 736)
        for bad in ["", "414", "414x", "x736", "159x736", "414x2561", "414,736", "0x0", "a x b"] {
            XCTAssertNil(OpsConfig.captureSize(bad), bad)
        }
        XCTAssertThrowsError(try OpsConfig.validated(["captureSize": "10x10"]))
        XCTAssertEqual(try OpsConfig.validated(["captureSize": "414x736"]), ["captureSize": "414x736"])
    }

    func testConfigContainsOnlyNonSecretFields() {
        let settings = Settings(defaults: UserDefaults(suiteName: UUID().uuidString)!, info: nil)
        settings.baseURL = "https://user:pass@example.com/v1?key=remote-secret"
        settings.apiKey = "not-for-remote"
        let config = OpsConfig.get(settings, frameMode: .stream)
        XCTAssertEqual(config["hasAPIKey"] as? Bool, true)
        XCTAssertNil(config["apiKey"])
        XCTAssertNil(config["token"])
        XCTAssertEqual(config["baseURL"] as? String, "https://example.com/v1")
        let json = try? JSONSerialization.data(withJSONObject: config)
        let text = String(decoding: json ?? Data(), as: UTF8.self)
        XCTAssertFalse(text.contains("not-for-remote"))
        XCTAssertFalse(text.contains("remote-secret"))
    }
}

@MainActor private final class TaskOpsStub: OpsTaskApp {
    var revocations = 0
    var settings: Settings { fatalError("not used by the connection lifecycle test") }
    var board: BoardLink { fatalError("not used by the connection lifecycle test") }
    var feed: VideoFeed { fatalError("not used by the connection lifecycle test") }
    var agent: AgentLoop { fatalError("not used by the connection lifecycle test") }
    var opsRecovering: Bool { false }
    var opsNeedsHelp: Bool { false }
    var opsTaskTelemetry: [String: Any] { [:] }
    func setFrameMode(_ mode: FrameMode) {}
    func say(_ text: String) {}
    func stopAgent() async {}
    func submitOpsTask(id: String, text: String) throws -> [String: Any] { [:] }
    func opsTaskStatus(id: String) throws -> [String: Any] { [:] }
    func stopOpsTask(id: String) async throws -> [String: Any] { [:] }
    func revokeOpsTasks() { revocations += 1 }
}
