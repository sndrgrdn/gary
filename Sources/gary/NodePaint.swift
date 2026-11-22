import GaryCore
import SwiftUI

extension AnyShapeStyle {
    init(_ paint: ResolvedPaint) {
        switch paint {
        case let .color(color):
            self.init(Color(color))
        case let .gradient(.linear, colors, angle):
            let radians = angle * .pi / 180
            let across = cos(radians) / 2
            let down = sin(radians) / 2
            self.init(LinearGradient(
                colors: colors.map(Color.init),
                startPoint: UnitPoint(x: 0.5 - across, y: 0.5 - down),
                endPoint: UnitPoint(x: 0.5 + across, y: 0.5 + down),
            ))
        case let .gradient(.radial, colors, _):
            self.init(EllipticalGradient(colors: colors.map(Color.init)))
        case let .gradient(.angular, colors, angle):
            self.init(AngularGradient(colors: colors.map(Color.init), center: .center, angle: .degrees(angle)))
        }
    }
}
