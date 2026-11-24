import Foundation
import GaryCore

nonisolated struct ShownSurface: Equatable {
    var focused: String?
    var origin: CGRect?
}

nonisolated struct Scene: Equatable {
    var displays: [DisplayInfo] = []
    var shown: [String: ShownSurface] = [:]
}

nonisolated struct RuntimeOutput: Equatable {
    var surfaces: [String: SurfaceSpec] = [:]
    var trees: [String: [String: Node?]] = [:]
    var refreshRate = 60

    mutating func draw(_ surface: String, on displays: [DisplayInfo], _ render: (DisplayInfo) throws -> Node?) rethrows {
        refreshRate = max(refreshRate, displays.map(\.refreshRate).max() ?? 0)
        trees[surface] = try Dictionary(uniqueKeysWithValues: displays.map { try ($0.id, render($0)) })
    }
}

nonisolated enum SurfaceRequest: String {
    case show, hide, toggle
}

nonisolated struct CallTarget {
    let plugin: PluginID?
    let kind: PluginKind?

    init(plugin: String, kind: String) throws {
        self.plugin = PluginID(plugin)
        self.kind = PluginKind(rawValue: kind)
        guard plugin.isEmpty || self.plugin != nil else { throw RenderError("\(plugin) is not a plugin id") }
        guard kind.isEmpty || self.kind != nil else {
            throw RenderError("\(kind) is not a kind; use \(PluginKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
    }
}

nonisolated enum RuntimeEvent {
    case loaded(RuntimeOutput, Trace)
    case output(RuntimeOutput, Trace)
    case surface(SurfaceRequest, SurfaceAddress, origin: CGRect?)
    case call(CallTarget, method: String, arguments: [String], reply: @Sendable (Response) -> Void)
    case failed(String)
    case busy
}

final nonisolated class MainDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: (runtime: PluginRuntime, event: RuntimeEvent)?
    private var applied: DispatchTime?
    private let handle: @MainActor (PluginRuntime, RuntimeEvent) -> Void

    init(_ handle: @escaping @MainActor (PluginRuntime, RuntimeEvent) -> Void) {
        self.handle = handle
    }

    func send(_ runtime: PluginRuntime, _ event: RuntimeEvent) {
        guard case let .output(output, _) = event else {
            DispatchQueue.main.async { [self] in handle(runtime, event) }
            return
        }
        let due: DispatchTime? = lock.withLock {
            defer { pending = (runtime, event) }
            return pending == nil ? applied.map { $0 + 1 / Double(max(output.refreshRate, 1)) } ?? .now() : nil
        }
        guard let due else { return }
        if due <= .now() {
            DispatchQueue.main.async { [self] in flush() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: due) { [self] in flush() }
        }
    }

    @MainActor private func flush() {
        let latest = lock.withLock {
            defer {
                pending = nil
                applied = .now()
            }
            return pending
        }
        if let latest {
            handle(latest.runtime, latest.event)
        }
    }
}
