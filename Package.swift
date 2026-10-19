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
        .testTarget(
            name: "SwapCoreTests",
            dependencies: ["SwapCore"],
            path: "Tests/SwapCoreTests"
        ),
    ]
)
