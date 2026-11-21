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

    public init(_ content: Content, key: String? = nil, style: String? = nil, action: String? = nil, props: StyleProps = StyleProps(),
                hovered: StyleProps? = nil, pressed: StyleProps? = nil) {
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
        case .row: return .row
        case .column: return .column
        case .stack: return .stack
        case .scroll: return .scroll
        case .button: return .button
        case .text: return .text
        case .icon: return .icon
        case .image: return .image
        case .slider: return .slider
        case .progress: return .progress
        case .input: return .input
        case .spacer: return .spacer
        }
    }

    public var children: [Node] {
        switch content {
        case .row(let children), .column(let children), .stack(let children), .scroll(let children, _), .button(let children, _): return children
        case .text, .icon, .image, .slider, .progress, .input, .spacer: return []
        }
    }

    public func with(children: [Node]) -> Node {
        var node = self
        switch content {
        case .row: node.content = .row(children)
        case .column: node.content = .column(children)
        case .stack: node.content = .stack(children)
        case .scroll(_, let reveal): node.content = .scroll(children, reveal: reveal)
        case .button(_, let hover): node.content = .button(children, hover: hover)
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
            if let key = child.key { return .key(key) }
            defer { position += 1 }
            return .position(position)
        }
    }

    public func resolvingImages(against folder: URL) -> Node {
        if case .image(let path) = content, !path.hasPrefix("/"), !path.hasPrefix("~") {
            var node = self
            node.content = .image(folder.appending(path: path).standardizedFileURL.path)
            return node
        }
        return with(children: children.map { $0.resolvingImages(against: folder) })
    }

    public var revealedChild: Int? {
        guard case .scroll(let children, let reveal) = content else { return nil }
        return children.firstIndex { child in reveal.map { child.key == $0 } ?? (child.style == "selected") }
    }
}

public struct NodeError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String

    public var description: String { "\(path): \(reason)" }
}

extension Node {
    public static let maxDepth = 16
    public static let maxNodes = 1000

    public static func parse(_ json: JSON) throws -> Node {
        var count = 0
        return try parse(json, path: "root", depth: 1, count: &count)
    }

    public static func parse(_ data: Data) throws -> Node {
        guard let json = try? JSON.parse(data) else { throw NodeError(path: "root", reason: "render did not return a JSON value") }
        return try parse(json)
    }

    private static func parse(_ json: JSON, path: String, depth: Int, count: inout Int) throws -> Node {
        func fail(_ reason: String) -> NodeError { NodeError(path: path, reason: reason) }
        count += 1
        guard count <= maxNodes else { throw fail("tree has more than \(maxNodes) nodes") }
        guard depth <= maxDepth else { throw fail("tree is deeper than \(maxDepth)") }
        guard case .object(let fields) = json else { throw fail("node must be an object") }

        func string(_ name: String) throws -> String? {
            switch fields[name] {
            case nil, .null?: return nil
            case .string(let value)?: return value
            case .number(let value)? where name == "text" || name == "value":
                return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
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
            guard case .array(let array) = items else { throw fail("children must be an array") }
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
        case .row?: content = .row(try children())
        case .column?: content = .column(try children())
        case .stack?: content = .stack(try children())
        case .scroll?: content = .scroll(try children(), reveal: try string("reveal"))
        case .button?: content = .button(try children(), hover: try string("hover"))
        case .text?: content = .text(try required("text"))
        case .icon?: content = .icon(try required("symbol"))
        case .image?: content = .image(try required("path"))
        case .slider?: content = .slider(try fraction())
        case .progress?: content = .progress(try fraction())
        case .input?:
            content = .input(Input(value: try string("value") ?? "", placeholder: try string("placeholder"), change: try string("change"), submit: try string("submit")))
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
        return Node(content, key: try string("key"), style: try string("style"), action: try string("action"), props: try props(fields, ""),
                    hovered: try state("hovered"), pressed: try state("pressed"))
    }
}
