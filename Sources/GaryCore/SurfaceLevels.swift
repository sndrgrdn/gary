import Foundation

public struct SurfaceLevels: Equatable, Sendable {
    public var bar: Int
    public var barAside: Int

    private static let desktopIcon = -2_147_483_603
    private static let mainMenu = 24

    private static func row(bar: Int) -> SurfaceLevels {
        SurfaceLevels(bar: bar, barAside: mainMenu - 1)
    }

    private static let oldest = row(bar: 25)

    static let table: [(minimum: OperatingSystemVersion, levels: SurfaceLevels)] = [
        (OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0), row(bar: 26)),
    ]

    public static func forSystem(_ version: OperatingSystemVersion) -> SurfaceLevels {
        let match = table.first { row in
            (version.majorVersion, version.minorVersion, version.patchVersion)
                >= (row.minimum.majorVersion, row.minimum.minorVersion, row.minimum.patchVersion)
        }
        return match?.levels ?? oldest
    }

    public func level(_ layer: SurfaceLayer) -> Int {
        switch layer {
        case .desktop: Self.desktopIcon - 1
        case .below: -1
        case .normal: 0
        case .top: 3
        case .overlay: 101
        case .notch: Self.mainMenu + 3
        }
    }
}
