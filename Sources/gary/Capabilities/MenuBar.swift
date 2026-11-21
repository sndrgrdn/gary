import AppKit
import GaryCore

extension Capability {
    static let menubar = Capability(name: "menubar", install: { host, plugin in
        let owner = ObjectIdentifier(plugin)
        plugin.onStop { DispatchQueue.main.async { MenuBar.shared.release(owner) } }
        plugin.installAPI(host, "menubar", MenuBarRequest.methods) { call in
            let request = try MenuBarRequest.parse(call)
            return .later(.main) {
                switch request {
                case .hide: try MenuBar.shared.hide(owner)
                case .restore: MenuBar.shared.release(owner)
                case .state: break
                }
                return MenuBar.shared.state
            }
        }
    })
}

private final class MenuBar {
    static let shared = MenuBar()
    private var hiders: Set<ObjectIdentifier> = []

    func hide(_ owner: ObjectIdentifier) throws {
        if let missing = SkyLight.missing(SkyLight.menuBarSymbols) { throw HostFailure(missing) }
        hiders.insert(owner)
        apply()
    }

    func release(_ owner: ObjectIdentifier) {
        hiders.remove(owner)
        apply()
    }

    var state: JSON {
        .object(["hidden": .bool(SystemState.saved.menuBarHidden), "available": .bool(SkyLight.missing(SkyLight.menuBarSymbols) == nil)])
    }

    private func apply() {
        let hidden = !hiders.isEmpty
        guard hidden != SystemState.saved.menuBarHidden else { return }
        SkyLight.setMenuBarAlpha(hidden ? 0 : 1)
        SystemState.update { $0.menuBarHidden = hidden }
        log("menubar \(hidden ? "hidden" : "restored")")
    }
}
