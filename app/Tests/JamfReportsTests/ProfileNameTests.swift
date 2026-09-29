import Foundation
import Testing
@testable import JamfReports

/// Names jamf-cli 1.31.1 accepted and resolved in a scratch config on 2026-09-29.
private let jamfCLINames = [
    "Acme Prod", "acme.prod", "Zürich", "a,b", "a:b", "a/b", "-lead", "#hash", "it's",
    "🍎 apple", "..", ".", "_fleet-reports", "100%", "a%2Fb", "東京", "R&D (EU)",
]

@Suite("ProfileName")
struct ProfileNameTests {

    @Test("every name jamf-cli accepts is usable", arguments: jamfCLINames)
    func jamfCLINamesAreUsable(_ name: String) {
        #expect(ProfileName.problem(with: name) == nil)
    }

    @Test("names already in use keep their folder, file name and label")
    func existingNamesAreUnchanged() {
        for name in ["acme", "Acme-Dev", "prod_2", "Waikato-Dev-API", "a--b", "x-"] {
            #expect(ProfileName.pathComponent(name) == name)
            #expect(ProfileName.labelComponent(name) == name)
        }
    }

    @Test("path and label parts decode back to the name", arguments: jamfCLINames)
    func componentsRoundTrip(_ name: String) {
        let path = ProfileName.pathComponent(name)
        let label = ProfileName.labelComponent(name)
        #expect(ProfileName.name(fromPathComponent: path) == name)
        #expect(ProfileName.name(fromLabelComponent: label) == name)
    }

    @Test("a path part is one visible folder that is not reserved", arguments: jamfCLINames)
    func pathComponentIsASafeFolderName(_ name: String) {
        let path = ProfileName.pathComponent(name)
        #expect(!path.contains("/"))
        #expect(!path.contains(":"))
        #expect(!path.hasPrefix("."))
        #expect(!path.hasPrefix("_"))
        #expect(path != "." && path != "..")
    }

    @Test("a label part holds only ASCII letters, digits, _, - and %", arguments: jamfCLINames)
    func labelComponentHasNoSeparator(_ name: String) {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-%")
        #expect(ProfileName.labelComponent(name).unicodeScalars.allSatisfy(allowed.contains))
    }

    @Test("specific encodings")
    func specificEncodings() {
        #expect(ProfileName.pathComponent("Acme Prod") == "Acme Prod")
        #expect(ProfileName.pathComponent("acme.prod") == "acme.prod")
        #expect(ProfileName.pathComponent("a/b") == "a%2Fb")
        #expect(ProfileName.pathComponent("..") == "%2E.")
        #expect(ProfileName.pathComponent("_fleet-reports") == "%5Ffleet-reports")
        #expect(ProfileName.pathComponent("100%") == "100%25")
        #expect(ProfileName.labelComponent("acme.prod") == "acme%2Eprod")
        #expect(ProfileName.labelComponent("Zürich") == "Z%C3%BCrich")
    }

    @Test("a folder that no name encodes to is not a workspace")
    func nonCanonicalComponentsAreRejected() {
        #expect(ProfileName.name(fromPathComponent: "100%") == nil, "stray %")
        #expect(ProfileName.name(fromPathComponent: "a%20b") == nil, "a space is kept as is")
        #expect(ProfileName.name(fromPathComponent: "%2e.") == nil, "hex is upper case")
        #expect(ProfileName.name(fromLabelComponent: "acme.prod") == nil)
        // A folder name Finder or a sync provider stored decomposed still reads back.
        #expect(ProfileName.name(fromPathComponent: "Zu\u{0308}rich") == "Z\u{00FC}rich")
    }

    @Test("the names the app still refuses")
    func problems() {
        #expect(ProfileName.problem(with: "") == .empty)
        #expect(ProfileName.problem(with: "a\nb") == .controlCharacter)
        #expect(ProfileName.problem(with: "a\tb") == .controlCharacter)
        #expect(ProfileName.problem(with: "a\u{2028}b") == .controlCharacter, "line separator")
        #expect(ProfileName.problem(with: "a\u{2029}b") == .controlCharacter, "paragraph separator")
        #expect(ProfileName.problem(with: "a\u{85}b") == .controlCharacter, "next line")
        #expect(ProfileName.problem(with: " acme") == .edgeWhitespace)
        #expect(ProfileName.problem(with: "acme ") == .edgeWhitespace)
        #expect(ProfileName.problem(with: String(repeating: "a", count: 120)) == nil)
        #expect(ProfileName.problem(with: String(repeating: "a", count: 121)) == .tooLong)
        #expect(ProfileName.problem(with: String(repeating: "é", count: 20)) == nil)
        #expect(ProfileName.problem(with: String(repeating: "é", count: 21)) == .tooLong,
                "each é is six bytes in a label")
    }

    @Test("names that share a folder on APFS share a key")
    func folderKeys() {
        #expect(ProfileName.folderKey("Prod") == ProfileName.folderKey("prod"))
        let composed = "Z\u{00FC}rich"
        let decomposed = "Zu\u{0308}rich"
        // Swift's == already treats the two spellings as equal; the scalars differ.
        #expect(Array(composed.unicodeScalars) != Array(decomposed.unicodeScalars))
        #expect(ProfileName.folderKey(composed) == ProfileName.folderKey(decomposed))
        #expect(ProfileName.folderKey("acme") != ProfileName.folderKey("acme-dev"))
    }
}
