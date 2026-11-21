import Foundation
import Testing
import GaryCore

struct NodeTests {
    private func parse(_ text: String) throws -> Node { try Node.parse(Data(text.utf8)) }

    @Test func parsesEveryKindWithOptionalFields() throws {
        let node = try parse("""
        {"type":"row","style":"bar","children":[
          {"type":"text","text":"1","key":"ws1","style":"active","action":"1"},
          {"type":"icon","symbol":"battery.100"},
          {"type":"spacer"},
          {"type":"column","children":[{"type":"text","text":42}]}
        ]}
        """)
        #expect(node == Node(.row([
            Node(.text("1"), key: "ws1", style: "active", action: "1"),
            Node(.icon("battery.100")),
            Node(.spacer),
            Node(.column([Node(.text("42"))])),
        ]), style: "bar"))
    }

    @Test func nullOptionalFieldsAreAbsent() throws {
        #expect(try parse(#"{"type":"text","text":"a","style":null,"key":null}"#) == Node(.text("a")))
    }

    @Test func rejectsMalformedNodesWithTheirPath() {
        let cases: [(String, NodeError)] = [
            (#"[]"#, NodeError(path: "root", reason: "node must be an object")),
            (#"{"text":"a"}"#, NodeError(path: "root", reason: "type is required")),
            (#"{"type":"button"}"#, NodeError(path: "root", reason: "unknown type \"button\"")),
            (#"{"type":"text"}"#, NodeError(path: "root", reason: "text is required")),
            (#"{"type":"icon","text":"x"}"#, NodeError(path: "root", reason: "symbol is required")),
            (#"{"type":"text","text":"a","style":3}"#, NodeError(path: "root", reason: "style must be a string")),
            (#"{"type":"row","children":{}}"#, NodeError(path: "root", reason: "children must be an array")),
            (#"{"type":"row","children":[{"type":"text","text":"a"},{"type":"text"}]}"#,
             NodeError(path: "root.children[1]", reason: "text is required")),
            (#"{"type":"row","children":[{"type":"spacer","key":"k"},{"type":"spacer","key":"k"}]}"#,
             NodeError(path: "root", reason: "duplicate key \"k\" among children")),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try parse(text) }
        }
        #expect(throws: NodeError(path: "root", reason: "render did not return a JSON value")) { try parse("undefined") }
    }

    @Test func boundsDepthAndSize() throws {
        var deep = #"{"type":"spacer"}"#
        for _ in 1..<Node.maxDepth { deep = #"{"type":"row","children":[\#(deep)]}"# }
        _ = try parse(deep)
        #expect(throws: NodeError.self) { try parse(#"{"type":"row","children":[\#(deep)]}"#) }

        let wide = Array(repeating: #"{"type":"spacer"}"#, count: Node.maxNodes).joined(separator: ",")
        #expect(throws: NodeError(path: "root.children[999]", reason: "tree has more than \(Node.maxNodes) nodes")) {
            try parse(#"{"type":"row","children":[\#(wide)]}"#)
        }
    }
}

/// Applies patches the way the AppKit view layer does, keeping view identity so tests can see reuse.
private final class FakeView {
    var kind: Node.Kind
    var key: String?
    var attributes: (value: String?, style: String?, action: String?)
    var children: [FakeView]

    init(_ node: Node) {
        kind = node.kind
        key = node.key
        attributes = (node.value, node.style, node.action)
        children = node.children.map(FakeView.init)
    }

    func apply(_ patch: Patch) -> FakeView {
        switch patch {
        case .replace(let node):
            return FakeView(node)
        case .update(let attributes, let children):
            if let attributes { self.attributes = (attributes.value, attributes.style, attributes.action) }
            if let children {
                let old = self.children
                self.children = children.map { child in
                    switch child {
                    case .reuse(let index, let patch): return patch.map { old[index].apply($0) } ?? old[index]
                    case .create(let node): return FakeView(node)
                    }
                }
            }
            return self
        }
    }

    var subtree: [FakeView] { [self] + children.flatMap(\.subtree) }

    var node: Node {
        let content: Node.Content
        switch kind {
        case .row: content = .row(children.map(\.node))
        case .column: content = .column(children.map(\.node))
        case .text: content = .text(attributes.value!)
        case .icon: content = .icon(attributes.value!)
        case .spacer: content = .spacer
        }
        return Node(content, key: key, style: attributes.style, action: attributes.action)
    }
}

struct ReconcileTests {
    private func text(_ value: String, key: String? = nil, style: String? = nil) -> Node {
        Node(.text(value), key: key, style: style)
    }

    /// Mounts `old`, applies the patch, and returns the result plus how many of its views are new.
    private func mountAndPatch(_ old: Node, _ new: Node) -> (view: FakeView, root: FakeView, built: Int) {
        let root = FakeView(old)
        let mounted = Set(root.subtree.map(ObjectIdentifier.init))
        let view = reconcile(old, new).map { root.apply($0) } ?? root
        #expect(view.node == new)
        return (view, root, view.subtree.filter { !mounted.contains(ObjectIdentifier($0)) }.count)
    }

    @Test func equalTreesNeedNoPatch() {
        let tree = Node(.row([text("a"), Node(.icon("bolt")), Node(.column([text("b")]))]))
        #expect(reconcile(tree, tree) == nil)
    }

    @Test func aTextChangeUpdatesOneViewInPlace() {
        let old = Node(.row([text("12:00"), text("80%")]))
        let new = Node(.row([text("12:01"), text("80%")]))
        #expect(reconcile(old, new) == .update(attributes: nil, children: [
            .reuse(from: 0, patch: .update(attributes: Attributes(value: "12:01", style: nil, action: nil), children: nil)),
            .reuse(from: 1, patch: nil),
        ]))
        let result = mountAndPatch(old, new)
        #expect(result.view === result.root)
        #expect(result.built == 0)
    }

    @Test func aChangedRootKindOrKeyReplacesTheView() {
        #expect(reconcile(Node(.row([])), Node(.column([]))) == .replace(Node(.column([]))))
        #expect(reconcile(text("a", key: "x"), text("a", key: "y")) == .replace(text("a", key: "y")))
        #expect(mountAndPatch(Node(.row([text("a")])), Node(.column([text("a")]))).built == 2)
    }

    @Test func keyedChildrenKeepTheirViewsWhenReordered() {
        let old = Node(.row([text("1", key: "1"), text("2", key: "2"), text("3", key: "3")]))
        let new = Node(.row([text("3", key: "3"), text("1", key: "1"), text("2", key: "2", style: "active")]))
        let result = mountAndPatch(old, new)
        #expect(result.built == 0)
        let mounted = FakeView(old)
        let views = mounted.children
        _ = mounted.apply(reconcile(old, new)!)
        #expect(mounted.children.map(ObjectIdentifier.init) == [views[2], views[0], views[1]].map(ObjectIdentifier.init))
    }

    @Test func insertingAKeyedChildBuildsOnlyThatChild() {
        let old = Node(.row([text("2", key: "2"), text("3", key: "3")]))
        let new = Node(.row([text("1", key: "1"), text("2", key: "2"), text("3", key: "3")]))
        #expect(reconcile(old, new) == .update(attributes: nil, children: [
            .create(text("1", key: "1")), .reuse(from: 0, patch: nil), .reuse(from: 1, patch: nil),
        ]))
        #expect(mountAndPatch(old, new).built == 1)
    }

    @Test func removingAChildReusesTheRest() {
        let old = Node(.row([text("1", key: "1"), text("2", key: "2"), text("3", key: "3")]))
        let new = Node(.row([text("1", key: "1"), text("3", key: "3")]))
        #expect(reconcile(old, new) == .update(attributes: nil, children: [.reuse(from: 0, patch: nil), .reuse(from: 2, patch: nil)]))
        #expect(mountAndPatch(old, new).built == 0)
    }

    @Test func unkeyedChildrenMatchByPositionAndKind() {
        let old = Node(.row([text("a"), Node(.icon("bolt")), text("b")]))
        let new = Node(.row([Node(.icon("bolt")), text("a"), text("b")]))
        #expect(reconcile(old, new) == .update(attributes: nil, children: [
            .create(Node(.icon("bolt"))),
            .create(text("a")),
            .reuse(from: 2, patch: nil),
        ]))
        #expect(mountAndPatch(old, new).built == 2)
    }

    @Test func clearingAStyleIsAnAttributeChange() {
        let patch = reconcile(text("a", style: "active"), text("a"))
        #expect(patch == .update(attributes: Attributes(value: "a", style: nil, action: nil), children: nil))
    }

    @Test func anyPatchTurnsTheOldTreeIntoTheNewOne() {
        var random = SeededRandom(seed: 7)
        for _ in 0..<500 {
            let old = randomTree(&random, depth: 0)
            let new = randomTree(&random, depth: 0)
            _ = mountAndPatch(old, new)
        }
    }

    private func randomTree(_ random: inout SeededRandom, depth: Int) -> Node {
        let style = ["a", "b", nil][random.next(3)]
        let key = random.next(3) == 0 ? ["k1", "k2", "k3", "k4"][random.next(4)] : nil
        switch depth < 3 ? random.next(5) : 2 + random.next(3) {
        case 0, 1:
            var children: [Node] = []
            var keys = Set<String>()
            for _ in 0..<random.next(5) {
                let child = randomTree(&random, depth: depth + 1)
                if let key = child.key, !keys.insert(key).inserted { continue }
                children.append(child)
            }
            return Node(random.next(2) == 0 ? .row(children) : .column(children), key: key, style: style)
        case 2: return Node(.text(["1", "2", "3"][random.next(3)]), key: key, style: style, action: random.next(2) == 0 ? "go" : nil)
        case 3: return Node(.icon(["bolt", "wifi"][random.next(2)]), key: key, style: style)
        default: return Node(.spacer, key: key)
        }
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}
