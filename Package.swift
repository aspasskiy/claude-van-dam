// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeVanDam",
    platforms: [.macOS(.v14)],
    targets: [
        // Accounts, Keychain, locks, switching, token refresh, usage polling.
        .target(
            name: "SwapCore",
            path: "Sources/SwapCore"
        ),
        // Terminal harness for SwapCore.
        .executableTarget(
            name: "claude-van-dam-cli",
            dependencies: ["SwapCore"],
            path: "Sources/claude-van-dam-cli"
        ),
        .testTarget(
            name: "SwapCoreTests",
            dependencies: ["SwapCore"],
            path: "Tests/SwapCoreTests"
        ),
    ]
)
