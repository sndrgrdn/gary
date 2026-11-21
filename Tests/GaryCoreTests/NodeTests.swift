import Foundation
import Testing
@testable import GaryCore

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

    @Test func parsesTheControlsAndStyleProperties() throws {
        let node = try parse("""
        {"type":"column","style":"panel","padding":8,"gap":4,"background":"#000000","children":[
          {"type":"button","action":"open","hover":"selected","radius":6,"children":[{"type":"image","path":"/Applications/Safari.app","width":24,"height":24}]},
          {"type":"slider","value":0.25,"action":"volume"},
          {"type":"progress","value":1.5,"color":"accent","opacity":0.5},
          {"type":"input","value":"saf","placeholder":"Search","change":"query","submit":"run","fontSize":16},
          {"type":"scroll","height":200,"children":[{"type":"text","text":"a"}]}
        ]}
        """)
        #expect(node == Node(.column([
            Node(.button([Node(.image("/Applications/Safari.app"), props: StyleProps(width: 24, height: 24))], hover: "selected"),
                 action: "open", props: StyleProps(radius: 6)),
            Node(.slider(0.25), action: "volume"),
            Node(.progress(1), props: StyleProps(opacity: 0.5, color: "accent")),
            Node(.input(Node.Input(value: "saf", placeholder: "Search", change: "query", submit: "run")), props: StyleProps(fontSize: 16)),
            Node(.scroll([Node(.text("a"))]), props: StyleProps(height: 200)),
        ]), style: "panel", props: StyleProps(padding: 8, gap: 4, background: "#000000")))
        #expect(try parse(#"{"type":"input"}"#) == Node(.input(Node.Input(value: ""))))
    }

    @Test func nullOptionalFieldsAreAbsent() throws {
        #expect(try parse(#"{"type":"text","text":"a","style":null,"key":null}"#) == Node(.text("a")))
    }

    @Test func rejectsMalformedNodesWithTheirPath() {
        let cases: [(String, NodeError)] = [
            (#"[]"#, NodeError(path: "root", reason: "node must be an object")),
            (#"{"text":"a"}"#, NodeError(path: "root", reason: "type is required")),
            (#"{"type":"knob"}"#, NodeError(path: "root", reason: "unknown type \"knob\"")),
            (#"{"type":"slider"}"#, NodeError(path: "root", reason: "value must be a number from 0 to 1")),
            (#"{"type":"image"}"#, NodeError(path: "root", reason: "path is required")),
            (#"{"type":"spacer","width":-1}"#, NodeError(path: "root", reason: "width must be a non-negative number")),
            (#"{"type":"spacer","opacity":2}"#, NodeError(path: "root", reason: "opacity must be between 0 and 1")),
            (##"{"type":"spacer","color":"#12"}"##, NodeError(path: "root", reason: "color must be \(ColorExpr.syntax)")),
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

private final class FakeView {
    var own: Node
    var children: [FakeView]

    init(_ node: Node) {
        own = node.own
        children = node.children.map(FakeView.init)
    }

    func apply(_ patch: Patch) -> FakeView {
        switch patch {
        case .replace(let node):
            return FakeView(node)
        case .update(let own, let children):
            if let own { self.own = own }
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
    var node: Node { own.with(children: children.map(\.node)) }
}

struct ReconcileTests {
    private func text(_ value: String, key: String? = nil, style: String? = nil) -> Node {
        Node(.text(value), key: key, style: style)
    }

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
        #expect(reconcile(old, new) == .update(own: nil, children: [
            .reuse(from: 0, patch: .update(own: text("12:01"), children: nil)),
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
        #expect(reconcile(old, new) == .update(own: nil, children: [
            .create(text("1", key: "1")), .reuse(from: 0, patch: nil), .reuse(from: 1, patch: nil),
        ]))
        #expect(mountAndPatch(old, new).built == 1)
    }

    @Test func removingAChildReusesTheRest() {
        let old = Node(.row([text("1", key: "1"), text("2", key: "2"), text("3", key: "3")]))
        let new = Node(.row([text("1", key: "1"), text("3", key: "3")]))
        #expect(reconcile(old, new) == .update(own: nil, children: [.reuse(from: 0, patch: nil), .reuse(from: 2, patch: nil)]))
        #expect(mountAndPatch(old, new).built == 0)
    }

    @Test func unkeyedChildrenMatchByPositionAndKind() {
        let old = Node(.row([text("a"), Node(.icon("bolt")), text("b")]))
        let new = Node(.row([Node(.icon("bolt")), text("a"), text("b")]))
        #expect(reconcile(old, new) == .update(own: nil, children: [
            .create(Node(.icon("bolt"))),
            .create(text("a")),
            .reuse(from: 2, patch: nil),
        ]))
        #expect(mountAndPatch(old, new).built == 2)
    }

    @Test func clearingAStyleIsAnAttributeChange() {
        let patch = reconcile(text("a", style: "active"), text("a"))
        #expect(patch == .update(own: text("a"), children: nil))
    }

    @Test func aControlValueOrPropertyChangeUpdatesInPlaceAndKeepsChildren() {
        let row = [Node(.image("/a.app"), key: "icon"), text("Safari", key: "name")]
        let old = Node(.button(row, hover: nil), key: "r1", props: StyleProps(background: "selected"))
        let new = Node(.button(row, hover: nil), key: "r1")
        #expect(reconcile(old, new) == .update(own: new.own, children: nil))
        let slider = reconcile(Node(.slider(0.2), action: "v"), Node(.slider(0.6), action: "v"))
        #expect(slider == .update(own: Node(.slider(0.6), action: "v"), children: nil))
        let result = mountAndPatch(Node(.scroll(row)), Node(.scroll([text("Safari", key: "name")])))
        #expect(result.built == 0)
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
        let props = random.next(3) == 0 ? StyleProps(padding: Double(random.next(3))) : StyleProps()
        switch depth < 3 ? random.next(5) : 2 + random.next(4) {
        case 0, 1:
            var children: [Node] = []
            var keys = Set<String>()
            for _ in 0..<random.next(5) {
                let child = randomTree(&random, depth: depth + 1)
                if let key = child.key, !keys.insert(key).inserted { continue }
                children.append(child)
            }
            let containers: [Node.Content] = [.row(children), .column(children), .scroll(children), .button(children, hover: nil)]
            return Node(containers[random.next(4)], key: key, style: style, props: props)
        case 2: return Node(.text(["1", "2", "3"][random.next(3)]), key: key, style: style, action: random.next(2) == 0 ? "go" : nil)
        case 3: return Node(.icon(["bolt", "wifi"][random.next(2)]), key: key, style: style, props: props)
        case 4: return Node(random.next(2) == 0 ? .slider(Double(random.next(3)) / 2) : .progress(0.5), key: key)
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
