import XCTest
@testable import JamfReports

final class ServerHealthReductionTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: TestFixtures.dir("server-health/\(name)"))
    }

    private func reduced(_ kind: String, _ data: Data) throws -> [String: Any]? {
        guard let out = ServerHealthReduction.reduce(kind: kind, payload: data) else { return nil }
        return try JSONSerialization.jsonObject(with: out) as? [String: Any]
    }

    func testTheCAKeepsOnlyNotAfter() throws {
        let kept = try XCTUnwrap(
            try reduced("certificate-authority", fixture("certificate-authority-active.json")))
        XCTAssertEqual(Array(kept.keys), ["notAfter"])
        XCTAssertEqual(kept["notAfter"] as? Int, 1_893_456_000)
    }

    func testAnExtraKeyAndAPersonKeyAreDropped() throws {
        let payload = Data(#"{"notAfter":1893456000,"owner":"Jane Doe","email":"a@b.c"}"#.utf8)
        let kept = try XCTUnwrap(try reduced("certificate-authority", payload))
        XCTAssertEqual(Array(kept.keys), ["notAfter"])
    }

    func testAListOfOneIsReadAndAnythingElseIsNotSaved() throws {
        let list = Data(#"[{"notAfter":1893456000}]"#.utf8)
        XCTAssertEqual(try reduced("certificate-authority", list)?["notAfter"] as? Int,
                       1_893_456_000)
        for bad in ["\"text\"", "3", "null", "[]"] {
            XCTAssertNil(ServerHealthReduction.reduce(
                kind: "certificate-authority", payload: Data(bad.utf8)), bad)
        }
        XCTAssertNil(ServerHealthReduction.reduce(kind: "computers", payload: list))
    }

    func testAMissingOrNonNumericExpirySavesAnEmptyObject() throws {
        for payload in [#"{"serialNumber":"1"}"#, #"{"notAfter":"soon"}"#, #"{"notAfter":true}"#] {
            let kept = try XCTUnwrap(try reduced("certificate-authority", Data(payload.utf8)))
            XCTAssertTrue(kept.isEmpty, payload)
        }
    }

    func testListRowsReadsEveryShapeTheEnrollmentReductionDoes() {
        XCTAssertEqual(ReportEngine.listRows(of: NSNull())?.count, 0)
        XCTAssertEqual(ReportEngine.listRows(of: [1, 2] as [Any])?.count, 2)
        XCTAssertEqual(ReportEngine.listRows(of: ["results": [1]] as [String: Any])?.count, 1)
        XCTAssertNil(ReportEngine.listRows(of: ["other": 1] as [String: Any]))
    }

    func testEveryServerHealthKindInTheMatrixHasAFixture() throws {
        let matrixKinds = Set(ReportEngine.collectCommandMatrix(profile: "p", staleDays: 30)
            .map(\.kind)).intersection(ReportEngine.serverHealthKinds)
        XCTAssertEqual(matrixKinds, ReportEngine.serverHealthKinds, "a kind has no matrix row")
        let names = try FileManager.default.contentsOfDirectory(
            atPath: TestFixtures.dir("server-health").path)
        for kind in matrixKinds {
            XCTAssertTrue(names.contains { $0.hasPrefix(kind + "-") && $0.hasSuffix(".json") },
                          "\(kind) has no fixture under Fixtures/server-health")
        }
    }

    func testTheCAFixtureKeepsTheCapturedShape() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixture("certificate-authority-active.json")) as? [String: Any])
        XCTAssertEqual(Set(object.keys), [
            "subjectX500Principal", "issuerX500Principal", "serialNumber", "version", "notAfter",
            "notBefore", "signature", "keyUsage", "keyUsageExtended", "sha1Fingerprint",
            "sha256Fingerprint",
        ])
        XCTAssertEqual(String(describing: object["notAfter"] ?? "").count, 10, "epoch seconds")
        XCTAssertEqual((object["keyUsage"] as? [String])?.count, 4)
        XCTAssertEqual((object["keyUsageExtended"] as? [String])?.count, 1)
        let signature = try XCTUnwrap(object["signature"] as? [String: Any])
        XCTAssertEqual(Set(signature.keys), ["algorithm", "algorithmOid", "value"])
    }
}
