import AppKit
import GaryCore

extension Capability {
    static let wallpaper = Capability(name: "wallpaper", install: { host, plugin in
        plugin.installAPI(host, "wallpaper", WallpaperRequest.methods) { call in
            let request = try WallpaperRequest.parse(call, home: home)
            return .later(.main) {
                guard case .set(let path, let display) = request else { return wallpapers() }
                try setWallpaper(path, on: display)
                return wallpapers(showing: path, on: display)
            }
        }
    })
}

private func wallpapers(showing path: String? = nil, on display: String? = nil) -> JSON {
    .array(NSScreen.screens.map { screen in
        let shown = path != nil && (display == nil || display == screen.uuid) ? path : NSWorkspace.shared.desktopImageURL(for: screen)?.path
        return .object(["display": .string(screen.uuid), "name": .string(screen.localizedName), "path": shown.map(JSON.string) ?? .null])
    })
}

private func setWallpaper(_ path: String, on display: String?) throws {
    guard FileManager.default.fileExists(atPath: path) else { throw HostFailure("\(path) does not exist") }
    let screens = NSScreen.screens.filter { display == nil || $0.uuid == display }
    guard !screens.isEmpty else { throw HostFailure("no display \(display ?? "")") }
    for screen in screens {
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: options)
    }
}
