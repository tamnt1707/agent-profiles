// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeProfiles",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ClaudeProfilesCore", targets: ["ClaudeProfilesCore"]),
        .executable(name: "ClaudeProfiles", targets: ["ClaudeProfiles"]),
    ],
    targets: [
        .target(
            name: "ClaudeProfilesCore",
            path: "Sources/ClaudeProfilesCore"
        ),
        .executableTarget(
            name: "ClaudeProfiles",
            dependencies: ["ClaudeProfilesCore"],
            path: "Sources/ClaudeProfiles",
            resources: [
                .process("Resources")
            ]
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
