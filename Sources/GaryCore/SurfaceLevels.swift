public enum SurfaceLevels {
    private static let desktopIcon = -2_147_483_603
    private static let mainMenu = 24

    public static let bar = 26
    public static let barAside = mainMenu - 1

    public static func level(_ layer: SurfaceLayer) -> Int {
        switch layer {
        case .desktop: desktopIcon - 1
        case .below: -1
        case .normal: 0
        case .top: 3
        case .overlay: 101
        case .notch: mainMenu + 3
        }
    }
}
