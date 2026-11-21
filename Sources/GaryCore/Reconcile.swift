public indirect enum Patch: Equatable, Sendable {
    case replace(Node)
    case update(attributes: Attributes?, children: [ChildPatch]?)
}

public struct Attributes: Equatable, Sendable {
    public var value: String?
    public var style: String?
    public var action: String?

    init(value: String?, style: String?, action: String?) {
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

public enum ChildPatch: Equatable, Sendable {
    case reuse(from: Int, patch: Patch?)
    case create(Node)
}

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
