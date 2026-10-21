// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeProfilesCore", targets: ["ClaudeProfilesCore"]),
    ],
    targets: [
        .target(
            name: "ClaudeProfilesCore",
            path: "Sources/ClaudeProfilesCore"
        ),
        .testTarget(
            name: "ClaudeProfilesCoreTests",
            dependencies: ["ClaudeProfilesCore"],
            path: "Tests/ClaudeProfilesCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
