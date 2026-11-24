import AppKit
import GaryCore

extension Shell {
    func stats(_ id: PluginID?) -> Response {
        let loaded = slots.values.filter { id == nil || $0.key.id == id }
            .compactMap { slot in slot.runtime.map { (key: slot.key, engine: $0.engine.name, metrics: $0.metrics) } }
            .sorted { $0.key.description < $1.key.description }
        if let id, loaded.isEmpty {
            return .failure("\(id) is not loaded")
        }
        return .ok(loaded.map { statsLine($0.key, $0.engine, $0.metrics.snapshot).text }.joined(separator: "\n"))
    }

    private func statsLine(_ key: SlotKey, _ engine: String, _ stats: PluginStats) -> JSON {
        .object([
            "plugin": .string(key.id.rawValue),
            "kind": .string(key.kind.rawValue),
            "engine": .string(engine),
            "cpuMs": .object(["total": milliseconds(stats.cpu), "last60s": milliseconds(stats.recentCPU)]),
            "entries": .object(Dictionary(uniqueKeysWithValues: stats.entries.map { ("\($0.key)", .number(Double($0.value))) })),
            "longestEntryMs": milliseconds(stats.longestEntry),
            "overTimeLimit": .number(Double(stats.overTimeLimit)),
            "renders": .number(Double(stats.renders)),
            "lastRenderNodes": .number(Double(stats.lastRenderNodes)),
            "nodeCap": .number(Double(Node.maxNodes)),
            "refusedRenders": .number(Double(stats.refusedRenders)),
            "timers": .object([
                "firesLast60s": .number(Double(stats.timerFiresPerMinute)),
                "timeouts": .number(Double(stats.timeouts)),
                "intervals": .number(Double(stats.intervals)),
            ]),
            "pendingHostCalls": .object(stats.pendingHostCalls.mapValues { .number(Double($0)) }),
            "memory": memory(of: key),
        ])
    }

    private func memory(of key: SlotKey) -> JSON {
        let views = screens.mounts.filter { $0.key.slot == key }.map(\.value)
        let roots = views.map(\.tree.root)
        let images = decodedImages(at: Set(roots.flatMap(\.imagePaths)))
        return .object([
            "treeNodes": .number(Double(roots.reduce(0) { $0 + $1.nodeCount })),
            "images": .number(Double(images.count)),
            "imageBytes": .number(Double(images.bytes)),
            "views": .number(Double(views.reduce(0) { $0 + $1.descendants(NSView.self).count })),
            "layers": .number(Double(views.reduce(0) { $0 + ($1.layer?.treeCount ?? 0) })),
        ])
    }

    private func milliseconds(_ duration: Duration) -> JSON {
        .number((duration / .microseconds(1)).rounded() / 1000)
    }
}

private extension Node {
    var imagePaths: [String] {
        guard case let .image(path) = content else { return children.flatMap(\.imagePaths) }
        return [path]
    }
}

private extension CALayer {
    var treeCount: Int {
        (sublayers ?? []).reduce(1) { $0 + $1.treeCount }
    }
}
