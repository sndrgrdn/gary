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
    }

    public enum Kind: String, CaseIterable, Sendable {
        case row, column, stack, scroll, button, text, icon, image, slider, progress, input, spacer
    }

    public var content: Content
    public var key: String?
    public var style: String?
    public var action: String?
    public var props: StyleProps
    public var hovered: StyleProps?
    public var pressed: StyleProps?

    public init(
        _ content: Content,
        key: String? = nil,
        style: String? = nil,
        action: String? = nil,
        props: StyleProps = StyleProps(),
        hovered: StyleProps? = nil,
        pressed: StyleProps? = nil,
    ) {
        self.content = content
        self.key = key
        self.style = style
        self.action = action
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
        }
    }

    public var children: [Node] {
        switch content {
        case let .row(children), let .column(children), let .stack(children), let .scroll(children, _), let .button(children, _): children
        case .text, .icon, .image, .slider, .progress, .input, .spacer: []
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
        case .text, .icon, .image, .slider, .progress, .input, .spacer: break
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

    public func resolvingImages(against folder: URL) -> Node {
        if case let .image(path) = content, !path.hasPrefix("/"), !path.hasPrefix("~") {
            var node = self
            node.content = .image(folder.appending(path: path).standardizedFileURL.path)
            return node
        }
        return with(children: children.map { $0.resolvingImages(against: folder) })
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
        return try parse(json, path: "root", depth: 1, count: &count)
    }

    static func parse(_ data: Data) throws -> Node {
        guard let json = try? JSON.parse(data) else { throw NodeError(path: "root", reason: "render did not return a JSON value") }
        return try parse(json)
    }

    private static func parse(_ json: JSON, path: String, depth: Int, count: inout Int) throws -> Node {
        func fail(_ reason: String) -> NodeError {
            NodeError(path: path, reason: reason)
        }
        count += 1
        guard count <= maxNodes else { throw fail("tree has more than \(maxNodes) nodes") }
        guard depth <= maxDepth else { throw fail("tree is deeper than \(maxDepth)") }
        guard case let .object(fields) = json else { throw fail("node must be an object") }

        func string(_ name: String) throws -> String? {
            switch fields[name] {
            case nil, .null?: nil
            case let .string(value)?: value
            case let .number(value)? where name == "text" || name == "value":
                value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
            default: throw fail("\(name) must be a string")
            }
        }
        func required(_ name: String) throws -> String {
            guard let value = try string(name) else { throw fail("\(name) is required") }
            return value
        }
        func fraction() throws -> Double {
            guard let value = fields["value"]?.number, value.isFinite else { throw fail("value must be a number from 0 to 1") }
            return min(1, max(0, value))
        }
        func children() throws -> [Node] {
            guard let items = fields["children"] else { return [] }
            guard case let .array(array) = items else { throw fail("children must be an array") }
            let nodes = try array.enumerated().map { index, item in
                try parse(item, path: "\(path).children[\(index)]", depth: depth + 1, count: &count)
            }
            var seen = Set<String>()
            for key in nodes.compactMap(\.key) where !seen.insert(key).inserted {
                throw fail("duplicate key \"\(key)\" among children")
            }
            return nodes
        }

        let type = try required("type")
        let content: Content
        switch Kind(rawValue: type) {
        case .row?: content = try .row(children())
        case .column?: content = try .column(children())
        case .stack?: content = try .stack(children())
        case .scroll?: content = try .scroll(children(), reveal: string("reveal"))
        case .button?: content = try .button(children(), hover: string("hover"))
        case .text?: content = try .text(required("text"))
        case .icon?: content = try .icon(required("symbol"))
        case .image?: content = try .image(required("path"))
        case .slider?: content = try .slider(fraction())
        case .progress?: content = try .progress(fraction())
        case .input?:
            content = try .input(Input(
                value: string("value") ?? "",
                placeholder: string("placeholder"),
                change: string("change"),
                submit: string("submit"),
            ))
        case .spacer?: content = .spacer
        case nil: throw fail("unknown type \"\(type)\"")
        }
        func props(_ fields: [String: JSON], _ prefix: String) throws -> StyleProps {
            try StyleProps.parse(fields) { field, reason in NodeError(path: path, reason: "\(prefix)\(field) \(reason)") }
        }
        func state(_ name: String) throws -> StyleProps? {
            guard let value = fields[name], value != .null else { return nil }
            guard let object = value.object else { throw fail("\(name) must be an object of style properties") }
            return try props(object, "\(name).")
        }
        return try Node(
            content,
            key: string("key"),
            style: string("style"),
            action: string("action"),
            props: props(fields, ""),
            hovered: state("hovered"),
            pressed: state("pressed"),
        )
    }
}
