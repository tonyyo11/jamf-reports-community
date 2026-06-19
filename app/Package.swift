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
        // ZIPFoundation — pure-Swift ZIP creation for the OOXML (.xlsx) writer
        // and validator. Required by `Engine/OOXMLWriter.swift` and
        // `Engine/Validators/XLSXValidator.swift`.
        .package(url: "https://github.com/weichsel/ZIPFoundation", from: "0.9.19"),
        // swift-argument-parser — subcommand parsing for the included `jamf-reports`
        // CLI (Sources/JamfReports/CLI/). Apple-official; resolves to the latest 1.x.
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "JamfReports",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Tests/JamfReportsTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
