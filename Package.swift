// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "S12AdaptiveEQ",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "S12AdaptiveEQ", targets: ["S12AdaptiveEQ"]),
        .library(name: "EQCore", targets: ["EQCore"]),
    ],
    targets: [
        // DSP, profiles and analysis. No UI, no Core Audio device code: unit-testable.
        .target(name: "EQCore"),
        // Menu bar app: process tap, aggregate device, UI. Bundled into a .app by scripts/bundle.sh.
        .executableTarget(name: "S12AdaptiveEQ", dependencies: ["EQCore"]),
        .testTarget(
            name: "EQCoreTests",
            dependencies: ["EQCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
