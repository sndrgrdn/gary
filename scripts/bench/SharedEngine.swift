import Foundation
@testable import gary
import GaryCore

struct PluginEngines {
    private let shared: PluginEngine

    init(effect: URL) {
        shared = PluginEngine(effect: effect)
    }

    func engine(for _: PluginKind) -> PluginEngine {
        shared
    }
}
