import GaryCore
import SwiftUI

final class FrameRecorder {
    struct Entry {
        let frame: CGRect
        let look: ResolvedStyle
    }

    var entries: [String: Entry] = [:]
}

private struct FrameRecorderKey: EnvironmentKey {
    static let defaultValue: FrameRecorder? = nil
}

extension EnvironmentValues {
    var frameRecorder: FrameRecorder? {
        get { self[FrameRecorderKey.self] }
        set { self[FrameRecorderKey.self] = newValue }
    }
}

struct FrameProbe: View {
    let path: String
    let look: ResolvedStyle
    @Environment(\.frameRecorder) private var recorder

    var body: some View {
        GeometryReader { proxy in
            Color.clear.onAppear {
                recorder?.entries[path] = FrameRecorder.Entry(frame: proxy.frame(in: .global), look: look)
            }
        }
    }
}

extension View {
    func probed(_ path: String?, _ look: ResolvedStyle) -> some View {
        background {
            if let path {
                FrameProbe(path: path, look: look)
            }
        }
    }
}

extension String {
    func child(_ id: Node.ChildID) -> String {
        switch id {
        case let .key(key): "\(self)/\(key)"
        case let .position(position): "\(self)/#\(position)"
        }
    }
}

extension Node {
    func outline(_ entries: [String: FrameRecorder.Entry], path: String = "", depth: Int = 0) -> [String] {
        let name = key.map { "\(kind.rawValue) \($0)" } ?? kind.rawValue
        let line = [String(repeating: "  ", count: depth) + name, quoted, entries[path].map(Self.describe)].compactMap(\.self)
        return [line.joined(separator: " ")] + zip(childIDs, children).flatMap { id, child in
            child.outline(entries, path: path.child(id), depth: depth + 1)
        }
    }

    private var quoted: String? {
        switch content {
        case let .text(value), let .icon(value), let .image(value): "\"\(value)\""
        case let .input(input): "\"\(input.value)\""
        default: nil
        }
    }

    private static func describe(_ entry: FrameRecorder.Entry) -> String {
        let frame = entry.frame
        let look = entry.look
        var parts = [String(format: "@%g,%g %gx%g", frame.minX, frame.minY, frame.width, frame.height), "color=\(look.color.hex)"]
        switch look.background {
        case let .color(color)?: parts.append("background=\(color.hex)")
        case let .gradient(kind, colors, _)?: parts.append("background=\(kind)(\(colors.map(\.hex).joined(separator: ",")))")
        case nil: break
        }
        if let opacity = look.opacity, opacity < 1 {
            parts.append(String(format: "opacity=%g", opacity))
        }
        if let border = look.border, let color = look.borderColor {
            parts.append(String(format: "border=%@/%g", color.hex, border.width))
        }
        parts.append(String(format: "font=%g/%@", look.font.size, look.font.weight.rawValue))
        return parts.joined(separator: " ")
    }
}
