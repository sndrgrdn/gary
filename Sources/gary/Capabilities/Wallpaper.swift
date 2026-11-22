import AppKit
import GaryCore

extension Capability {
    static let wallpaper = Capability(name: "wallpaper", summary: "The wallpaper of each display. Set it.", types: """
    declare namespace Gary {
      type Wallpaper = { display: string; name: string; path: string | null }
      interface Host { wallpaper: WallpaperApi }
      interface WallpaperApi {
        get(): Promise<Wallpaper[]>;
        set(path: string, display?: string | null): Promise<Wallpaper[]>;
      }
    }
    """, example: """
    export default {
      methods: {
        set(path) {
          host.wallpaper.set(path).then((wallpapers) => host.log(wallpapers.map((each) => `${each.name}: ${each.path}`).join(", ")));
          return `setting ${path}`;
        },
      },
    } satisfies Gary.Service;
    """, install: { host, plugin in
        let folder = plugin.bundle.directory.path
        plugin.installAPI(host, "wallpaper", WallpaperRequest.methods) { call in
            let request = try WallpaperRequest.parse(call, home: home, folder: folder)
            return .later(.main) {
                guard case let .set(path, display) = request else { return wallpapers() }
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
