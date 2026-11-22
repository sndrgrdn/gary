import CoreGraphics
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
