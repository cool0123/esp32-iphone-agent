import XCTest
@testable import IPhoneAgent

@MainActor final class OpsTests: XCTestCase {
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
