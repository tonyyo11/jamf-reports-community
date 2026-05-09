// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JamfReports",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "JamfReports", targets: ["JamfReports"])
    ],
    dependencies: [
        // Sparkle 2.x — auto-update framework. EdDSA-signed appcast hosted on
        // GitHub Pages; see ADR-W23-sparkle-integration.md for the full design.
        // Pinned to 2.6.x; lift deliberately and re-test against the local build.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
        // ZIPFoundation — pure-Swift ZIP creation for the OOXML (.xlsx) writer
        // and validator. Required by `Engine/OOXMLWriter.swift` and
        // `Engine/Validators/XLSXValidator.swift`.
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
    ],
    targets: [
        .executableTarget(
            name: "JamfReports",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Sources/JamfReports",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "JamfReportsTests",
            dependencies: [
                "JamfReports",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "Tests/JamfReportsTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
