import XCTest
@testable import JamfReports

/// The Add sheet's Platform API Connect new, with jamf-cli and the config.yaml write injected.
@MainActor
final class PlatformSlotConnectModelTests: XCTestCase {
    private final class Spy: @unchecked Sendable {
        var registered: [String] = []
        var written: [(String, String)] = []
        var existing: [String] = []
        var check: ConnectionCheck.Verdict = .accepted(jamfProVersion: "11.9")
        var host: PlatformHostCheck.Verdict = .same
        var registerError: Error?
    }

    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    private func model(_ spy: Spy) -> PlatformSlotConnectModel {
        let deps = PlatformSlotConnectModel.Dependencies(
            jamfCLI: { URL(fileURLWithPath: "/bin/echo") },
            register: { _, profile, _, _, _, _, _ in
                spy.registered.append(profile)
                if let error = spy.registerError { throw error }
            },
            check: { _, _ in spy.check },
            hostVerdict: { _, _, _ in spy.host },
            writeSlot: { spy.written.append(($0, $1)) },
            existingProfiles: { spy.existing })
        let model = PlatformSlotConnectModel(workspace: "Example", dependencies: deps)
        model.scopeID = "env-123"
        model.clientID = "client-abc"
        model.setSecret(Data("s3cret-value".utf8))
        return model
    }

    func testAcceptedAddsTheSlot() async {
        let spy = Spy()
        let model = model(spy)
        await model.connect()
        XCTAssertEqual(spy.written.count, 1)
        XCTAssertEqual(spy.written.first?.1, "Example-API")
        guard case .added = model.outcome else { return XCTFail("\(String(describing: model.outcome))") }
    }

    func testRejectedIDRefusesAndNamesRemoveProfile() async {
        let spy = Spy()
        spy.check = .rejectedID(.unknownEnvironment)
        let model = model(spy)
        await model.connect()
        XCTAssertTrue(spy.written.isEmpty)
        guard case .refused(let text) = model.outcome else { return XCTFail("no refusal") }
        XCTAssertTrue(text.contains("jamf-cli config remove-profile Example-API"))
    }

    func testDifferentHostRefuses() async {
        let spy = Spy()
        spy.host = .different(jamfPro: "a.example.com", platform: "b.example.com")
        let model = model(spy)
        await model.connect()
        XCTAssertTrue(spy.written.isEmpty)
        guard case .refused(let text) = model.outcome else { return XCTFail("no refusal") }
        XCTAssertTrue(text.contains("remove-profile"))
    }

    func testUndecidedContinuesAndAdds() async {
        let spy = Spy()
        spy.check = .undecided(exitCode: 1)
        let model = model(spy)
        await model.connect()
        XCTAssertEqual(spy.written.count, 1)
    }

    func testRegisterFailureWritesNothing() async {
        let spy = Spy()
        spy.registerError = Boom()
        let model = model(spy)
        await model.connect()
        XCTAssertTrue(spy.written.isEmpty)
        XCTAssertEqual(model.outcome, .failed("boom"))
        XCTAssertEqual(model.secretByteCount, 0)
    }

    func testSecretIsWipedAfterConnect() async {
        let model = model(Spy())
        XCTAssertGreaterThan(model.secretByteCount, 0)
        await model.connect()
        XCTAssertEqual(model.secretByteCount, 0)
    }

    func testExistingProfileNameCannotConnect() {
        let spy = Spy()
        spy.existing = ["example-api"]
        XCTAssertFalse(model(spy).canConnect)
    }

    func testBadScopeIDCannotConnect() {
        let model = model(Spy())
        model.scopeID = "--evil"
        XCTAssertFalse(model.canConnect)
    }
}
