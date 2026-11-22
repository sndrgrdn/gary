import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct TreeViewIdentityTests {
    private let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: .borderless, backing: .buffered, defer: true)

    private static func tree(_ style: String) throws -> Node {
        try Node.parse(JSON.parse(#"""
        {"type":"column","children":[{"type":"row","key":"row",\#(style)"children":[{"type":"input","key":"field","change":"typed"}]}]}
        """#))
    }

    @Test(arguments: [
        #""opacity":0.5,"#, #""scale":0.9,"#, #""rotation":5,"#, #""blur":2,"#, #""blend":"multiply","#,
        #""x":4,"#, #""y":4,"#, #""minWidth":300,"#,
    ])
    func `a node that gains or loses a visual effect or minWidth keeps its children's state`(style: String) throws {
        var sent: [String] = []
        let theme = try Theme.parse(
            JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/theme.json"))),
            palette: Palette(nil, system: .dark),
        )
        let host = try TreeHostingView(
            tree: MountedTree(root: Self.tree(style), theme: theme),
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

        for next in try ["", style].map(Self.tree) {
            host.tree.root = next
            host.layoutSubtreeIfNeeded()
            CATransaction.flush()
            let shown = host.descendants(NSTextField.self).first
            #expect(shown?.stringValue == "hello")
            #expect(shown === field)
        }
    }
}
