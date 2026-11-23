import Charts
import GaryCore
import SwiftUI

extension CGPath {
    static func svg(_ svg: SVGPath, scale: CGSize) -> CGPath {
        let path = CGMutablePath()
        func scaled(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale.width, y: point.y * scale.height)
        }
        for element in svg.elements {
            switch element {
            case let .move(point): path.move(to: scaled(point))
            case let .line(point): path.addLine(to: scaled(point))
            case let .quad(control, point): path.addQuadCurve(to: scaled(point), control: scaled(control))
            case let .cubic(first, second, point): path.addCurve(to: scaled(point), control1: scaled(first), control2: scaled(second))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}

private struct SVGFigure: Shape {
    let svg: SVGPath
    let viewBox: CGSize?

    func path(in rect: CGRect) -> Path {
        let box = viewBox ?? rect.size
        let scale = CGSize(width: box.width > 0 ? rect.width / box.width : 1, height: box.height > 0 ? rect.height / box.height : 1)
        return Path(CGPath.svg(svg, scale: scale)).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

struct ShapeNode: View {
    let shape: Node.Shape
    let theme: Theme
    let color: RGBA

    var body: some View {
        GeometryReader { area in
            let box = shape.viewBox ?? area.size
            let factor = min(box.width > 0 ? area.size.width / box.width : 1, box.height > 0 ? area.size.height / box.height : 1)
            ZStack {
                ForEach(shape.paths.indices, id: \.self) { index in
                    layer(shape.paths[index], factor)
                }
            }
        }
    }

    @ViewBuilder private func layer(_ path: ShapePath, _ factor: Double) -> some View {
        let figure = SVGFigure(svg: path.data, viewBox: shape.viewBox).trim(from: path.trim.lowerBound, to: path.trim.upperBound)
        let fill = path.fill == nil && path.stroke == nil ? .color(color) : theme.paint(path.fill)
        ZStack {
            if let fill {
                figure.fill(AnyShapeStyle(fill))
            }
            if let stroke = theme.paint(path.stroke) {
                figure.stroke(AnyShapeStyle(stroke), style: StrokeStyle(
                    lineWidth: path.lineWidth * factor,
                    lineCap: CGLineCap(path.cap),
                    lineJoin: CGLineJoin(path.join),
                    dash: path.dash.map { $0 * factor },
                ))
            }
        }
    }
}

private extension CGLineCap {
    init(_ cap: ShapePath.Cap) {
        switch cap {
        case .butt: self = .butt
        case .round: self = .round
        case .square: self = .square
        }
    }
}

private extension CGLineJoin {
    init(_ join: ShapePath.Join) {
        switch join {
        case .miter: self = .miter
        case .round: self = .round
        case .bevel: self = .bevel
        }
    }
}

struct ChartNode: View {
    let chart: Node.Chart
    let theme: Theme
    let color: RGBA
    let font: NSFont

    var body: some View {
        let domain = chart.domain
        let hasBars = chart.series.contains { $0.mark == .bar }
        let last = Double(max(chart.count - 1, 1))
        Chart {
            ForEach(chart.series.indices, id: \.self) { index in
                let series = chart.series[index]
                let style = AnyShapeStyle(theme.paint(series.color) ?? .color(color))
                ForEach(series.values.indices, id: \.self) { position in
                    mark(series, index, position, domain, style)
                }
            }
        }
        .chartXScale(domain: hasBars ? -0.5...(last + 0.5) : 0...last)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
        .chartXAxis(chart.axes || !chart.labels.isEmpty ? .automatic : .hidden)
        .chartXAxis {
            if chart.labels.isEmpty {
                AxisMarks()
            } else {
                AxisMarks(preset: .aligned, values: chart.labels.indices.filter { !chart.labels[$0].isEmpty }.map(Double.init)) { value in
                    if chart.axes {
                        AxisGridLine()
                        AxisTick()
                    }
                    AxisValueLabel {
                        Text(verbatim: value.as(Double.self).map { chart.labels[Int($0)] } ?? "")
                            .font(Font(font as CTFont)).foregroundStyle(Color(color))
                    }
                }
            }
        }
        .chartYAxis(chart.axes ? .automatic : .hidden)
    }

    @ChartContentBuilder private func mark(
        _ series: ChartSeries,
        _ index: Int,
        _ position: Int,
        _ domain: ClosedRange<Double>,
        _ style: AnyShapeStyle,
    ) -> some ChartContent {
        let x = PlottableValue.value("x", Double(position))
        let floor = PlottableValue.value("y", domain.lowerBound)
        let value = PlottableValue.value("y", Swift.min(Swift.max(series.values[position], domain.lowerBound), domain.upperBound))
        let curve: InterpolationMethod = series.smooth ? .monotone : .linear
        if series.mark == .line {
            LineMark(x: x, y: value, series: .value("series", index)).foregroundStyle(style).interpolationMethod(curve)
        } else if series.mark == .area {
            AreaMark(x: x, yStart: floor, yEnd: value, series: .value("series", index)).foregroundStyle(style).interpolationMethod(curve)
        } else {
            RectangleMark(xStart: .value("x", Double(position) - 0.4), xEnd: .value("x", Double(position) + 0.4), yStart: floor, yEnd: value)
                .foregroundStyle(style)
        }
    }
}

struct GridNode: View {
    let node: Node
    let columns: Int
    let theme: Theme
    let gap: Double
    let align: Align
    let path: String?

    var body: some View {
        let cells = Array(zip(node.childIDs, node.children))
        let rows = stride(from: 0, to: cells.count, by: columns).map { cells[$0..<min($0 + columns, cells.count)] }
        Grid(alignment: Alignment(horizontal: HorizontalAlignment(align), vertical: .center), horizontalSpacing: gap, verticalSpacing: gap) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.0) { id, child in NodeView(node: child, theme: theme, path: path.map { "\($0)/\(id.label)" }) }
                }
            }
        }
    }
}
