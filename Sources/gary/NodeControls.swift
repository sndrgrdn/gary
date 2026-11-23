import AppKit
import GaryCore
import SwiftUI

struct Vibrancy: NSViewRepresentable {
    let radius: Double

    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.appearance = NSAppearance(named: context.environment.colorScheme == .dark ? .darkAqua : .aqua)
        view.maskImage = radius > 0 ? Self.roundedMask(radius) : nil
    }

    private static func roundedMask(_ radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension Date {
    var milliseconds: Double {
        timeIntervalSince1970 * 1000
    }
}

struct Advancing<Content: View>: View {
    let fraction: Node.Fraction
    let width: Double
    @ViewBuilder let content: (Double) -> Content
    private let since = State<Double?>(initialValue: nil)

    var body: some View {
        let now = Date()
        var anchored = fraction
        anchored.at = fraction.at ?? since.wrappedValue ?? now.milliseconds
        return TimelineView(.explicit(Self.ticks(anchored, from: now, width: width))) { context in
            content(anchored.value(at: context.date.milliseconds))
        }
        .onChange(of: fraction, initial: true) { since.wrappedValue = now.milliseconds }
    }

    private static func ticks(_ fraction: Node.Fraction, from now: Date, width: Double) -> [Date] {
        guard let end = fraction.end, end > now.milliseconds else { return [] }
        let interval = max(1.0 / 60, 1 / (abs(fraction.rate) * max(width, 1) * 2))
        return stride(from: 0, through: (end - now.milliseconds) / 1000 + interval, by: interval).map { now.addingTimeInterval($0) }
    }
}

struct ProgressBar: View {
    let value: Double
    let look: ResolvedStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: look.radius ?? 3)
        shape.fill(AnyShapeStyle(look.background ?? .color(RGBA(red: look.color.red, green: look.color.green, blue: look.color.blue, alpha: 0.25))))
            .overlay(alignment: .leading) { GeometryReader { area in shape.fill(Color(look.color)).frame(width: area.size.width * value) } }
    }
}

struct SliderNode: View {
    let fraction: Node.Fraction
    let width: Double
    let action: String?
    let release: String?
    let tint: Color?
    @Environment(\.nodeAction) private var perform
    private let drag = State(initialValue: SliderDrag())

    var body: some View {
        Advancing(fraction: drag.wrappedValue.held ?? fraction, width: width) { value in
            Slider(value: Binding(get: { value }, set: { next in
                drag.wrappedValue.move(to: next, at: Date().milliseconds)
                send(action, next)
            }), in: 0...1) { editing in
                if let released = drag.wrappedValue.edit(editing, shown: value, rate: fraction.rate, at: Date().milliseconds) {
                    send(release, released)
                }
            }
        }
        .tint(tint)
        .focusEffectDisabled()
        .onChange(of: fraction) {
            drag.wrappedValue.fractionChanged()
        }
    }

    private func send(_ name: String?, _ value: Double) {
        if let name {
            perform?(ActionEvent(name: name, payload: .number(value), origin: nil))
        }
    }
}

struct SliderDrag {
    private(set) var held: Node.Fraction?
    private var dragging = false

    mutating func move(to value: Double, at time: Double) {
        held = Node.Fraction(value, at: time)
    }

    mutating func edit(_ editing: Bool, shown value: Double, rate: Double, at time: Double) -> Double? {
        let current = dragging ? held?.value ?? value : value
        dragging = editing
        held = Node.Fraction(current, rate: editing ? 0 : rate, at: time)
        return editing ? nil : current
    }

    mutating func fractionChanged() {
        if !dragging {
            held = nil
        }
    }
}

struct InputNode: View {
    let input: Node.Input
    let font: NSFont
    let color: Color
    @Environment(\.nodeAction) private var perform
    private let text = State(initialValue: "")
    private let sent = State(initialValue: [String]())

    private static let keys: [KeyEquivalent: String] = [.upArrow: "up", .downArrow: "down", .tab: "tab", .escape: "escape"]

    var body: some View {
        TextField("", text: Binding(get: { text.wrappedValue }, set: { typed($0) }), prompt: input.placeholder.map { Text($0) })
            .textFieldStyle(.plain)
            .focusEffectDisabled()
            .font(Font(font as CTFont))
            .foregroundStyle(color)
            .onSubmit {
                if let submit = input.submit {
                    perform?(ActionEvent(name: submit, payload: .string(text.wrappedValue), origin: nil))
                } else {
                    pressKey("enter")
                }
            }
            .onKeyPress(keys: Set(Self.keys.keys)) { press in
                guard let key = Self.keys[press.key] else { return .ignored }
                pressKey(key)
                return .handled
            }
            .onChange(of: input.value, initial: true) { _, value in
                if let index = sent.wrappedValue.firstIndex(of: value) {
                    sent.wrappedValue.removeFirst(index + 1)
                    return
                }
                sent.wrappedValue = []
                if text.wrappedValue != value {
                    text.wrappedValue = value
                }
            }
    }

    private func typed(_ next: String) {
        guard next != text.wrappedValue else { return }
        text.wrappedValue = next
        guard let change = input.change else { return }
        sent.wrappedValue.append(next)
        perform?(ActionEvent(name: change, payload: .string(next), origin: nil))
    }

    private func pressKey(_ key: String) {
        (NSApp.keyWindow as? SurfacePanel)?.onKey?(key)
    }
}
