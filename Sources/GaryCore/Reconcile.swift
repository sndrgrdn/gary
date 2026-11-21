/// How to turn the views mounted for one tree into views for the next.
public indirect enum Patch: Equatable, Sendable {
    /// Build a new view for the node and drop the old one: its kind or key changed.
    case replace(Node)
    /// Keep the view. Set `attributes` when non-nil, and make the children match `children` when non-nil.
    case update(attributes: Attributes?, children: [ChildPatch]?)
}

/// A node's own attributes. `value` is the text of a text node or the symbol of an icon.
public struct Attributes: Equatable, Sendable {
    public var value: String?
    public var style: String?
    public var action: String?

    public init(value: String?, style: String?, action: String?) {
        self.value = value
        self.style = style
        self.action = action
    }

    init(_ node: Node) {
        value = node.value
        style = node.style
        action = node.action
    }
}

/// One child of the new tree, in order.
public enum ChildPatch: Equatable, Sendable {
    /// Reuse the old child view at `from`, applying `patch` when non-nil.
    case reuse(from: Int, patch: Patch?)
    /// Build a view: no old child has this child's key, or position among unkeyed siblings, and kind.
    case create(Node)
}

/// Nil when `new` equals `old`. Children match by key, or by position among their unkeyed siblings, and must
/// have the same kind; old children that match nothing are removed.
public func reconcile(_ old: Node, _ new: Node) -> Patch? {
    guard old.kind == new.kind, old.key == new.key else { return .replace(new) }
    return update(old, new)
}

private func update(_ old: Node, _ new: Node) -> Patch? {
    let attributes = Attributes(old) == Attributes(new) ? nil : Attributes(new)
    let children = reconcileChildren(old.children, new.children)
    if attributes == nil && children == nil { return nil }
    return .update(attributes: attributes, children: children)
}

private enum Identity: Hashable {
    case key(String)
    case position(Int)
}

private func identities(_ nodes: [Node]) -> [Identity] {
    var position = 0
    return nodes.map { node in
        if let key = node.key { return .key(key) }
        defer { position += 1 }
        return .position(position)
    }
}

private func reconcileChildren(_ old: [Node], _ new: [Node]) -> [ChildPatch]? {
    var oldIndex: [Identity: Int] = [:]
    for (index, identity) in identities(old).enumerated() { oldIndex[identity] = index }
    let patches = zip(new, identities(new)).map { child, identity -> ChildPatch in
        guard let index = oldIndex[identity], old[index].kind == child.kind else { return .create(child) }
        return .reuse(from: index, patch: update(old[index], child))
    }
    let unchanged = old.count == new.count
        && patches.enumerated().allSatisfy { index, patch in patch == .reuse(from: index, patch: nil) }
    return unchanged ? nil : patches
}
