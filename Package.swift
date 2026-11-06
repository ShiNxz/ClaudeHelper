// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeHelper",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "HelperCore",
            path: "Sources/HelperCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ClaudeHelper",
            dependencies: ["HelperCore"],
            path: "Sources/ClaudeHelper"
        ),
    ]
)
