// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "gary",
    platforms: [.macOS(.v26)],
    targets: [
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
    ]
)
