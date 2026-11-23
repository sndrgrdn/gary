// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "gary",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "gary", targets: ["gary"]),
        .library(name: "MediaRemoteAdapter", type: .dynamic, targets: ["MediaRemoteAdapter"]),
    ],
    targets: [
        // Every private symbol Gary uses, listed in one table and resolved with dlsym, so a missing one turns its feature off and shows in the
        // self-test. Objective-C.
        .target(
            name: "GaryPrivate",
            linkerSettings: [.linkedFramework("JavaScriptCore")],
        ),
        // ungive/mediaremote-adapter at 6571499 (BSD-3-Clause), loaded by Apple's /usr/bin/perl to read and control now playing. Objective-C.
        .target(
            name: "MediaRemoteAdapter",
            path: "Vendor/mediaremote-adapter",
            exclude: ["LICENSE", "bin", "src/test"],
            sources: ["src/adapter", "src/private", "src/utility"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src")],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("UniformTypeIdentifiers"), .linkedFramework("ImageIO")],
        ),
        // Pure shell model: manifests, node trees, reconcile, theme, shell config, plugin package sources, surfaces, IPC messages, and parsers for
        // the data capabilities read. Foundation, CoreGraphics geometry, and CryptoKit hashing only. Unit tested.
        .target(
            name: "GaryCore",
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "GaryCoreTests",
            dependencies: ["GaryCore"],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        // Unix socket server and client for Gary's NDJSON IPC lines. Unit tested.
        .target(
            name: "GarySocket",
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        .testTarget(
            name: "GarySocketTests",
            dependencies: ["GarySocket"],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
        // The app and CLI.
        .executableTarget(
            name: "gary",
            dependencies: ["GaryCore", "GarySocket", "GaryPrivate"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("JavaScriptCore"), .linkedFramework("IOKit"), .linkedFramework("Carbon")],
        ),
        // Checks of the app target against its capability registry, such as the agent guide covering every capability.
        .testTarget(
            name: "GaryTests",
            dependencies: ["gary"],
            swiftSettings: [.swiftLanguageMode(.v6)],
        ),
    ],
)
