// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentProfiles",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentProfilesCore", targets: ["AgentProfilesCore"]),
        .executable(name: "AgentProfiles", targets: ["AgentProfiles"]),
    ],
    targets: [
        .target(
            name: "AgentProfilesCore",
            path: "Sources/AgentProfilesCore"
        ),
        .executableTarget(
            name: "AgentProfiles",
            dependencies: ["AgentProfilesCore"],
            path: "Sources/AgentProfiles",
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "AgentProfilesCoreTests",
            dependencies: ["AgentProfilesCore"],
            path: "Tests/AgentProfilesCoreTests",
            resources: [
                .copy("Fixtures")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
