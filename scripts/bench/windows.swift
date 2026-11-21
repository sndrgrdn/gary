import CoreGraphics
import Foundation

let owner = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
for window in windows {
    let name = window[kCGWindowOwnerName as String] as? String ?? ""
    let pid = window[kCGWindowOwnerPID as String] as? Int ?? 0
    guard owner == nil || name == owner || "\(pid)" == owner else { continue }
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print([
        "id=\(window[kCGWindowNumber as String] as? Int ?? 0)", "pid=\(pid)", "owner=\(name)",
        "layer=\(window[kCGWindowLayer as String] as? Int ?? 0)", "onscreen=\(window[kCGWindowIsOnscreen as String] as? Bool ?? false)",
        "frame=\(Int(bounds["X"] ?? 0)),\(Int(bounds["Y"] ?? 0)),\(Int(bounds["Width"] ?? 0)),\(Int(bounds["Height"] ?? 0))",
    ].joined(separator: " "))
}
