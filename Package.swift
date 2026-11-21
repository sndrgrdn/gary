// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "gary",
    platforms: [.macOS(.v26)],
    targets: [
        // Every private symbol Gary uses, listed in one table and resolved with dlsym, so a missing one turns its feature off and shows in the self-test. Objective-C.
        .target(
            name: "GaryPrivate",
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        // Pure shell model: manifests, node trees, reconcile, theme, shell config, surfaces, IPC messages. Foundation and CoreGraphics geometry only. Unit tested.
        .target(
            name: "GaryCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GaryCoreTests",
            dependencies: ["GaryCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unix socket server and client for Gary's NDJSON IPC lines. Unit tested.
        .target(
            name: "GarySocket",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GarySocketTests",
            dependencies: ["GarySocket"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The app and CLI.
        .executableTarget(
            name: "gary",
            dependencies: ["GaryCore", "GarySocket", "GaryPrivate"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("JavaScriptCore"), .linkedFramework("IOKit"), .linkedFramework("Carbon")]
        ),
    ]
)
