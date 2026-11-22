import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct TreeViewBench {
    private nonisolated static let sizes = ProcessInfo.processInfo.environment["GARY_TREE_BENCH"]?.split(separator: ",").compactMap { Int($0) } ?? []
    private static let frames = 150
    private static let warmup = 30

    private let theme: Theme
    private let display: DisplayInfo
    private let spec: SurfaceSpec

    init() throws {
        theme = try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: .dark),
        )
        display = try #require(NSScreen.screens.first).display(index: 0, theme: theme)
        spec = try SurfaceSpec.parse(JSON.parse(#"{"width":1200,"height":900}"#), kind: .panel)
    }

    private static func busy(_ nodes: Int, frame: Int) -> String {
        let perRow = 20
        let rows = Int((Double(nodes - 1) / Double(perRow + 1)).rounded(.up))
        var leaves = nodes - 1 - rows
        let children = (0..<rows).map { row in
            let count = min(perRow, leaves)
            leaves -= count
            let cells = (0..<count).map { column in
                let index = row * perRow + column
                let text = row == rows - 1 && column == count - 1 ? "frame \(frame)" : "cell \(index)"
                return #"{"type":"text","key":"c\#(index)","text":"\#(text)","style":"dim"}"#
            }
            return #"{"type":"row","key":"r\#(row)","gap":4,"children":[\#(cells.joined(separator: ","))]}"#
        }
        return #"{"type":"column","gap":2,"padding":8,"children":[\#(children.joined(separator: ","))]}"#
    }

    private static func parse(_ text: String) throws -> Node {
        let json = try JSON.parse(text)
        let children = try (json["children"]?.array ?? []).map(Node.parse)
        return try Node.parse(.object((json.object ?? [:]).merging(["children": .array([])]) { $1 })).with(children: children)
    }

    private static func milliseconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    private static func threadCPU() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e6
    }

    private static func percentiles(_ name: String, _ values: [Double]) -> String {
        let sorted = values.sorted()
        return String(format: "%@_p50=%.3f %@_p95=%.3f", name, sorted[sorted.count / 2], name, sorted[min(sorted.count - 1, sorted.count * 95 / 100)])
    }

    private func mount(_ tree: Node, in window: SurfaceWindow) -> TreeHostingView {
        let view = TreeHostingView(
            tree: MountedTree(root: tree, theme: theme),
            onAction: { _ in Issue.record("unexpected action") },
            onDismiss: { Issue.record("unexpected dismiss") },
        )
        window.setContent(view)
        window.place(spec, on: display, origin: nil, level: 0, theme: theme)
        window.panel.orderFrontRegardless()
        window.panel.contentView?.layoutSubtreeIfNeeded()
        window.panel.displayIfNeeded()
        CATransaction.flush()
        return view
    }

    private func commit(_ tree: Node, to view: TreeHostingView, in window: SurfaceWindow) -> [String: Double] {
        let apply = Self.milliseconds {
            if view.tree.root != tree {
                view.tree.root = tree
            }
            window.place(spec, on: display, origin: nil, level: 0, theme: theme)
        }
        let layout = Self.milliseconds {
            window.panel.contentView?.layoutSubtreeIfNeeded()
            window.panel.displayIfNeeded()
        }
        let flush = Self.milliseconds { CATransaction.flush() }
        let cpu = Self.threadCPU()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
        return ["apply": apply, "layout": layout, "flush": flush, "frame": apply + layout + flush, "between_cpu": Self.threadCPU() - cpu]
    }

    @Test(.enabled(if: !sizes.isEmpty, "set GARY_TREE_BENCH to a comma-separated list of node counts"))
    func `time the main-thread update of a busy panel per frame`() throws {
        for nodes in Self.sizes {
            var parse: [Double] = []
            let trees = try (0...(Self.warmup + Self.frames)).map { frame in
                let text = Self.busy(nodes, frame: frame)
                var tree: Node?
                try parse.append(Self.milliseconds { tree = try Self.parse(text) })
                return try #require(tree)
            }
            let window = SurfaceWindow()
            var view: TreeHostingView?
            let mountTime = Self.milliseconds { view = mount(trees[0], in: window) }
            let mounted = try #require(view)
            var stages: [String: [Double]] = [:]
            for (index, tree) in trees.dropFirst().enumerated() {
                let times = commit(tree, to: mounted, in: window)
                for (stage, time) in times where index >= Self.warmup {
                    stages[stage, default: []].append(time)
                }
            }
            let fields = ["apply", "layout", "flush", "frame", "between_cpu"].map { Self.percentiles("\($0)_ms", stages[$0] ?? [0]) }
                + [Self.percentiles("parse_ms", parse)]
            print("tree_bench nodes=\(nodes) frames=\(stages["frame"]?.count ?? 0) " + String(format: "mount_ms=%.3f ", mountTime) + fields
                .joined(separator: " "))
            window.panel.close()
        }
    }
}
