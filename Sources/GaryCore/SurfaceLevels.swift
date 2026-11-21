import Foundation

public struct SurfaceLevels: Equatable, Sendable {
    public var bar: Int
    public var panel: Int

    static let table: [(minimum: OperatingSystemVersion, levels: SurfaceLevels)] = [
        (OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0), SurfaceLevels(bar: 26, panel: 101)),
        (OperatingSystemVersion(majorVersion: 0, minorVersion: 0, patchVersion: 0), SurfaceLevels(bar: 25, panel: 101)),
    ]

    public static func forSystem(_ version: OperatingSystemVersion) -> SurfaceLevels {
        table.first { row in
            (version.majorVersion, version.minorVersion, version.patchVersion)
                >= (row.minimum.majorVersion, row.minimum.minorVersion, row.minimum.patchVersion)
        }!.levels
    }
}
