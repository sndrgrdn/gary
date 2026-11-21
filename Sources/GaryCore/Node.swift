import Foundation

public struct Node: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case row([Node])
        case column([Node])
        case text(String)
        case icon(String)
        case spacer
    }

    public enum Kind: String, Sendable {
        case row, column, text, icon, spacer
    }

    public var content: Content
    public var key: String?
    public var style: String?
    public var action: String?

    public init(_ content: Content, key: String? = nil, style: String? = nil, action: String? = nil) {
        self.content = content
        self.key = key
        self.style = style
        self.action = action
    }

    public var kind: Kind {
        switch content {
        case .row: return .row
        case .column: return .column
        case .text: return .text
        case .icon: return .icon
        case .spacer: return .spacer
        }
    }

    public var children: [Node] {
        switch content {
        case .row(let children), .column(let children): return children
        case .text, .icon, .spacer: return []
        }
    }

    public var value: String? {
        switch content {
        case .text(let value), .icon(let value): return value
        case .row, .column, .spacer: return nil
        }
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
            case .number(let value)? where name == "text":
                return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
            default: throw fail("\(name) must be a string")
            }
        }
        func required(_ name: String) throws -> String {
            guard let value = try string(name) else { throw fail("\(name) is required") }
            return value
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
        case .text?: content = .text(try required("text"))
        case .icon?: content = .icon(try required("symbol"))
        case .spacer?: content = .spacer
        case nil: throw fail("unknown type \"\(type)\"")
        }
        return Node(content, key: try string("key"), style: try string("style"), action: try string("action"))
    }
}
