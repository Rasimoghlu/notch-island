// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NotchIsland",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NotchIsland", targets: ["NotchIsland"]),
        .executable(name: "notch-hook", targets: ["notch-hook"]),
    ],
    targets: [
        // Pure logic: state machine, parsers, usage math. Foundation only.
        .target(name: "NotchIslandCore"),
        // The menu-bar agent app (AppKit + SwiftUI).
        .executableTarget(name: "NotchIsland", dependencies: ["NotchIslandCore"]),
        // Tiny CLI called by Claude Code hooks and the status line.
        .executableTarget(name: "notch-hook", dependencies: ["NotchIslandCore"]),
        // Assertion-based tests (XCTest is not available with Command Line Tools only).
        .executableTarget(name: "selftest", dependencies: ["NotchIslandCore"]),
    ]
)
