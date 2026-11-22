import Foundation
import GaryCore

struct ShownSurface: Equatable {
    var focused: String?
    var origin: CGRect?
}

struct Scene: Equatable {
    var displays: [DisplayInfo] = []
    var shown: [String: ShownSurface] = [:]
}

struct RuntimeOutput: Equatable {
    var surfaces: [String: SurfaceSpec] = [:]
    var trees: [String: [String: Node]] = [:]
}

enum SurfaceRequest: String {
    case show, hide, toggle
}

enum RuntimeEvent {
    case loaded(RuntimeOutput, surfaces: [String], Trace)
    case output(RuntimeOutput, Trace)
    case surface(SurfaceRequest, String, origin: CGRect?)
    case call(method: String, arguments: [String], reply: (Response) -> Void)
    case failed(String)
}

final class MainDelivery {
    private let lock = NSLock()
    private var newestOutput = 0
    private let handle: (PluginRuntime, RuntimeEvent) -> Void

    init(_ handle: @escaping (PluginRuntime, RuntimeEvent) -> Void) {
        self.handle = handle
    }

    func send(_ runtime: PluginRuntime, _ event: RuntimeEvent) {
        var ticket: Int?
        if case .output = event {
            ticket = lock.withLock {
                newestOutput += 1
                return newestOutput
            }
        }
        DispatchQueue.main.async { [self] in
            if let ticket, lock.withLock({ ticket != newestOutput }) {
                return
            }
            handle(runtime, event)
        }
    }
}
