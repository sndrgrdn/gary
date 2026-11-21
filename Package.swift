// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "gary",
    platforms: [.macOS(.v26)],
    targets: [
        // The private JavaScriptCore execution time limit, resolved with dlsym so a missing symbol disables it. Objective-C.
        .target(
            name: "GaryPrivate",
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        // Pure shell model: manifests, node trees, reconcile, theme, shell config, IPC messages. Foundation only. Unit tested.
        .target(
            name: "GaryCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "GaryCoreTests",
            dependencies: ["GaryCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Unix socket server and clients: NDJSON lines for Gary's IPC, EOF-framed exchanges for dinky. Unit tested.
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
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("JavaScriptCore"), .linkedFramework("IOKit")]
        ),
    ]
)
