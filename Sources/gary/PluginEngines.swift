import Foundation
import GaryCore

nonisolated struct PluginEngines {
    private let bar: PluginEngine
    private let rest: PluginEngine

    init(effect: URL = Paths.effect) {
        bar = PluginEngine(effect: effect)
        rest = PluginEngine(effect: effect)
    }

    func engine(for kind: PluginKind) -> PluginEngine {
        kind == .barWidget || kind == .bar ? bar : rest
    }
}
