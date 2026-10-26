// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DAWlessMIDI",
    platforms: [.macOS(.v13)],
    targets: [
        // Routing logic with no Core MIDI in it, so it can be tested on its own.
        .target(
            name: "DAWlessCore",
            path: "Sources/DAWlessCore"
        ),
        .executableTarget(
            name: "DAWlessMIDI",
            dependencies: ["DAWlessCore"],
            path: "Sources/DAWlessMIDI"
        ),
        .testTarget(
            name: "DAWlessCoreTests",
            dependencies: ["DAWlessCore"]
        ),
    ]
)
