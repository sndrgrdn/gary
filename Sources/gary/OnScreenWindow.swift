import CoreGraphics
import Foundation

struct OnScreenWindow {
    let ownerName: String?
    let ownerPID: pid_t?
    let layer: Int?
    let bounds: CGRect?

    static func list(_ options: CGWindowListOption) -> [OnScreenWindow] {
        let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [NSDictionary] ?? []
        return windows.map { window in
            OnScreenWindow(
                ownerName: window[kCGWindowOwnerName as String] as? String,
                ownerPID: window[kCGWindowOwnerPID as String] as? pid_t,
                layer: window[kCGWindowLayer as String] as? Int,
                bounds: (window[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) },
            )
        }
    }
}
