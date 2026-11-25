import XCTest
@testable import JamfReports

final class DeploymentSourceReductionTests: XCTestCase {

    private func reduce(_ kind: String, _ json: String) -> [[String: Any]]? {
        DeploymentSourceReduction.reduce(kind: kind, payload: Data(json.utf8)).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]]
        }
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: TestFixtures.dir("deployment-health/\(name)"), encoding: .utf8)
    }

    func testAppInstallersKeepsOnlyTheKeysAReaderUses() throws {
        let rows = try XCTUnwrap(reduce(
            "app-installers-deployments", try fixture("app-installers-deployments-list.json")))
        XCTAssertEqual(rows.count, 2)
        let first = rows[0]
        XCTAssertEqual(Set(first.keys),
                       ["id", "name", "enabled", "updateBehavior", "app", "computerStatuses"])
        let app = try XCTUnwrap(first["app"] as? [String: Any])
        XCTAssertEqual(Set(app.keys), ["latestVersion", "deployedVersion"])
        let statuses = try XCTUnwrap(first["computerStatuses"] as? [String: Any])
        XCTAssertEqual(statuses["failed"] as? Int, 40)
        XCTAssertEqual(statuses["unqualified"] as? Int, 12)
        XCTAssertEqual(first["enabled"] as? Bool, true)
    }

    func testPatchPoliciesKeepsTenOfTheElevenKeys() throws {
        let rows = try XCTUnwrap(reduce("patch-policies", try fixture("patch-policies-list.json")))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(Set(rows[0].keys), [
            "id", "policyName", "policyEnabled", "policyTargetVersion", "softwareTitle",
            "softwareTitleConfigurationId", "completed", "deferred", "failed", "pending",
        ])
    }

    func testWrongTypesAreLeftOut() throws {
        let json = """
            [{"id":"1","policyEnabled":1,"failed":true,"completed":2.5,"pending":3,
              "deferred":"4","policyName":7}]
            """
        let row = try XCTUnwrap(reduce("patch-policies", json)?.first)
        XCTAssertNil(row["policyEnabled"], "a number is not a boolean")
        XCTAssertNil(row["failed"], "a boolean is not a number")
        XCTAssertNil(row["completed"], "a fraction is not a whole number")
        XCTAssertNil(row["deferred"], "text is not a number")
        XCTAssertNil(row["policyName"], "a number is not text")
        XCTAssertEqual(row["pending"] as? Int, 3)
        let negative = try XCTUnwrap(reduce("patch-policies", #"[{"failed":-1}]"#)?.first)
        XCTAssertNil(negative["failed"], "a negative count reads as not reported")
        XCTAssertEqual(row["id"] as? String, "1")
    }

    func testEmptyNullAndEnvelopeReadAsLists() {
        XCTAssertEqual(reduce("patch-policies", "[]")?.count, 0)
        XCTAssertEqual(reduce("patch-policies", "null")?.count, 0)
        XCTAssertEqual(reduce("patch-policies", #"{"results":[{"id":"9"}]}"#)?.count, 1)
    }

    func testAnythingButAListOfObjectsSavesNothing() {
        XCTAssertNil(DeploymentSourceReduction.reduce(
            kind: "patch-policies", payload: Data(#"{"id":"1"}"#.utf8)))
        XCTAssertNil(DeploymentSourceReduction.reduce(
            kind: "patch-policies", payload: Data(#"[{"id":"1"},"x"]"#.utf8)))
        XCTAssertNil(DeploymentSourceReduction.reduce(
            kind: "patch-policies", payload: Data("not json".utf8)))
        XCTAssertNil(DeploymentSourceReduction.reduce(
            kind: "computers", payload: Data("[]".utf8)), "an unknown kind")
    }
}
