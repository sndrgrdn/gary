import AppKit
import GaryCore

nonisolated extension Capability {
    static let menubar = Capability(name: "menubar", summary: "Hide the macOS menu bar while the plugin runs.", types: """
    declare namespace Gary {
      type MenuBarState = { hidden: boolean; available: boolean }
      interface Host { menubar: MenuBarApi }
      interface MenuBarApi {
        hide(): Promise<MenuBarState>;
        restore(): Promise<MenuBarState>;
        state(): Promise<MenuBarState>;
      }
    }
    """, example: """
    host.menubar.hide().then((menubar) => {
      if (!menubar.hidden) host.log("this macOS cannot hide the menu bar");
    });

    export default {
      render(state) {
        return { type: "row", children: [{ type: "spacer", key: "gap" }, { type: "text", key: "width", text: String(state.display?.width) }] };
      },
    } satisfies Gary.Bar;
    """, install: { host, plugin in
        let owner = ObjectIdentifier(plugin)
        plugin.onStop { SystemState.queue.async { MenuBar.shared.release(owner) } }
        plugin.installAPI(host, "menubar", MenuBarRequest.methods) { call in
            let request = try MenuBarRequest.parse(call)
            return .later(SystemState.queue) {
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

private final nonisolated class MenuBar: @unchecked Sendable {
    static let shared = MenuBar()
    private var hiders: Set<ObjectIdentifier> = []

    func hide(_ owner: ObjectIdentifier) throws {
        guard Paths.drivesSystem else { throw HostFailure(isolatedSystem("the menu bar")) }
        if let missing = SkyLight.missing(SkyLight.menuBarSymbols) {
            throw HostFailure(missing)
        }
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
