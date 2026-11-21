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

struct SliderNode: View {
    let value: Double
    let action: String?
    let tint: Color?
    @Environment(\.nodeAction) private var perform
    private let shown = State(initialValue: 0.0)

    var body: some View {
        Slider(value: Binding(get: { shown.wrappedValue }, set: { next in
            shown.wrappedValue = next
            if let action {
                perform?(ActionEvent(name: action, payload: .number(next), origin: nil))
            }
        }), in: 0...1)
            .tint(tint)
            .onChange(of: value, initial: true) { _, next in shown.wrappedValue = next }
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
