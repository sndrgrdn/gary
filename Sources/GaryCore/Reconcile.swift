public indirect enum Patch: Equatable, Sendable {
    case replace(Node)
    case update(own: Node?, children: [ChildPatch]?)
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
    let own = old.own == new.own ? nil : new.own
    let children = reconcileChildren(old.children, new.children)
    if own == nil && children == nil { return nil }
    return .update(own: own, children: children)
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
