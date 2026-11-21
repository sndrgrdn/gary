import Foundation
@testable import GaryCore
import Testing

struct NodeTests {
    private func parse(_ text: String) throws -> Node {
        try Node.parse(Data(text.utf8))
    }

    @Test func `parses every kind with optional fields`() throws {
        let node = try parse("""
        {"type":"row","style":"bar","children":[
          {"type":"text","text":"1","key":"ws1","style":"active","action":"1"},
          {"type":"icon","symbol":"battery.100"},
          {"type":"spacer"},
          {"type":"column","children":[{"type":"text","text":42}]}
        ]}
        """)
        #expect(node == Node(.row([
            Node(.text("1"), key: "ws1", style: "active", actions: [.click: "1"]),
            Node(.icon("battery.100")),
            Node(.spacer),
            Node(.column([Node(.text("42"))])),
        ]), style: "bar"))
    }

    @Test func `parses the controls and style properties`() throws {
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
            Node(
                .button([Node(.image("/Applications/Safari.app"), props: StyleProps(width: 24, height: 24))], hover: "selected"),
                actions: [.click: "open"],
                props: StyleProps(radius: 6),
            ),
            Node(.slider(0.25), actions: [.click: "volume"]),
            Node(.progress(1), props: StyleProps(opacity: 0.5, color: "accent")),
            Node(.input(Node.Input(value: "saf", placeholder: "Search", change: "query", submit: "run")), props: StyleProps(fontSize: 16)),
            Node(.scroll([Node(.text("a"))], reveal: "a"), props: StyleProps(height: 200)),
        ]), style: "panel", props: StyleProps(padding: Insets(8), gap: 4, background: "#000000")))
        #expect(try parse(#"{"type":"input"}"#) == Node(.input(Node.Input(value: ""))))
    }

    @Test func `parses padding per side A signed offset alignment animation and material`() throws {
        func props(_ fields: String) throws -> StyleProps {
            try parse(#"{"type":"text","text":"a",\#(fields)}"#).props
        }
        #expect(try props(#""padding":4"#).padding == Insets(4))
        #expect(try props(#""padding":[2,6]"#).padding == Insets(top: 2, right: 6, bottom: 2, left: 6))
        #expect(try props(#""padding":[1,2,3,4]"#).padding == Insets(top: 1, right: 2, bottom: 3, left: 4))
        #expect(try props(#""offset":-1.5,"align":"center","minWidth":51"#) == StyleProps(minWidth: 51, offset: -1.5, align: .center))
        let reason = "padding must be \(Insets.syntax)"
        for bad in [#""padding":[1,2,3]"#, #""padding":[1,-2]"#, #""padding":"4""#] {
            #expect(throws: NodeError(path: "root", reason: reason), "\(bad)") { try props(bad) }
        }
        #expect(try props(#""animation":"spring","material":"glass""#) == StyleProps(animation: .spring, material: .glass))
        #expect(try props(#""material":"vibrant","colorScheme":"dark""#) == StyleProps(material: .vibrant, colorScheme: .dark))
        #expect(throws: NodeError(path: "root", reason: "colorScheme must be one of \"dark\", \"light\"")) { try props(#""colorScheme":"auto""#) }
        #expect(throws: NodeError(path: "root", reason: "align must be one of \"leading\", \"center\", \"trailing\"")) {
            try props(#""align":"left""#)
        }
        #expect(throws: NodeError(path: "root", reason: "material must be one of \"vibrant\", \"glass\", \"none\"")) {
            try props(#""material":"blur""#)
        }
        #expect(throws: NodeError(path: "root", reason: "offset must be a number")) { try props(#""offset":"1""#) }
    }

    @Test func `parses A stack with placed layered and decorated children`() throws {
        let node = try parse("""
        {"type":"stack","width":768,"height":475,"animation":"smooth","duration":0.35,"children":[
          {"type":"stack","key":"card","x":-94.5,"y":17.5,"zIndex":100,"scale":0.97,"radius":12,"clip":true,"transition":"opacity",
           "border":{"color":"accent","width":2.5},"shadow":{"color":"alpha(#000000, 0.45)","radius":30,"y":18},
           "pressed":{"scale":0.97},"children":[
            {"type":"image","path":"/p.jpg","width":768,"height":475,"fit":"fill"},
            {"type":"row","background":"background","opacity":0.42,"hovered":{"opacity":0.2}}
          ]}
        ]}
        """)
        #expect(node == Node(.stack([
            Node(
                .stack([
                    Node(.image("/p.jpg"), props: StyleProps(width: 768, height: 475, fit: .fill)),
                    Node(.row([]), props: StyleProps(opacity: 0.42, background: "background"), hovered: StyleProps(opacity: 0.2)),
                ]),
                key: "card",
                props: StyleProps(
                    radius: 12,
                    x: -94.5,
                    y: 17.5,
                    zIndex: 100,
                    scale: 0.97,
                    transition: .opacity,
                    clip: true,
                    shadow: Shadow(color: "alpha(#000000, 0.45)", radius: 30, y: 18),
                    border: Border(
                        color: "accent",
                        width: 2.5,
                    ),
                ),
                pressed: StyleProps(scale: 0.97),
            ),
        ]), props: StyleProps(width: 768, height: 475, animation: .smooth, duration: 0.35)))
        #expect(try parse(#"{"type":"row","border":{"color":"accent"},"shadow":{"color":"accent"}}"#).props
            == StyleProps(shadow: Shadow(color: "accent"), border: Border(color: "accent", width: 1)))
    }

    @Test func `rejects malformed stack and decoration properties`() {
        let cases: [(String, String)] = [
            (#""x":"1""#, "x must be a number"),
            (#""zIndex":true"#, "zIndex must be a number"),
            (#""scale":-1"#, "scale must be a non-negative number"),
            (#""duration":-0.1"#, "duration must be a non-negative number"),
            (#""clip":1"#, "clip must be true or false"),
            (#""transition":"slide""#, "transition must be one of \"opacity\", \"scale\", \"none\""),
            (#""fit":"cover""#, "fit must be one of \"fit\", \"fill\""),
            (#""border":"accent""#, "border must be an object with color and width"),
            (#""border":{"width":1}"#, "border.color must be \(ColorExpr.syntax)"),
            (#""shadow":{"color":"accent","radius":-1}"#, "shadow.radius must be a non-negative number"),
            (#""shadow":{"color":"accent","y":"down"}"#, "shadow.y must be a number"),
            (#""hovered":"dim""#, "hovered must be an object of style properties"),
            (#""pressed":{"scale":"small"}"#, "pressed.scale must be a non-negative number"),
        ]
        for (fields, reason) in cases {
            #expect(throws: NodeError(path: "root", reason: reason), "\(fields)") { try parse(#"{"type":"stack",\#(fields)}"#) }
        }
    }

    @Test func `an image decodes at the largest size its fit shows without upscaling`() {
        let wide = CGSize(width: 2048, height: 1024)
        let frame = CGSize(width: 1536, height: 950)
        #expect(ImageFit.fill.pixelSize(source: wide, frame: frame) == 1900)
        #expect(ImageFit.fit.pixelSize(source: wide, frame: frame) == 1536)
        #expect(ImageFit.fill.pixelSize(source: CGSize(width: 1024, height: 633), frame: frame) == 1024)
        #expect(ImageFit.fit.pixelSize(source: .zero, frame: CGSize(width: 32, height: 30)) == 32)
    }

    @Test func `a scroll reveals the child it names or else the first selected one`() {
        let rows = (0..<12).map { index in Node(.text("\(index)"), key: "r\(index)", style: index == 9 || index == 11 ? "selected" : nil) }
        #expect(Node(.scroll(rows, reveal: nil)).revealedChild == 9)
        #expect(Node(.scroll(rows, reveal: "r3")).revealedChild == 3)
        #expect(Node(.scroll(rows, reveal: "gone")).revealedChild == nil)
        #expect(Node(.scroll(Array(rows.prefix(8)), reveal: nil)).revealedChild == nil)
        #expect(Node(.column(rows)).revealedChild == nil)
    }

    @Test func `keyed children are identified by key and the rest by their position among unkeyed siblings`() {
        let row = Node(.row([Node(.text("a")), Node(.text("b"), key: "b"), Node(.icon("bolt")), Node(.spacer, key: "gap")]))
        #expect(row.childIDs == [.position(0), .key("b"), .position(1), .key("gap")])
        #expect(Node(.text("a")).childIDs.isEmpty)
    }

    @Test func `relative image paths resolve inside the plugin folder`() throws {
        let tree = try parse(#"""
        {"type":"row","children":[{"type":"image","path":"icons/logo.png"},{"type":"image","path":"art/../Gary.icns"},\#
        {"type":"image","path":"~/a.png"},{"type":"image","path":"/b.png"}]}
        """#)
        let resolved = try tree.resolvingImages(against: URL(fileURLWithPath: "/App/Resources/plugins/onboarding"))
        #expect(resolved.children.map(\.content) == [
            .image("/App/Resources/plugins/onboarding/icons/logo.png"),
            .image("/App/Resources/plugins/onboarding/Gary.icns"),
            .image("~/a.png"),
            .image("/b.png"),
        ])
    }

    @Test func `an image path that leaves the plugin folder is an error`() throws {
        let tree = try parse(#"{"type":"image","key":"icon","path":"../../Gary.icns"}"#)
        #expect(throws: NodeError(path: "icon", reason: "image path \"../../Gary.icns\" must stay inside the plugin folder")) {
            try tree.resolvingImages(against: URL(fileURLWithPath: "/App/Resources/plugins/onboarding"))
        }
    }

    @Test func `null optional fields are absent`() throws {
        #expect(try parse(#"{"type":"text","text":"a","style":null,"key":null}"#) == Node(.text("a")))
    }

    @Test func `rejects malformed nodes with their path`() {
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
            (
                #"{"type":"row","children":[{"type":"text","text":"a"},{"type":"text"}]}"#,
                NodeError(path: "root.children[1]", reason: "text is required"),
            ),
            (
                #"{"type":"row","children":[{"type":"spacer","key":"k"},{"type":"spacer","key":"k"}]}"#,
                NodeError(path: "root", reason: "duplicate key \"k\" among children"),
            ),
        ]
        for (text, error) in cases {
            #expect(throws: error, "\(text)") { try parse(text) }
        }
        #expect(throws: NodeError(path: "root", reason: "render did not return a JSON value")) { try parse("undefined") }
    }

    @Test func `bounds depth and size`() throws {
        var deep = #"{"type":"spacer"}"#
        for _ in 1..<Node.maxDepth {
            deep = #"{"type":"row","children":[\#(deep)]}"#
        }
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
    init(seed: UInt64) {
        state = seed
    }

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }
}
