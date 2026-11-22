import CoreGraphics
import Foundation

public struct ShapePath: Equatable, Sendable {
    public enum Cap: String, CaseIterable, Sendable {
        case butt, round, square
    }

    public enum Join: String, CaseIterable, Sendable {
        case miter, round, bevel
    }

    public var data: SVGPath
    public var fill: Paint?
    public var stroke: Paint?
    public var lineWidth: Double
    public var cap: Cap
    public var join: Join
    public var dash: [Double]
    public var trim: ClosedRange<Double>

    public init(
        _ data: SVGPath,
        fill: Paint? = nil,
        stroke: Paint? = nil,
        lineWidth: Double = 1,
        cap: Cap = .butt,
        join: Join = .miter,
        dash: [Double] = [],
        trim: ClosedRange<Double> = 0...1,
    ) {
        self.data = data
        self.fill = fill
        self.stroke = stroke
        self.lineWidth = lineWidth
        self.cap = cap
        self.join = join
        self.dash = dash
        self.trim = trim
    }
}

public struct ChartSeries: Equatable, Sendable {
    public enum Mark: String, CaseIterable, Sendable {
        case line, area, bar
    }

    public var values: [Double]
    public var mark: Mark
    public var color: Paint?
    public var smooth: Bool

    public init(_ values: [Double], mark: Mark = .line, color: Paint? = nil, smooth: Bool = false) {
        self.values = values
        self.mark = mark
        self.color = color
        self.smooth = smooth
    }
}

public extension Node {
    struct Shape: Equatable, Sendable {
        public var viewBox: CGSize?
        public var paths: [ShapePath]

        public init(paths: [ShapePath], viewBox: CGSize? = nil) {
            self.paths = paths
            self.viewBox = viewBox
        }
    }

    struct Chart: Equatable, Sendable {
        public var series: [ChartSeries]
        public var min: Double?
        public var max: Double?
        public var axes: Bool

        public init(_ series: [ChartSeries], min: Double? = nil, max: Double? = nil, axes: Bool = false) {
            self.series = series
            self.min = min
            self.max = max
            self.axes = axes
        }

        public var domain: ClosedRange<Double> {
            let values = series.flatMap(\.values)
            let low = min ?? values.min() ?? 0
            let high = max ?? values.max() ?? 1
            guard high <= low else { return low...high }
            return max != nil && min == nil ? (high - 1)...high : low...(low + 1)
        }

        public var count: Int {
            series.map(\.values.count).max() ?? 0
        }
    }

    struct Shader: Equatable, Sendable {
        public static let maxArgs = 1024

        public var path: String
        public var function: String
        public var args: [Double]
        public var animated: Bool

        public init(path: String, function: String, args: [Double] = [], animated: Bool = false) {
            self.path = path
            self.function = function
            self.args = args
            self.animated = animated
        }
    }
}

extension NodeReader {
    func shape() throws -> Node.Shape {
        let viewBox = try fields["viewBox"].flatMap { value -> CGSize? in
            guard value != .null else { return nil }
            let sides = value.array?.compactMap(\.number) ?? []
            guard sides.count == 2, value.array?.count == 2, sides.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                throw fail("viewBox must be [width, height] of positive numbers")
            }
            return CGSize(width: sides[0], height: sides[1])
        }
        return try Node.Shape(paths: list("paths").enumerated().map { index, item in try shapePath(item, "paths[\(index)]") }, viewBox: viewBox)
    }

    private func shapePath(_ json: JSON, _ name: String) throws -> ShapePath {
        guard let fields = json.object else { throw fail("\(name) must be an object") }
        guard let data = fields["d"]?.string else { throw fail("\(name).d must be an SVG path string") }
        let dash = try numbers(fields["dash"], "\(name).dash", "an array of numbers").map { max(0, $0) }
        let trim = try numbers(fields["trim"], "\(name).trim", "[from, to]").map { min(1, max(0, $0)) }
        guard trim.isEmpty || trim.count == 2 else { throw fail("\(name).trim must be [from, to]") }
        return try ShapePath(
            SVGPath(data, path: "\(path).\(name).d"),
            fill: paint(fields["fill"], "\(name).fill"),
            stroke: paint(fields["stroke"], "\(name).stroke"),
            lineWidth: number(fields["lineWidth"], "\(name).lineWidth") ?? 1,
            cap: choice(fields["cap"], "\(name).cap") ?? .butt,
            join: choice(fields["join"], "\(name).join") ?? .miter,
            dash: dash,
            trim: trim.isEmpty ? 0...1 : trim[0]...max(trim[0], trim[1]),
        )
    }

    func chart() throws -> Node.Chart {
        let series = try list("series").enumerated().map { index, item -> ChartSeries in
            let name = "series[\(index)]"
            guard let fields = item.object else { throw fail("\(name) must be an object") }
            guard fields["values"]?.array != nil else { throw fail("\(name).values must be an array of numbers") }
            let values = try numbers(fields["values"], "\(name).values", "an array of numbers")
            return try ChartSeries(
                values,
                mark: choice(fields["mark"], "\(name).mark") ?? .line,
                color: paint(fields["color"], "\(name).color"),
                smooth: flag(fields["smooth"], "\(name).smooth") ?? false,
            )
        }
        let low = try number(fields["min"], "min", signed: true)
        let high = try number(fields["max"], "max", signed: true)
        if let low, let high, high <= low {
            throw fail("max must be greater than min")
        }
        return try Node.Chart(series, min: low, max: high, axes: flag(fields["axes"], "axes") ?? false)
    }

    func columns() throws -> Int {
        guard let columns = fields["columns"]?.number, columns.rounded() == columns else { throw fail("columns must be a whole number") }
        return Int(min(max(columns, 1), Double(Node.maxNodes)))
    }

    func shader() throws -> Node.Shader {
        let function = try required("function")
        let identifier = function.utf8.first.map { !(48...57).contains($0) } == true
            && function.utf8.allSatisfy { $0 == 95 || (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }
        guard identifier else { throw fail("function must name a Metal function") }
        let args = try numbers(fields["args"], "args", "an array of numbers")
        guard args.count <= Node.Shader.maxArgs else { throw fail("args holds at most \(Node.Shader.maxArgs) numbers") }
        return try Node.Shader(path: required("path"), function: function, args: args, animated: flag(fields["animated"], "animated") ?? false)
    }

    private func list(_ name: String) throws -> [JSON] {
        guard let items = fields[name]?.array else { throw fail("\(name) must be an array") }
        return items
    }

    private func numbers(_ value: JSON?, _ name: String, _ syntax: String) throws -> [Double] {
        guard let value, value != .null else { return [] }
        let items = value.array ?? []
        let numbers = items.compactMap(\.number).filter(\.isFinite)
        guard value.array != nil, numbers.count == items.count else { throw fail("\(name) must be \(syntax)") }
        return numbers
    }

    private var report: (String, String) -> Error {
        { field, reason in NodeError(path: path, reason: "\(field) \(reason)") }
    }

    private func number(_ value: JSON?, _ name: String, signed: Bool = false) throws -> Double? {
        try StyleProps.number(value, name, signed: signed, fail: report)
    }

    private func flag(_ value: JSON?, _ name: String) throws -> Bool? {
        try StyleProps.flag(value, name, fail: report)
    }

    private func paint(_ value: JSON?, _ name: String) throws -> Paint? {
        try StyleProps.paint(value, name, fail: report)
    }

    private func choice<Value: RawRepresentable & CaseIterable>(_ value: JSON?, _ name: String) throws -> Value? where Value.RawValue == String {
        try StyleProps.choice(value, name, fail: report)
    }
}
