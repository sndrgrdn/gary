import AppKit
import GaryCore

nonisolated extension Capability {
    static let dock = Capability(name: "dock", summary: "Reserve a screen edge that windows keep clear of, and hide or show the Dock.", types: """
    declare namespace Gary {
      type DockEdge = "bottom" | "left" | "right";
      type DockState = {
        autohide: boolean;
        rect: { x: number; y: number; width: number; height: number } | null;
        reserved: { edge: DockEdge; size: number } | null;
      }
      interface Host { dock: DockApi }
      interface DockApi {
        reserve(edge: DockEdge, size: number): Promise<DockState>;
        release(): Promise<DockState>;
        hide(): Promise<DockState>;
        show(): Promise<DockState>;
        restore(): Promise<DockState>;
        state(): Promise<DockState>;
      }
    }
    """, example: """
    host.dock.hide().then(() => host.dock.reserve("bottom", 56)).then((dock) => host.log(`reserved ${dock.reserved?.size} points`));

    export default {
      surface: { screen: "main", anchors: { bottom: true, left: true, right: true }, height: 56, layer: "top", exclusionMode: "ignore" },
      render() {
        return { type: "row", children: [{ type: "icon", key: "finder", symbol: "folder", action: "com.apple.finder" }] };
      },
    } satisfies Gary.Panel;
    """, install: { host, plugin in
        let owner = ObjectIdentifier(plugin)
        plugin.onStop { DispatchQueue.main.async { Dock.shared.release(owner) } }
        plugin.installAPI(host, "dock", DockRequest.methods) { call in
            let request = try DockRequest.parse(call)
            return .main { try Dock.shared.perform(request, by: owner) }
        }
    })
}

private final class Dock {
    static let shared = Dock()
    private var reservations = Claims<ObjectIdentifier, DockReservation>()
    private var visibilities = Claims<ObjectIdentifier, DockVisibility>()
    private var timer: Timer?

    private var screen: CGSize {
        CGDisplayBounds(CGMainDisplayID()).size
    }

    func perform(_ request: DockRequest, by owner: ObjectIdentifier) throws -> JSON {
        switch request {
        case let .reserve(reservation):
            if let missing = SkyLight.missing(SkyLight.dockSymbols) {
                throw HostFailure(missing)
            }
            guard reservation.rect(in: screen) != nil else { throw HostFailure("\(reservation.size) pt is more than half the screen") }
            reservations.claim(reservation, by: owner)
        case .release:
            reservations.release(owner)
        case .hide, .show:
            if let missing = CoreDock.missing {
                throw HostFailure(missing)
            }
            visibilities.claim(request == .hide ? .autohide : .shown, by: owner)
        case .restore:
            visibilities.release(owner)
        case .state:
            break
        }
        apply()
        return state
    }

    func release(_ owner: ObjectIdentifier) {
        reservations.release(owner)
        visibilities.release(owner)
        apply()
    }

    private var state: JSON {
        let rect = SkyLight.dockRect()?.rect
        return .object([
            "autohide": .bool(CoreDock.visibility == .autohide),
            "rect": rect
                .map { .object(["x": .number($0.minX), "y": .number($0.minY), "width": .number($0.width), "height": .number($0.height)]) } ?? .null,
            "reserved": reservations.current?.json ?? .null,
        ])
    }

    private func apply() {
        if let wanted = visibilities.current {
            if SystemState.saved.dockVisibility == nil {
                SystemState.update { $0.dockVisibility = CoreDock.visibility }
            }
            if CoreDock.visibility != wanted {
                CoreDock.setVisibility(wanted)
            }
        } else if let original = SystemState.saved.dockVisibility {
            if CoreDock.visibility != original {
                CoreDock.setVisibility(original)
            }
            SystemState.update { $0.dockVisibility = nil }
        }
        reserve()
        if reservations.current == nil {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.reserve() } }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    private func reserve() {
        let saved = SystemState.saved.dock
        guard let current = SkyLight.dockRect() else { return }
        guard let reservation = reservations.current, let rect = reservation.rect(in: screen) else {
            guard let saved else { return }
            if current.rect == saved.reserved.rect {
                SkyLight.setDockRect(saved.own)
            }
            SystemState.update { $0.dock = nil }
            log("dock reservation released")
            return
        }
        guard current.rect != rect else { return }
        let own = if let saved, current.rect == saved.reserved.rect {
            saved.own
        } else {
            current
        }
        if saved != nil, own == current {
            log("dock: the Dock rewrote its rect to \(current.rect); reserving again")
        }
        let reserved = DockRect(rect: rect, reason: own.reason, orientation: reservation.orientation)
        SystemState.update { $0.dock = SavedSystemState.Dock(own: own, reserved: reserved) }
        SkyLight.setDockRect(reserved)
        log("dock reserved \(reservation.edge.rawValue) \(reservation.size) pt: \(rect)")
    }
}
