import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct TreeViewIdentityTests {
    private let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless, backing: .buffered, defer: true)

    private static func tree(_ style: String, _ base: String = "") throws -> Node {
        try Node.parse(JSON.parse(#"""
        {"type":"column","children":[{"type":"row","key":"row",\#(base)\#(style)"children":[{"type":"input","key":"field","change":"typed"}]}]}
        """#))
    }

    @Test(arguments: [
        #""opacity":0.5,"#, #""scale":0.9,"#, #""rotation":5,"#, #""blur":2,"#, #""blend":"multiply","#,
        #""x":4,"#, #""y":4,"#, #""minWidth":300,"#, ##""shadow":{"color":"#000000","radius":4,"y":2},"##, #""clip":true,"#,
        #""material":"vibrant","#, #""material":"glass","#, #""colorScheme":"light","#, #""action":"open","#,
    ])
    func `a node that gains or loses a style or a click action keeps its children's state`(style: String) throws {
        try withKnownIssue("shadow, action and glass still wrap the row conditionally") {
            try keepsState(style)
        } when: {
            ["shadow", "action", "glass"].contains { style.contains($0) }
        }
    }

    @Test(arguments: [#""hovered":{"opacity":0.9},"#, #""pressed":{"opacity":0.9},"#])
    func `a node with a hover or press style keeps its children's state when its shadow comes or goes`(base: String) throws {
        try keepsState(##""shadow":{"color":"#000000","radius":4,"y":2},"##, base)
    }

    private func keepsState(_ style: String, _ base: String = "") throws {
        var sent: [String] = []
        let theme = try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: .dark),
        )
        let host = try TreeHostingView(
            tree: MountedTree(root: Self.tree(style, base), theme: theme),
            onAction: { sent.append($0.name) },
            onDismiss: { Issue.record("unexpected dismiss") },
        )
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let field = try #require(host.descendants(NSTextField.self).first)
        field.stringValue = "hello"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(sent == ["typed"])

        for next in try ["", style].map({ try Self.tree($0, base) }) {
            host.tree.root = next
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let shown = host.descendants(NSTextField.self).first
            #expect(shown?.stringValue == "hello")
            #expect(shown === field)
        }
    }
}
