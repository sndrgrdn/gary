import CoreGraphics
import Foundation

public struct DisplayInfo: Equatable, Sendable {
    public var id: String
    public var index: Int
    public var frame: CGRect
    public var band: Double
    public var notch: ClosedRange<Double>?

    public init(id: String, index: Int, frame: CGRect, band: Double, notch: ClosedRange<Double>? = nil) {
        self.id = id
        self.index = index
        self.frame = frame
        self.band = band
        self.notch = notch
    }

    public var json: JSON {
        .object([
            "id": .string(id),
            "index": .number(Double(index)),
            "main": .bool(index == 0),
            "width": .number(frame.width),
            "height": .number(frame.height),
            "notched": .bool(notch != nil),
            "notch": notch.map { .object(["left": .number($0.lowerBound), "right": .number($0.upperBound)]) } ?? .null,
        ])
    }
}

public enum SurfaceLayer: String, CaseIterable, Sendable {
    case desktop, below, normal, top, overlay, notch
}

public enum ScreenSelector: Equatable, Sendable {
    case main, focused, all
    case index(Int)

    public func select(_ displays: [DisplayInfo], focused: String?) -> [DisplayInfo] {
        switch self {
        case .all: displays
        case .main: Array(displays.prefix(1))
        case .focused: [displays.first { $0.id == focused } ?? displays.first].compactMap(\.self)
        case let .index(index): [displays.first { $0.index == index } ?? displays.first].compactMap(\.self)
        }
    }
}

public enum Dimension: Equatable, Sendable {
    case fit
    case points(Double)
}

public enum ExclusionMode: String, Sendable {
    case normal, ignore
}

public enum SurfaceBackground: String, CaseIterable, Sendable {
    case solid
    case transparent = "none"
    case backdrop
}

public struct Edges<Value: Equatable & Sendable>: Equatable, Sendable {
    public var top: Value
    public var bottom: Value
    public var left: Value
    public var right: Value

    public init(top: Value, bottom: Value, left: Value, right: Value) {
        self.top = top
        self.bottom = bottom
        self.left = left
        self.right = right
    }
}

public struct SurfaceError: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let reason: String
    public var description: String {
        "\(path): \(reason)"
    }
}

public struct SurfaceAddress: Hashable, Sendable, CustomStringConvertible {
    public static let main = "main"
    public let plugin: PluginID
    public let surface: String

    public init(_ plugin: PluginID) {
        self.plugin = plugin
        surface = Self.main
    }

    public init?(_ plugin: PluginID, surface: String) {
        guard Self.isName(surface) else { return nil }
        self.plugin = plugin
        self.surface = surface
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let plugin = PluginID(parts[0]) else { return nil }
        self.init(plugin, surface: parts.count == 2 ? parts[1] : Self.main)
    }

    public var description: String {
        surface == Self.main ? plugin.rawValue : "\(plugin.rawValue):\(surface)"
    }

    public static func isName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }
}

public struct SurfaceSpec: Equatable, Sendable {
    public var screen: ScreenSelector
    public var anchors: Edges<Bool>
    public var width: Dimension
    public var height: Dimension
    public var margins: Edges<Double>
    public var layer: SurfaceLayer
    public var exclusionMode: ExclusionMode
    public var clickThrough: Bool
    public var focusable: Bool
    public var background: SurfaceBackground
    public var attach = false

    public static let all = Edges(top: true, bottom: true, left: true, right: true)

    public static func defaults(for kind: PluginKind) -> SurfaceSpec {
        var spec = SurfaceSpec(
            screen: .focused, anchors: Edges(top: false, bottom: false, left: false, right: false), width: .fit, height: .fit,
            margins: Edges(top: 0, bottom: 0, left: 0, right: 0),
            layer: .top, exclusionMode: .normal, clickThrough: false, focusable: false, background: .solid,
        )
        switch kind {
        case .overlay:
            spec.anchors = all
            spec.layer = .overlay
            spec.exclusionMode = .ignore
        case .menu:
            spec.layer = .overlay
            spec.focusable = true
        case .bar, .barWidget, .service:
            spec.background = .transparent
        case .panel:
            break
        }
        return spec
    }

