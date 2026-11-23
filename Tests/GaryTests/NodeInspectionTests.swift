import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct NodeInspectionTests {
    private let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: .borderless, backing: .buffered, defer: true)

    @Test func `an inspected tree outlines each node with its frame from the surface's top left, offset included, and the colors it is drawn with`(
    ) throws {
        let theme = try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: .dark),
        )
        let node = try Node.parse(JSON.parse(#"""
        {"type":"column","gap":0,"padding":10,"width":200,"height":100,"children":[
          {"type":"row","key":"first","height":20,"background":"#ff0000","children":[{"type":"text","text":"a","color":"#00ff00","opacity":0.5}]},
          {"type":"row","height":30,"x":5,"children":[]}
        ]}
        """#))
        let tree = MountedTree(root: node, theme: theme)
        let host = TreeHostingView(
            tree: tree,
            onAction: { Issue.record("unexpected action \($0.name)") },
            onDismiss: { Issue.record("unexpected dismiss") },
        )
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        window.contentView = host
        let recorder = FrameRecorder()
        tree.inspection = recorder
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let lines = node.outline(recorder.entries)
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("column @0,0 200x100 "))
        #expect(lines[1].hasPrefix("  row first @10,10 ") && lines[1].contains("background=#ff0000"))
        #expect(lines[2].hasPrefix("    text \"a\" @10,") && lines[2].contains("color=#00ff00") && lines[2].contains("opacity=0.5"))
        #expect(lines[3].hasPrefix("  row @15,30 ") && lines[3].contains("x30 "))
        tree.inspection = nil
        #expect(node.outline([:]) == ["column", "  row first", "    text \"a\"", "  row"])
    }
}
