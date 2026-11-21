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
        case .all: return displays
        case .main: return Array(displays.prefix(1))
        case .focused: return [displays.first { $0.id == focused } ?? displays.first].compactMap { $0 }
        case .index(let index): return [displays.first { $0.index == index } ?? displays.first].compactMap { $0 }
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
    case solid, vibrant, none
}

public struct Edges<Value: Equatable & Sendable>: Equatable, Sendable {
    public var top, bottom, left, right: Value

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
    public var description: String { "\(path): \(reason)" }
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

    public static let none = Edges(top: false, bottom: false, left: false, right: false)
    public static let all = Edges(top: true, bottom: true, left: true, right: true)

    public static func defaults(for kind: PluginKind) -> SurfaceSpec {
        var spec = SurfaceSpec(
            screen: .focused, anchors: none, width: .fit, height: .fit,
            margins: Edges(top: 0, bottom: 0, left: 0, right: 0),
            layer: .top, exclusionMode: .normal, clickThrough: false, focusable: false, background: .solid
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
            spec.background = .none
        case .panel:
            break
        }
        return spec
    }

    public static func parse(_ json: JSON, kind: PluginKind) throws -> SurfaceSpec {
        var spec = defaults(for: kind)
        if json == .null { return spec }
        func fail(_ path: String, _ reason: String) -> SurfaceError { SurfaceError(path: "surface\(path)", reason: reason) }
        guard let fields = json.object else { throw fail("", "must be an object") }
        func bool(_ value: JSON, _ path: String) throws -> Bool {
            guard let flag = value.bool else { throw fail(path, "must be true or false") }
            return flag
        }
        func points(_ value: JSON, _ path: String) throws -> Double {
            guard let number = value.number, number >= 0, number.isFinite else { throw fail(path, "must be a non-negative number") }
            return number
        }
        func dimension(_ value: JSON, _ path: String) throws -> Dimension {
            if value.string == "fit" { return .fit }
            guard let number = value.number, number > 0, number.isFinite else { throw fail(path, "must be a positive number or \"fit\"") }
            return .points(number)
        }
        func edges<Value>(_ value: JSON, _ path: String, absent: Value, _ read: (JSON, String) throws -> Value) throws -> Edges<Value> {
            guard let sides = value.object else { throw fail(path, "must be an object with top, bottom, left and right") }
            if let unknown = sides.keys.sorted().first(where: { !["top", "bottom", "left", "right"].contains($0) }) {
                throw fail("\(path).\(unknown)", "is not top, bottom, left or right")
            }
            func side(_ name: String) throws -> Value { try sides[name].map { try read($0, "\(path).\(name)") } ?? absent }
            return Edges(top: try side("top"), bottom: try side("bottom"), left: try side("left"), right: try side("right"))
        }

        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            let path = ".\(name)"
            switch name {
            case "screen":
                switch value {
                case .string("main"): spec.screen = .main
                case .string("focused"): spec.screen = .focused
                case .string("all"): spec.screen = .all
                case .number(let index) where index >= 0 && index == index.rounded() && index < 64: spec.screen = .index(Int(index))
                default: throw fail(path, "must be \"main\", \"focused\", \"all\" or a display index")
                }
            case "anchors": spec.anchors = try edges(value, path, absent: false, bool)
            case "width": spec.width = try dimension(value, path)
            case "height": spec.height = try dimension(value, path)
            case "margins":
                if value.number != nil {
                    let all = try points(value, path)
                    spec.margins = Edges(top: all, bottom: all, left: all, right: all)
                } else {
                    spec.margins = try edges(value, path, absent: 0, points)
                }
            case "layer":
                guard let layer = value.string.flatMap(SurfaceLayer.init(rawValue:)) else {
                    throw fail(path, "must be one of \(SurfaceLayer.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                spec.layer = layer
            case "exclusionMode":
                guard let mode = value.string.flatMap(ExclusionMode.init(rawValue:)) else { throw fail(path, "must be \"normal\" or \"ignore\"") }
                spec.exclusionMode = mode
            case "clickThrough": spec.clickThrough = try bool(value, path)
            case "focusable": spec.focusable = try bool(value, path)
            case "background":
                guard let background = value.string.flatMap(SurfaceBackground.init(rawValue:)) else {
                    throw fail(path, "must be one of \(SurfaceBackground.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))")
                }
                spec.background = background
            default: throw fail(path, "is not a surface field")
            }
        }
        return spec
    }

    public func area(on display: DisplayInfo) -> CGRect {
        var area = display.frame
        if exclusionMode == .normal { area.size.height -= display.band }
        return area
    }

    public func frame(on display: DisplayInfo, fitting: (_ width: Double?, _ height: Double?, _ limit: CGSize) -> CGSize) -> CGRect {
        let area = area(on: display)
        func forced(_ dimension: Dimension, _ low: Bool, _ high: Bool, _ span: Double, _ lowMargin: Double, _ highMargin: Double) -> Double? {
            if low && high { return max(0, span - lowMargin - highMargin) }
            if case .points(let value) = dimension { return value }
            return nil
        }
        let limit = CGSize(
            width: max(0, area.width - (anchors.left ? margins.left : 0) - (anchors.right ? margins.right : 0)),
            height: max(0, area.height - (anchors.bottom ? margins.bottom : 0) - (anchors.top ? margins.top : 0))
        )
        let width = forced(self.width, anchors.left, anchors.right, area.width, margins.left, margins.right)
        let height = forced(self.height, anchors.bottom, anchors.top, area.height, margins.bottom, margins.top)
        let fitted = width == nil || height == nil ? fitting(width.map { min($0, limit.width) }, height.map { min($0, limit.height) }, limit) : .zero
        let size = CGSize(width: min(width ?? fitted.width, limit.width), height: min(height ?? fitted.height, limit.height))
        func origin(_ low: Bool, _ high: Bool, _ min: Double, _ max: Double, _ length: Double, _ lowMargin: Double, _ highMargin: Double) -> Double {
            let start: Double
            if low { start = min + lowMargin } else if high { start = max - highMargin - length } else { start = ((min + max - length) / 2).rounded() }
            return Swift.min(Swift.max(start, min), max - length)
        }
        return CGRect(
            x: origin(anchors.left, anchors.right, area.minX, area.maxX, size.width, margins.left, margins.right),
            y: origin(anchors.bottom, anchors.top, area.minY, area.maxY, size.height, margins.bottom, margins.top),
            width: size.width, height: size.height
        )
    }
}
