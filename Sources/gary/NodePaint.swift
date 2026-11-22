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

extension BlendMode {
    init(_ blend: Blend) {
        switch blend {
        case .normal: self = .normal
        case .multiply: self = .multiply
        case .screen: self = .screen
        case .overlay: self = .overlay
        case .plusLighter: self = .plusLighter
        case .plusDarker: self = .plusDarker
        case .difference: self = .difference
        }
    }
}

struct VisualEffects: ViewModifier {
    let scale: Double
    let rotation: Double
    let blur: Double
    let opacity: Double
    let blend: Blend
    let offset: CGSize
    let loop: Loop?
    let loops: Bool

    init(_ look: ResolvedStyle, _ node: Node) {
        scale = look.scale ?? 1
        rotation = look.rotation ?? 0
        blur = look.blur ?? 0
        opacity = look.opacity ?? 1
        blend = look.blend ?? .normal
        offset = CGSize(width: look.x ?? 0, height: look.y ?? 0)
        loop = look.loop
        loops = look.loop != nil || [node.props, node.hovered, node.pressed].contains { $0?.loop != nil }
    }

    func body(content: Content) -> some View {
        content
            .modifier(TransformEffect(scale: scale, rotation: rotation, offset: loops ? .zero : offset))
            .blur(radius: blur)
            .opacity(opacity)
            .blendMode(BlendMode(blend))
            .modifier(LoopEffect(loop: loop, present: loops, offset: offset))
    }
}

struct LoopEffect: ViewModifier {
    let loop: Loop?
    let present: Bool
    let offset: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let start = State(initialValue: Date())

    func body(content: Content) -> some View {
        let loop = reduceMotion ? nil : loop
        if present {
            TimelineView(.animation(paused: loop == nil)) { context in
                let phase = loop?.phase(after: context.date.timeIntervalSince(start.wrappedValue)) ?? 0
                content
                    .modifier(TransformEffect(
                        scale: loop?.spans[.scale]?.at(phase) ?? 1,
                        rotation: loop?.spans[.rotation]?.at(phase) ?? 0,
                        offset: CGSize(
                            width: offset.width + (loop?.spans[.x]?.at(phase) ?? 0),
                            height: offset.height + (loop?.spans[.y]?.at(phase) ?? 0),
                        ),
                    ))
                    .opacity(loop?.spans[.opacity]?.at(phase) ?? 1)
            }
            .onChange(of: loop) { start.wrappedValue = Date() }
        } else {
            content
        }
    }
}

struct TransformEffect: GeometryEffect {
    var scale: Double
    var rotation: Double
    var offset: CGSize

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, CGSize.AnimatableData> {
        get { AnimatablePair(AnimatablePair(scale, rotation), offset.animatableData) }
        set { (scale, rotation, offset.animatableData) = (newValue.first.first, newValue.first.second, newValue.second) }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: offset.width + size.width / 2, y: offset.height + size.height / 2)
            .rotated(by: rotation * .pi / 180)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -size.width / 2, y: -size.height / 2))
    }
}
