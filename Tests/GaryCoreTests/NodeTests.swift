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
          {"type":"scroll","height":200,"reveal":"a","children":[{"type":"text","text":"a"}]}
        ]}
        """)
        #expect(node == Node(.column([
            Node(.button([Node(.image("/Applications/Safari.app"), props: StyleProps(width: 24, height: 24))], hover: "selected"),
                 action: "open", props: StyleProps(radius: 6)),
            Node(.slider(0.25), action: "volume"),
            Node(.progress(1), props: StyleProps(opacity: 0.5, color: "accent")),
            Node(.input(Node.Input(value: "saf", placeholder: "Search", change: "query", submit: "run")), props: StyleProps(fontSize: 16)),
            Node(.scroll([Node(.text("a"))], reveal: "a"), props: StyleProps(height: 200)),
        ]), style: "panel", props: StyleProps(padding: Insets(8), gap: 4, background: "#000000")))
        #expect(try parse(#"{"type":"input"}"#) == Node(.input(Node.Input(value: ""))))
    }

    @Test func parsesPaddingPerSideASignedOffsetAlignmentAnimationAndMaterial() throws {
        func props(_ fields: String) throws -> StyleProps { try parse(#"{"type":"text","text":"a",\#(fields)}"#).props }
        #expect(try props(#""padding":4"#).padding == Insets(4))
        #expect(try props(#""padding":[2,6]"#).padding == Insets(top: 2, right: 6, bottom: 2, left: 6))
        #expect(try props(#""padding":[1,2,3,4]"#).padding == Insets(top: 1, right: 2, bottom: 3, left: 4))
        #expect(try props(#""offset":-1.5,"align":"center","minWidth":51"#) == StyleProps(minWidth: 51, offset: -1.5, align: .center))
        let reason = "padding must be \(Insets.syntax)"
        for bad in [#""padding":[1,2,3]"#, #""padding":[1,-2]"#, #""padding":"4""#] {
            #expect(throws: NodeError(path: "root", reason: reason), "\(bad)") { try props(bad) }
        }
        #expect(try props(#""animation":"spring","material":"glass""#) == StyleProps(animation: .spring, material: .glass))
        #expect(throws: NodeError(path: "root", reason: "align must be one of \"leading\", \"center\", \"trailing\"")) { try props(#""align":"left""#) }
        #expect(throws: NodeError(path: "root", reason: "material must be one of \"vibrant\", \"glass\", \"none\"")) { try props(#""material":"blur""#) }
        #expect(throws: NodeError(path: "root", reason: "offset must be a number")) { try props(#""offset":"1""#) }
    }

    @Test func aScrollRevealsTheChildItNamesOrElseTheFirstSelectedOne() throws {
        let rows = (0..<12).map { index in Node(.text("\(index)"), key: "r\(index)", style: index == 9 || index == 11 ? "selected" : nil) }
        #expect(Node(.scroll(rows, reveal: nil)).revealedChild == 9)
        #expect(Node(.scroll(rows, reveal: "r3")).revealedChild == 3)
        #expect(Node(.scroll(rows, reveal: "gone")).revealedChild == nil)
        #expect(Node(.scroll(Array(rows.prefix(8)), reveal: nil)).revealedChild == nil)
        #expect(Node(.column(rows)).revealedChild == nil)
    }

    @Test func keyedChildrenAreIdentifiedByKeyAndTheRestByTheirPositionAmongUnkeyedSiblings() {
        let row = Node(.row([Node(.text("a")), Node(.text("b"), key: "b"), Node(.icon("bolt")), Node(.spacer, key: "gap")]))
        #expect(row.childIDs == [.position(0), .key("b"), .position(1), .key("gap")])
        #expect(Node(.text("a")).childIDs == [])
    }

    @Test func relativeImagePathsResolveInsideThePluginFolder() throws {
        let tree = try parse(#"{"type":"row","children":[{"type":"image","path":"icons/logo.png"},{"type":"image","path":"../../Gary.icns"},{"type":"image","path":"~/a.png"},{"type":"image","path":"/b.png"}]}"#)
        let resolved = tree.resolvingImages(against: URL(fileURLWithPath: "/App/Resources/plugins/onboarding"))
        #expect(resolved.children.map(\.content) == [.image("/App/Resources/plugins/onboarding/icons/logo.png"), .image("/App/Resources/Gary.icns"), .image("~/a.png"), .image("/b.png")])
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

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}
