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
    targets: [
        .executableTarget(
            name: "JamfReports",
            path: "Sources/JamfReports",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "JamfReportsTests",
            dependencies: ["JamfReports"],
            path: "Tests/JamfReportsTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
