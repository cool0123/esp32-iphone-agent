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
