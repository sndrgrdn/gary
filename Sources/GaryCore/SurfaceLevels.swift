import Foundation

public struct SurfaceLevels: Equatable, Sendable {
    public var bar: Int
    public var layers: [SurfaceLayer: Int]

    private static let desktopIcon = -2147483603
    private static let mainMenu = 24

    private static func row(bar: Int) -> SurfaceLevels {
        SurfaceLevels(bar: bar, layers: [
            .desktop: desktopIcon - 1, .below: -1, .normal: 0, .top: 3, .overlay: 101, .notch: mainMenu + 3,
        ])
    }

    static let table: [(minimum: OperatingSystemVersion, levels: SurfaceLevels)] = [
        (OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0), row(bar: 26)),
        (OperatingSystemVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0), row(bar: 25)),
    ]

    public static func forSystem(_ version: OperatingSystemVersion) -> SurfaceLevels {
        table.first { row in
            (version.majorVersion, version.minorVersion, version.patchVersion)
                >= (row.minimum.majorVersion, row.minimum.minorVersion, row.minimum.patchVersion)
        }!.levels
    }

    public func level(_ layer: SurfaceLayer) -> Int { layers[layer]! }
}
