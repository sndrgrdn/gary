import Foundation

public struct Node: Equatable, Sendable {
    public struct Input: Equatable, Sendable {
        public var value: String
        public var placeholder: String?
        public var change: String?
        public var submit: String?

        public init(value: String, placeholder: String? = nil, change: String? = nil, submit: String? = nil) {
            self.value = value
            self.placeholder = placeholder
            self.change = change
            self.submit = submit
        }
    }

    public enum Content: Equatable, Sendable {
        case row([Node])
        case column([Node])
        case stack([Node])
        case scroll([Node], reveal: String?)
        case button([Node], hover: String?)
        case text(String)
        case icon(String)
        case image(String)
        case slider(Double)
        case progress(Double)
        case input(Input)
        case spacer
        case shape(Shape)
        case chart(Chart)
        case grid([Node], columns: Int)
    }

    public enum Kind: String, CaseIterable, Sendable {
        case row, column, stack, scroll, button, text, icon, image, slider, progress, input, spacer, shape, chart, grid
    }

    public var content: Content
    public var key: String?
    public var style: String?
    public var actions: [Gesture: String]
    public var tooltip: String?
    public var props: StyleProps
    public var hovered: StyleProps?
    public var pressed: StyleProps?

    public init(
        _ content: Content,
        key: String? = nil,
        style: String? = nil,
        actions: [Gesture: String] = [:],
        tooltip: String? = nil,
        props: StyleProps = StyleProps(),
        hovered: StyleProps? = nil,
        pressed: StyleProps? = nil,
    ) {
        self.content = content
        self.key = key
        self.style = style
        self.actions = actions
        self.tooltip = tooltip
        self.props = props
        self.hovered = hovered
        self.pressed = pressed
    }

    public var kind: Kind {
        switch content {
        case .row: .row
        case .column: .column
        case .stack: .stack
        case .scroll: .scroll
        case .button: .button
        case .text: .text
        case .icon: .icon
        case .image: .image
        case .slider: .slider
        case .progress: .progress
        case .input: .input
        case .spacer: .spacer
        case .shape: .shape
        case .chart: .chart
        case .grid: .grid
        }
    }

    public var children: [Node] {
        switch content {
        case let .row(children), let .column(children), let .stack(children), let .scroll(children, _), let .button(children, _),
             let .grid(children, _): children
        case .text, .icon, .image, .slider, .progress, .input, .spacer, .shape, .chart: []
        }
    }

    public func with(children: [Node]) -> Node {
        var node = self
        switch content {
        case .row: node.content = .row(children)
        case .column: node.content = .column(children)
        case .stack: node.content = .stack(children)
        case let .scroll(_, reveal): node.content = .scroll(children, reveal: reveal)
        case let .button(_, hover): node.content = .button(children, hover: hover)
        case let .grid(_, columns): node.content = .grid(children, columns: columns)
        case .text, .icon, .image, .slider, .progress, .input, .spacer, .shape, .chart: break
        }
        return node
    }

    public enum ChildID: Hashable, Sendable {
        case key(String)
        case position(Int)
    }

    public var childIDs: [ChildID] {
        var position = 0
        return children.map { child in
            if let key = child.key {
                return .key(key)
            }
            defer { position += 1 }
            return .position(position)
        }
    }

    public func resolvingImages(against folder: URL) throws -> Node {
        if case let .image(path) = content, !path.hasPrefix("/"), !path.hasPrefix("~") {
            guard let resolved = absolutePath(path, home: "", folder: folder.path) else {
                throw NodeError(path: key ?? "image", reason: "image path \"\(path)\" must stay inside the plugin folder")
            }
            var node = self
            node.content = .image(resolved)
            return node
        }
        return try with(children: children.map { try $0.resolvingImages(against: folder) })
    }

    public var revealedChild: Int? {
        guard case let .scroll(children, reveal) = content else { return nil }
        return children.firstIndex { child in reveal.map { child.key == $0 } ?? (child.style == "selected") }
    }
}

public struct NodeError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String

    public var description: String {
        "\(path): \(reason)"
    }
}

public extension Node {
    static let maxDepth = 16
    static let maxNodes = 1000

    static func parse(_ json: JSON) throws -> Node {
        var count = 0
        return try NodeReader.node(json, path: "root", depth: 1, count: &count)
    }

