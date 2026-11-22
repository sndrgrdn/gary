import CoreGraphics
import Foundation
@testable import GaryCore
import Testing

struct NodeDrawingTests {
    private func parse(_ text: String) throws -> Node {
        try Node.parse(JSON.parse(text))
    }

    @Test func `a shape reads its view box and each path with defaults`() throws {
        let node = try parse(#"""
        {"type":"shape","viewBox":[24,24],"width":48,"paths":[
          {"d":"M0 0 L24 24"},
          {"d":"M12 2 L12 22","fill":"accent","stroke":{"gradient":"linear","colors":["a","b"]},"lineWidth":2,
           "cap":"round","join":"bevel","dash":[4,2],"trim":[0,0.75]}
        ]}
        """#)
        #expect(node.content == .shape(Node.Shape(paths: [
            ShapePath(SVGPath([.move(.zero), .line(CGPoint(x: 24, y: 24))])),
            ShapePath(
                SVGPath([.move(CGPoint(x: 12, y: 2)), .line(CGPoint(x: 12, y: 22))]),
                fill: "accent",
                stroke: .gradient(Gradient(.linear, colors: ["a", "b"])),
                lineWidth: 2,
                cap: .round,
                join: .bevel,
                dash: [4, 2],
                trim: 0...0.75,
            ),
        ], viewBox: CGSize(width: 24, height: 24))))
        #expect(node.props.width == 48)
        #expect(try parse(#"{"type":"shape","paths":[]}"#).content == .shape(Node.Shape(paths: [])))
    }

    @Test(arguments: [
        (#"{"type":"shape"}"#, "root", "paths must be an array"),
        (#"{"type":"shape","viewBox":[0,24],"paths":[]}"#, "root", "viewBox must be [width, height] of positive numbers"),
        (#"{"type":"shape","paths":[1]}"#, "root", "paths[0] must be an object"),
        (#"{"type":"shape","paths":[{"d":3}]}"#, "root", "paths[0].d must be an SVG path string"),
        (#"{"type":"shape","paths":[{"d":"M0 0 Q1"}]}"#, "root.paths[0].d", "expected a number at the end"),
        (#"{"type":"shape","paths":[{"d":"M0 0","trim":[0.8,0.2]}]}"#, "root", "paths[0].trim must be [from, to] with 0 <= from <= to <= 1"),
        (#"{"type":"shape","paths":[{"d":"M0 0","trim":[0,2]}]}"#, "root", "paths[0].trim must be [from, to] with 0 <= from <= to <= 1"),
        (#"{"type":"shape","paths":[{"d":"M0 0","dash":[-1]}]}"#, "root", "paths[0].dash must be an array of non-negative numbers"),
        (#"{"type":"shape","paths":[{"d":"M0 0","cap":"flat"}]}"#, "root", #"paths[0].cap must be one of "butt", "round", "square""#),
        (#"{"type":"shape","paths":[{"d":"M0 0","fill":"mix("}]}"#, "root", "paths[0].fill must be \(Paint.syntax)"),
        (#"{"type":"shape","paths":[{"d":"M0 0","lineWidth":-1}]}"#, "root", "paths[0].lineWidth must be a non-negative number"),
    ])
    func `a malformed shape fails with the field that is wrong`(_ text: String, _ path: String, _ reason: String) {
        #expect(throws: NodeError(path: path, reason: reason)) { try parse(text) }
    }

    @Test func `a chart reads its series and range and its domain comes from the data otherwise`() throws {
        let node = try parse(#"""
        {"type":"chart","min":0,"max":100,"axes":true,"series":[
          {"values":[1,2,3]},
          {"values":[5],"mark":"bar","color":"accent","smooth":true}
        ]}
        """#)
        let chart = Node.Chart(
            [ChartSeries([1, 2, 3]), ChartSeries([5], mark: .bar, color: "accent", smooth: true)],
            min: 0,
            max: 100,
            axes: true,
        )
        #expect(node.content == .chart(chart))
        #expect(chart.domain == 0...100)
        #expect(chart.count == 3)
        #expect(Node.Chart([ChartSeries([3, -2, 7])]).domain == -2...7)
        #expect(Node.Chart([ChartSeries([4, 4])]).domain == 4...5)
        #expect(Node.Chart([ChartSeries([1, 2])], min: 0).domain == 0...2)
        #expect(Node.Chart([ChartSeries([100, 100])], max: 100).domain == 99...100)
        #expect(Node.Chart([]).domain == 0...1)
    }

    @Test(arguments: [
        (#"{"type":"chart"}"#, "series must be an array"),
        (#"{"type":"chart","series":[{}]}"#, "series[0].values must be an array of numbers"),
        (#"{"type":"chart","series":[{"values":[1,"2"]}]}"#, "series[0].values must be an array of numbers"),
        (#"{"type":"chart","series":[{"values":[1],"mark":"pie"}]}"#, #"series[0].mark must be one of "line", "area", "bar""#),
        (#"{"type":"chart","series":[],"min":5,"max":5}"#, "max must be greater than min"),
        (#"{"type":"chart","series":[],"axes":"yes"}"#, "axes must be true or false"),
    ])
    func `a malformed chart fails with the field that is wrong`(_ text: String, _ reason: String) {
        #expect(throws: NodeError(path: "root", reason: reason)) { try parse(text) }
    }

    @Test func `a grid reads its columns and children`() throws {
        let node = try parse(#"{"type":"grid","columns":7,"children":[{"type":"text","text":"1"},{"type":"text","text":"2"}]}"#)
        #expect(node.content == .grid([Node(.text("1")), Node(.text("2"))], columns: 7))
        #expect(node.with(children: [Node(.spacer)]).content == .grid([Node(.spacer)], columns: 7))
        for bad in [#""columns":0"#, #""columns":1.5"#, #""columns":"7""#, ""] {
            let text = #"{"type":"grid","children":[]"# + (bad.isEmpty ? "" : ",\(bad)") + "}"
            #expect(throws: NodeError(path: "root", reason: "columns must be a whole number from 1 to 100"), "\(bad)") { try parse(text) }
        }
    }

    @Test func `a shader reads its file function arguments and animation`() throws {
        #expect(try parse(#"{"type":"shader","path":"glow.metal","function":"glow","args":[0.5,1],"animated":true}"#).content
            == .shader(Node.Shader(path: "glow.metal", function: "glow", args: [0.5, 1], animated: true)))
        #expect(try parse(#"{"type":"shader","path":"a.metal","function":"_f2"}"#).content == .shader(Node.Shader(path: "a.metal", function: "_f2")))
    }

    @Test(arguments: [
        (#"{"type":"shader","function":"glow"}"#, "path is required"),
        (#"{"type":"shader","path":"a.metal"}"#, "function is required"),
        (#"{"type":"shader","path":"a.metal","function":"glow(x)"}"#, "function must name a Metal function"),
        (#"{"type":"shader","path":"a.metal","function":"2d"}"#, "function must name a Metal function"),
        (#"{"type":"shader","path":"a.metal","function":"f","args":[true]}"#, "args must be an array of numbers"),
        (#"{"type":"shader","path":"a.metal","function":"f","animated":1}"#, "animated must be true or false"),
    ])
    func `a malformed shader fails with the field that is wrong`(_ text: String, _ reason: String) {
        #expect(throws: NodeError(path: "root", reason: reason)) { try parse(text) }
    }

    @Test func `a relative shader path resolves inside the plugin folder like an image`() throws {
        let tree = try parse(#"""
        {"type":"grid","columns":2,"children":[{"type":"shader","path":"fx/glow.metal","function":"glow"},
        {"type":"shader","path":"/abs.metal","function":"glow"}]}
        """#)
        let resolved = tree.resolvingPaths(against: URL(fileURLWithPath: "/plugins/you.fx"))
        #expect(resolved.children.map(\.content) == [
            .shader(Node.Shader(path: "/plugins/you.fx/fx/glow.metal", function: "glow")),
            .shader(Node.Shader(path: "/abs.metal", function: "glow")),
        ])
    }
}
