import Foundation

public struct DisplayChange: Equatable, Sendable {
    public var added: [String] = []
    public var removed: [String] = []
    public var changed: [String] = []

    public init(from old: [DisplayInfo], to new: [DisplayInfo]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Set(new.map(\.id))
        for display in new {
            switch before[display.id] {
            case nil: added.append(display.id)
            case display?: break
            case _?: changed.append(display.id)
            }
        }
        removed = old.map(\.id).filter { !after.contains($0) }
    }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty && changed.isEmpty }
}

public struct PerDisplay<Surface> {
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var surfaces: [String: Surface] = [:]

    public init() {}

    @discardableResult
    public mutating func sync(
        _ next: [DisplayInfo], open: (DisplayInfo) -> Surface, update: (Surface, DisplayInfo) -> Void, close: (Surface) -> Void
    ) -> DisplayChange {
        var seen = Set<String>()
        let next = next.filter { seen.insert($0.id).inserted }
        let change = DisplayChange(from: displays, to: next)
        for id in change.removed {
            if let surface = surfaces.removeValue(forKey: id) { close(surface) }
        }
        for display in next {
            if change.added.contains(display.id) {
                surfaces[display.id] = open(display)
            } else if change.changed.contains(display.id), let surface = surfaces[display.id] {
                update(surface, display)
            }
        }
        displays = next
        return change
    }

    public subscript(id: String) -> Surface? { surfaces[id] }
}
