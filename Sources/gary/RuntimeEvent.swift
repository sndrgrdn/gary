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
}

final nonisolated class MainDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var newestOutput = 0
    private let handle: @MainActor (PluginRuntime, RuntimeEvent) -> Void

    init(_ handle: @escaping @MainActor (PluginRuntime, RuntimeEvent) -> Void) {
        self.handle = handle
    }

    func send(_ runtime: PluginRuntime, _ event: RuntimeEvent) {
        let ticket: Int? = if case .output = event {
            lock.withLock {
                newestOutput += 1
                return newestOutput
            }
        } else {
            nil
        }
        DispatchQueue.main.async { [self] in
            if let ticket, lock.withLock({ ticket != newestOutput }) {
                return
            }
            handle(runtime, event)
        }
    }
}