    public static func parse(_ json: JSON, kind: PluginKind, at root: String = "surface") throws -> SurfaceSpec {
        var spec = defaults(for: kind)
        if json == .null {
            return spec
        }
        guard let fields = json.object else { throw fail(root, "must be an object") }
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            let path = "\(root).\(name)"
            guard let read = fieldReaders[name] else { throw fail(path, "is not a surface field") }
            try read(&spec, value, path)
        }
        return spec
    }

    private static let fieldReaders: [String: @Sendable (inout SurfaceSpec, JSON, String) throws -> Void] = [
        "screen": { spec, value, path in spec.screen = try screen(value, path) },
        "anchors": { spec, value, path in spec.anchors = try edges(value, path, absent: false, bool) },
        "width": { spec, value, path in spec.width = try dimension(value, path) },
        "height": { spec, value, path in spec.height = try dimension(value, path) },
        "margins": { spec, value, path in spec.margins = try margins(value, path) },
        "layer": { spec, value, path in
            spec.layer = try choice(value, path, "must be one of \(SurfaceLayer.allCases.map(\.rawValue).joined(separator: ", "))")
        },
        "exclusionMode": { spec, value, path in spec.exclusionMode = try choice(value, path, "must be \"normal\" or \"ignore\"") },
        "clickThrough": { spec, value, path in spec.clickThrough = try bool(value, path) },
        "focusable": { spec, value, path in spec.focusable = try bool(value, path) },
        "attach": { spec, value, path in spec.attach = try bool(value, path) },
        "background": { spec, value, path in
            spec.background = try choice(
                value,
                path,
                "must be one of \(SurfaceBackground.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))",
            )
        },
    ]

    public static func parseAll(_ exports: JSON, kind: PluginKind) throws -> [String: SurfaceSpec] {
        let surface = exports["surface"]
        guard let surfaces = exports["surfaces"] else { return try [SurfaceAddress.main: parse(surface ?? .null, kind: kind)] }
        if surface != nil {
            throw fail("surfaces", "cannot be exported with surface; put that surface in surfaces as main")
        }
        guard let named = surfaces.object, !named.isEmpty else { throw fail("surfaces", "must be an object of one or more named surfaces") }
        var specs: [String: SurfaceSpec] = [:]
        for (name, value) in named.sorted(by: { $0.key < $1.key }) {
            let path = "surfaces.\(name)"
            guard SurfaceAddress.isName(name) else { throw fail(path, "is not a surface name; use lowercase letters, digits and hyphens") }
            specs[name] = try parse(value, kind: kind, at: path)
        }
        return specs
    }

    private static func fail(_ path: String, _ reason: String) -> SurfaceError {
        SurfaceError(path: path, reason: reason)
    }

    private static func screen(_ value: JSON, _ path: String) throws -> ScreenSelector {
        switch value {
        case .string("main"): .main
        case .string("focused"): .focused
        case .string("all"): .all
        case let .number(index) where index >= 0 && index == index.rounded() && index < 64: .index(Int(index))
        default: throw fail(path, "must be \"main\", \"focused\", \"all\" or a display index")
        }
    }

    private static func bool(_ value: JSON, _ path: String) throws -> Bool {
        guard let flag = value.bool else { throw fail(path, "must be true or false") }
        return flag
    }

    private static func points(_ value: JSON, _ path: String) throws -> Double {
        guard let number = value.number, number >= 0, number.isFinite else { throw fail(path, "must be a non-negative number") }
        return number
    }

    private static func dimension(_ value: JSON, _ path: String) throws -> Dimension {
        if value.string == "fit" {
            return .fit
        }
        guard let number = value.number, number > 0, number.isFinite else { throw fail(path, "must be a positive number or \"fit\"") }
        return .points(number)
    }

    private static func margins(_ value: JSON, _ path: String) throws -> Edges<Double> {
        guard value.number != nil else { return try edges(value, path, absent: 0, points) }
        let all = try points(value, path)
        return Edges(top: all, bottom: all, left: all, right: all)
    }

    private static func edges<Value>(_ value: JSON, _ path: String, absent: Value, _ read: (JSON, String) throws -> Value) throws -> Edges<Value> {
        guard let sides = value.object else { throw fail(path, "must be an object with top, bottom, left and right") }
        if let unknown = sides.keys.sorted().first(where: { !["top", "bottom", "left", "right"].contains($0) }) {
            throw fail("\(path).\(unknown)", "is not top, bottom, left or right")
        }
        func side(_ name: String) throws -> Value {
            try sides[name].map { try read($0, "\(path).\(name)") } ?? absent
        }
        return try Edges(top: side("top"), bottom: side("bottom"), left: side("left"), right: side("right"))
    }

    private static func choice<Value: RawRepresentable>(_ value: JSON, _ path: String, _ reason: String) throws -> Value
        where Value.RawValue == String
    {
        guard let choice = value.string.flatMap(Value.init(rawValue:)) else { throw fail(path, reason) }
        return choice
    }

    public func area(on display: DisplayInfo) -> CGRect {
        var area = display.frame
        if exclusionMode == .normal {
            area.size.height -= display.band
        }
        return area
    }

    public func frame(on display: DisplayInfo, fitting: (_ width: Double?, _ height: Double?, _ limit: CGSize) -> CGSize) -> CGRect {
        let area = area(on: display)
        let horizontal = Axis(
            start: area.minX, end: area.maxX, span: area.width,
            lowAnchored: anchors.left, highAnchored: anchors.right, lowMargin: margins.left, highMargin: margins.right,
        )
        let vertical = Axis(
            start: area.minY, end: area.maxY, span: area.height,
            lowAnchored: anchors.bottom, highAnchored: anchors.top, lowMargin: margins.bottom, highMargin: margins.top,
        )
        let limit = CGSize(width: horizontal.limit, height: vertical.limit)
        let width = horizontal.forced(width)
        let height = vertical.forced(height)
        let fitted = width == nil || height == nil ? fitting(width.map { min($0, limit.width) }, height.map { min($0, limit.height) }, limit) : .zero
        let size = CGSize(width: min(width ?? fitted.width, limit.width), height: min(height ?? fitted.height, limit.height))
        return CGRect(x: horizontal.origin(size.width), y: vertical.origin(size.height), width: size.width, height: size.height)
    }

    public func frame(
        on display: DisplayInfo,
        attachedTo origin: CGRect?,
        edge: Double,
        fitting: (_ width: Double?, _ height: Double?, _ limit: CGSize) -> CGSize,
    ) -> CGRect {
        guard attach, let origin, display.frame.contains(CGPoint(x: origin.midX, y: origin.midY)) else { return frame(on: display, fitting: fitting) }
        let bounds = display.frame.insetBy(dx: edge, dy: edge)
        let limit = CGSize(
            width: max(0, bounds.width),
            height: max(0, origin.minY - margins.top - bounds.minY, bounds.maxY - origin.maxY - margins.top),
        )
        func fixed(_ dimension: Dimension, _ limit: Double) -> Double? {
            if case let .points(value) = dimension {
                min(value, limit)
            } else {
                nil
            }
        }
        let width = fixed(width, limit.width)
        let height = fixed(height, limit.height)
        let fitted = width == nil || height == nil ? fitting(width, height, limit) : .zero
        let size = CGSize(width: min(width ?? fitted.width, limit.width), height: min(height ?? fitted.height, limit.height))
        return Self.attached(size, to: origin, gap: margins.top, within: bounds)
    }

    public static func attached(_ size: CGSize, to origin: CGRect, gap: Double, within bounds: CGRect) -> CGRect {
        let below = origin.minY - gap - size.height
        let y = below >= bounds.minY ? below : origin.maxY + gap
        return CGRect(
            x: max(bounds.minX, min((origin.midX - size.width / 2).rounded(), bounds.maxX - size.width)),
            y: max(bounds.minY, min(y.rounded(), bounds.maxY - size.height)),
            width: size.width,
            height: size.height,
        )
    }
}

private struct Axis {
    let start: Double
    let end: Double
    let span: Double
    let lowAnchored: Bool
    let highAnchored: Bool
    let lowMargin: Double
    let highMargin: Double

    var limit: Double {
        max(0, span - (lowAnchored ? lowMargin : 0) - (highAnchored ? highMargin : 0))
    }

    func forced(_ dimension: Dimension) -> Double? {
        if lowAnchored, highAnchored {
            return max(0, span - lowMargin - highMargin)
        }
        if case let .points(value) = dimension {
            return value
        }
        return nil
    }

    func origin(_ length: Double) -> Double {
        let origin: Double = if lowAnchored {
            start + lowMargin
        } else if highAnchored {
            end - highMargin - length
        } else {
            ((start + end - length) / 2).rounded()
        }
        return min(max(origin, start), end - length)
    }
}
