import GaryCore
import SwiftUI

struct NodeBox: Equatable {
    var width: Double?
    var height: Double?
    var padding: Insets
    var background: ResolvedPaint?
    var action: String?
    var alignment: Alignment
    var clip: Bool

    init(_ look: ResolvedStyle, _ node: Node) {
        width = look.width
        height = look.height
        padding = look.padding ?? Insets(0)
        background = look.background
        action = node.actions[.click]
        alignment = Alignment(horizontal: HorizontalAlignment(look.align ?? .leading), vertical: .center)
        clip = look.clip == true
        switch node.content {
        case .column, .stack: alignment.vertical = .top
        case .scroll: (height, padding, action, alignment.vertical) = (nil, Insets(0), nil, .top)
        case .image:
            (width, height, clip) = (width ?? height ?? 16, height ?? width ?? 16, clip || look.fit == .fill)
            alignment.horizontal = look.align.map(HorizontalAlignment.init) ?? .center
        case .slider: (width, action) = (width ?? 120, nil)
        case .input: (width, action) = (width ?? 240, nil)
        case .progress: (width, height, background) = (width ?? 120, height ?? 6, nil)
        case .icon: alignment.horizontal = look.align.map(HorizontalAlignment.init) ?? .center
        case let .shape(shape): (width, height) = (width ?? shape.viewBox.map(\.width) ?? 24, height ?? shape.viewBox.map(\.height) ?? 24)
        case .chart: (width, height) = (width ?? 60, height ?? 16)
        case .row, .button, .text, .spacer, .grid: break
        }
    }
}
