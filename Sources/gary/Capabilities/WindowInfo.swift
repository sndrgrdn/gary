import CoreGraphics
import Foundation

nonisolated struct WindowInfo: Equatable {
    let id: CGWindowID
    let owner: pid_t
    let ownerName: String?
    let layer: Int
    let bounds: CGRect?

    static func list(_ options: CGWindowListOption) -> [Self] {
        (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [NSDictionary] ?? []).compactMap(Self.init)
    }
}

nonisolated extension WindowInfo {
    init?(_ info: NSDictionary) {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let owner = info[kCGWindowOwnerPID as String] as? pid_t,
              let layer = info[kCGWindowLayer as String] as? Int else { return nil }
        let bounds = (info[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
        self.init(id: id, owner: owner, ownerName: info[kCGWindowOwnerName as String] as? String, layer: layer, bounds: bounds)
    }
}
