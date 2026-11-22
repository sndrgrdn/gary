import Foundation
import GaryCore

extension Skill {
    static let drawingSection = """
    ## Drawing

    ### Paint

    `background`, the `fill` and `stroke` of a `shape` path, and the `color` of a `chart` series take a paint: a color, or a gradient object.

    | Field | Value |
    | --- | --- |
    | `gradient` | \(Gradient.Kind.allCases.map { "`\"\($0.rawValue)\"`" }.joined(separator: ", ")) |
    | `colors` | Two or more colors, spread evenly from start to end. |
    | `angle` | Degrees, `0` by default. A linear gradient runs left to right at `0` and top to bottom at `90`. An angular gradient starts at this angle. A radial gradient spreads from the center and ignores it. |

    ```ts
    { type: "column", style: "panel", background: { gradient: "linear", colors: ["accent", "alpha(accent, 0.2)"], angle: 90 } }
    ```

    A style in `theme.json` takes a gradient `background` too.

    ### Rotate, blur, blend, and loop

    - `rotation` turns a node clockwise around its center by degrees, or counterclockwise when negative, without changing its layout. It animates like `scale`.
    - `blur` blurs the node by a radius in points.
    - `blend` sets how the node's colors mix with what is drawn under it: \(Blend.allCases.map { "`\"\($0.rawValue)\"`" }.joined(separator: ", ")).
    - `loop` animates the node forever without calling `render` again. Each of \(Loop.Property.allCases.map { "`\($0.rawValue)`" }.joined(separator: ", ")) is `[from, to]`. The node moves from `from` to `to` over `duration` seconds, 1 by default, and starts again. With `reverse: true` it eases back to `from` before it starts again. The loop combines with the node's own `opacity`, `scale`, `rotation`, `x`, and `y`. `hovered` and `pressed` can set a loop. Reduce Motion turns loops off.

    ```ts
    { type: "icon", symbol: "arrow.triangle.2.circlepath", loop: { rotation: [0, 360], duration: 1.5 } }
    { type: "text", text: "Live", loop: { opacity: [0.4, 1], scale: [0.95, 1.05], reverse: true } }
    ```

    ### shape

    A `shape` draws SVG paths. It is as large as its `viewBox`, or 24 by 24 points, unless it has a `width` and `height`.

    | Field | Value |
    | --- | --- |
    | `viewBox` | `[width, height]`, the space the paths are drawn in. They scale from it to the node's size. It is the node's size by default. |
    | `paths` | The paths, drawn in order, each an object with the fields below. |
    | `d` | SVG path data with the commands `M`, `L`, `H`, `V`, `C`, `S`, `Q`, `T`, `A`, and `Z`, absolute in upper case and relative in lower case. A path that does not parse fails the render and names the bad token. |
    | `fill`, `stroke` | Paints. A path with neither fills with the node's `color`. |
    | `lineWidth` | The stroke width in `viewBox` units, `1` by default. |
    | `cap` | \(ShapePath.Cap.allCases.map { "`\"\($0.rawValue)\"`" }.joined(separator: ", ")). `"butt"` by default. |
    | `join` | \(ShapePath.Join.allCases.map { "`\"\($0.rawValue)\"`" }.joined(separator: ", ")). `"miter"` by default. |
    | `dash` | Lengths of dashes and gaps in `viewBox` units, such as `[4, 2]`. |
    | `trim` | `[from, to]`, the part of the path to draw as fractions of its length, `[0, 1]` by default. Under an `animation`, a change of `trim` moves smoothly, so a progress ring grows. |

    ```ts
    const ring = "M12 2 A10 10 0 1 1 11.99 2";
    { type: "shape", width: 48, height: 48, viewBox: [24, 24], animation: "smooth", paths: [
      { d: ring, stroke: "alpha(foreground, 0.15)", lineWidth: 3 },
      { d: ring, stroke: "accent", lineWidth: 3, cap: "round", trim: [0, progress] },
    ] }
    ```

    ### chart

    A `chart` plots numbers with Swift Charts. Each value sits at its index along the x axis. It is 60 by 16 points unless it has a `width` and `height`.

    | Field | Value |
    | --- | --- |
    | `series` | The series, each `{ values, mark, color, smooth }`. `values` is an array of numbers. `mark` is \(ChartSeries.Mark.allCases.map { "`\"\($0.rawValue)\"`" }.joined(separator: ", ")), `"line"` by default. `color` is a paint, the node's `color` by default. `smooth: true` curves a line or area through its points. |
    | `min`, `max` | The range of the y axis. Without them the lowest and highest values set it. A value outside the range draws at its edge. |
    | `axes` | `true` draws axes with labels and grid lines. Without it the chart is a sparkline that fills the node. |

    ```ts
    { type: "chart", width: 80, height: 20, min: 0, max: 100, series: [{ values: cpu, mark: "area", color: "alpha(accent, 0.4)", smooth: true }] }
    ```

    ### grid

    A `grid` places its `children` in rows of `columns` cells, left to right. `gap` sets the space between rows and columns, and `align` places each cell in its column. A column is as wide as its widest cell, so give the cells a `width` for even columns. A month calendar is a 7-column grid of day numbers.

    ```ts
    { type: "grid", columns: 7, gap: 4, align: "center", children: days.map((day) => ({ type: "text", text: day, width: 24, align: "center" })) }
    ```

    ### shader

    A `shader` draws a Metal fragment function into its frame. It is 100 by 100 points unless it has a `width` or `height`. It draws only its own frame and does not change other nodes.

    | Field | Value |
    | --- | --- |
    | `path` | A `.metal` file, absolute, from `~`, or relative to the plugin folder. |
    | `function` | The name of the function to call for each pixel. |
    | `args` | Numbers the function reads as `args`, at most \(Node.Shader.maxArgs). |
    | `animated` | `true` advances `time` at the display's refresh rate while the node is on screen. Otherwise `time` is `0` and Gary draws again only when the node changes. Reduce Motion keeps `time` at `0`. |

    The function has this signature. `position` and `size` are in points from the top left corner, `time` is in seconds since the node appeared, and `count` is the number of `args`. It returns a color with straight alpha, so `half4(1, 0, 0, 0.5)` is half-transparent red.

    ```metal
    half4 glow(float2 position, float2 size, float time, constant float *args, uint count) {
        float d = distance(position, size / 2) / (min(size.x, size.y) / 2);
        return half4(1, 0.6, 0.2, saturate(1 - d) * (0.6 + 0.4 * sin(time * 2)));
    }
    ```

    Gary adds `#include <metal_stdlib>` and `using namespace metal;` before the file and compiles it off the main thread when the node first draws. It compiles the file again when its modification date has changed by the time the node changes or is next shown. A compile error writes `plugin <id>: shader <path>: <error>` to the log, and the node draws nothing.
    """
}
