import Foundation
import GaryCore

final class PluginEngines {
    private let effect: URL
    private let bar: PluginEngine
    private let other: PluginEngine
    private var own: Set<SlotKey> = []

    init(effect: URL = Paths.effect) {
        self.effect = effect
        bar = PluginEngine("bar", effect: effect)
        other = PluginEngine("other", effect: effect)
    }

    func engine(for key: SlotKey) -> PluginEngine {
        if own.contains(key) {
            return PluginEngine(effect: effect)
        }
        return key.kind == .barWidget || key.kind == .bar ? bar : other
    }

    func promote(_ key: SlotKey) -> Bool {
        own.insert(key).inserted
    }
}