    static func parse(_ data: Data) throws -> Node {
        guard let json = try? JSON.parse(data) else { throw NodeError(path: "root", reason: "render did not return a JSON value") }
        return try parse(json)
    }
}

struct NodeReader {
    let fields: [String: JSON]
    let path: String
    let depth: Int
    var count: Int

    static func node(_ json: JSON, path: String, depth: Int, count: inout Int) throws -> Node {
        count += 1
        guard count <= Node.maxNodes else { throw NodeError(path: path, reason: "tree has more than \(Node.maxNodes) nodes") }
        guard depth <= Node.maxDepth else { throw NodeError(path: path, reason: "tree is deeper than \(Node.maxDepth)") }
        guard case let .object(fields) = json else { throw NodeError(path: path, reason: "node must be an object") }
        var reader = NodeReader(fields: fields, path: path, depth: depth, count: count)
        let type = try reader.required("type")
        guard let kind = Node.Kind(rawValue: type), let content = contentReaders[kind] else { throw reader.fail("unknown type \"\(type)\"") }
        let node = try Node(
            content(&reader),
            key: reader.string("key"),
            style: reader.string("style"),
            actions: reader.actions(),
            tooltip: reader.string("tooltip"),
            props: reader.props(fields, ""),
            hovered: reader.state("hovered"),
            pressed: reader.state("pressed"),
        )
        count = reader.count
        return node
    }

    private static let contentReaders: [Node.Kind: @Sendable (inout Self) throws -> Node.Content] = [
        .row: { try .row($0.children()) },
        .column: { try .column($0.children()) },
        .stack: { try .stack($0.children()) },
        .scroll: { try .scroll($0.children(), reveal: $0.string("reveal")) },
        .button: { try .button($0.children(), hover: $0.string("hover")) },
        .text: { try .text($0.required("text")) },
        .icon: { try .icon($0.required("symbol")) },
        .image: { try .image($0.required("path")) },
        .slider: { try .slider($0.fraction()) },
        .progress: { try .progress($0.fraction()) },
        .input: { try .input($0.input()) },
        .spacer: { _ in .spacer },
        .shape: { try .shape($0.shape()) },
        .chart: { try .chart($0.chart()) },
        .grid: { try .grid($0.children(), columns: $0.columns()) },
    ]

    func fail(_ reason: String) -> NodeError {
        NodeError(path: path, reason: reason)
    }

    func string(_ name: String) throws -> String? {
        switch fields[name] {
        case nil, .null: nil
        case let .string(value)?: value
        case let .number(value)? where name == "text" || name == "value": Self.text(value)
        default: throw fail("\(name) must be a string")
        }
    }

    func actions() throws -> [Node.Gesture: String] {
        try Node.Gesture.allCases.reduce(into: [:]) { actions, gesture in actions[gesture] = try string(gesture.rawValue) }
    }

    func required(_ name: String) throws -> String {
        guard let value = try string(name) else { throw fail("\(name) is required") }
        return value
    }

    func fraction() throws -> Double {
        guard let value = fields["value"]?.number, value.isFinite else { throw fail("value must be a number from 0 to 1") }
        return min(1, max(0, value))
    }

    func input() throws -> Node.Input {
        try Node.Input(value: string("value") ?? "", placeholder: string("placeholder"), change: string("change"), submit: string("submit"))
    }

    mutating func children() throws -> [Node] {
        guard let items = fields["children"] else { return [] }
        guard case let .array(array) = items else { throw fail("children must be an array") }
        let nodes = try array.enumerated().map { index, item in
            try Self.node(item, path: "\(path).children[\(index)]", depth: depth + 1, count: &count)
        }
        var seen = Set<String>()
        for key in nodes.compactMap(\.key) where !seen.insert(key).inserted {
            throw fail("duplicate key \"\(key)\" among children")
        }
        return nodes
    }

    func props(_ fields: [String: JSON], _ prefix: String) throws -> StyleProps {
        try StyleProps.parse(fields) { field, reason in NodeError(path: path, reason: "\(prefix)\(field) \(reason)") }
    }

    func state(_ name: String) throws -> StyleProps? {
        guard let value = fields[name], value != .null else { return nil }
        guard let object = value.object else { throw fail("\(name) must be an object of style properties") }
        return try props(object, "\(name).")
    }

    static func text(_ number: Double) -> String {
        guard number.rounded() == number, abs(number) < 1e15 else { return String(number) }
        return String(Int64(number))
    }
}
