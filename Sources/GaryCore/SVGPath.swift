import CoreGraphics
import Foundation

public struct SVGPath: Equatable, Sendable {
    public enum Element: Equatable, Sendable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint)
        case close
    }

    public var elements: [Element]

    public init(_ elements: [Element]) {
        self.elements = elements
    }

    public init(_ text: String, path: String) throws(NodeError) {
        var scanner = Scanner(bytes: Array(text.utf8), path: path)
        elements = try scanner.parse()
    }
}

private struct Scanner {
    let bytes: [UInt8]
    let path: String
    var index = 0
    var elements: [SVGPath.Element] = []
    var current = CGPoint.zero
    var start = CGPoint.zero
    var cubicControl: CGPoint?
    var quadControl: CGPoint?

    init(bytes: [UInt8], path: String) {
        self.bytes = bytes
        self.path = path
    }

    mutating func parse() throws(NodeError) -> [SVGPath.Element] {
        skipSeparators()
        guard index < bytes.count else { return [] }
        guard bytes[index] == UInt8(ascii: "M") || bytes[index] == UInt8(ascii: "m") else { throw fail("must start with M or m") }
        while index < bytes.count {
            let letter = bytes[index]
            index += 1
            try command(letter)
            skipSeparators()
        }
        return elements
    }

    private mutating func command(_ letter: UInt8) throws(NodeError) {
        let relative = letter >= UInt8(ascii: "a")
        let upper = relative ? letter - 32 : letter
        var first = true
        repeat {
            let origin = relative ? current : .zero
            switch upper {
            case UInt8(ascii: "M"):
                let point = try point(origin)
                if first {
                    append(.move(point))
                    start = point
                } else {
                    append(.line(point))
                }
            case UInt8(ascii: "L"): try append(.line(point(origin)))
            case UInt8(ascii: "H"): try append(.line(CGPoint(x: origin.x + number(), y: current.y)))
            case UInt8(ascii: "V"): try append(.line(CGPoint(x: current.x, y: origin.y + number())))
            case UInt8(ascii: "C"): try append(.cubic(point(origin), point(origin), point(origin)))
            case UInt8(ascii: "S"):
                let control = reflected(cubicControl)
                try append(.cubic(control, point(origin), point(origin)))
            case UInt8(ascii: "Q"): try append(.quad(point(origin), point(origin)))
            case UInt8(ascii: "T"): try append(.quad(reflected(quadControl), point(origin)))
            case UInt8(ascii: "A"): try arc(origin)
            case UInt8(ascii: "Z"):
                append(.close)
                current = start
                return
            default:
                index -= 1
                throw fail("unknown command")
            }
            first = false
        } while hasNumber()
    }

    private mutating func append(_ element: SVGPath.Element) {
        elements.append(element)
        (cubicControl, quadControl) = (nil, nil)
        switch element {
        case let .move(point), let .line(point): current = point
        case let .quad(control, point): (quadControl, current) = (control, point)
        case let .cubic(_, control, point): (cubicControl, current) = (control, point)
        case .close: break
        }
    }

    private func reflected(_ control: CGPoint?) -> CGPoint {
        guard let control else { return current }
        return CGPoint(x: 2 * current.x - control.x, y: 2 * current.y - control.y)
    }

    private mutating func arc(_ origin: CGPoint) throws(NodeError) {
        let radii = try CGPoint(x: abs(number()), y: abs(number()))
        let rotation = try number() * .pi / 180
        let large = try flag()
        let sweep = try flag()
        let end = try point(origin)
        guard end != current else { return }
        guard radii.x > 0, radii.y > 0 else { append(.line(end))
            return
        }
        for curve in Arc(from: current, to: end, radii: radii, rotation: rotation, large: large, sweep: sweep).curves() {
            append(curve)
        }
    }

    private mutating func point(_ origin: CGPoint) throws(NodeError) -> CGPoint {
        try CGPoint(x: origin.x + number(), y: origin.y + number())
    }

    private mutating func skipSeparators() {
        while index < bytes.count, [UInt8(ascii: " "), 9, 10, 13, 12, UInt8(ascii: ",")].contains(bytes[index]) {
            index += 1
        }
    }

    private mutating func hasNumber() -> Bool {
        skipSeparators()
        guard index < bytes.count else { return false }
        return Self.startsNumber(bytes[index])
    }

    private static func startsNumber(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "+") || byte == UInt8(ascii: ".")
    }

    private mutating func flag() throws(NodeError) -> Bool {
        skipSeparators()
        guard index < bytes.count,
              bytes[index] == UInt8(ascii: "0") || bytes[index] == UInt8(ascii: "1") else { throw fail("expected an arc flag, 0 or 1") }
        index += 1
        return bytes[index - 1] == UInt8(ascii: "1")
    }

    private mutating func number() throws(NodeError) -> Double {
        skipSeparators()
        let begin = index
        func digits() -> Bool {
            let from = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            return index > from
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
            index += 1
        }
        var found = digits()
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            found = digits() || found
        }
        if found, index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            let mark = index
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
                index += 1
            }
            if !digits() {
                index = mark
            }
        }
        guard found, let value = Double(String(decoding: bytes[begin..<index], as: UTF8.self)), value.isFinite else {
            index = begin
            throw fail("expected a number")
        }
        return value
    }

    private func fail(_ reason: String) -> NodeError {
        guard index < bytes.count else { return NodeError(path: path, reason: "\(reason) at the end") }
        var end = index + 1
        while end < bytes.count, end - index < 12, !Self.startsNumber(bytes[end]), bytes[end] > 32, bytes[end] != UInt8(ascii: ",") {
            end += 1
        }
        let token = String(decoding: bytes[index..<end], as: UTF8.self)
        return NodeError(path: path, reason: "\(reason) at \"\(token)\", character \(index + 1)")
    }
}

private struct Arc {
    let from: CGPoint
    let to: CGPoint
    let radii: CGPoint
    let rotation: Double
    let large: Bool
    let sweep: Bool

    private struct Ellipse {
        let center: CGPoint
        let radius: CGPoint
        let rotation: Double
        let start: Double
        let span: Double

        func point(_ angle: Double) -> CGPoint {
            CGPoint(
                x: center.x + radius.x * cos(angle) * cos(rotation) - radius.y * sin(angle) * sin(rotation),
                y: center.y + radius.x * cos(angle) * sin(rotation) + radius.y * sin(angle) * cos(rotation),
            )
        }

        func tangent(_ angle: Double) -> CGPoint {
            CGPoint(
                x: -radius.x * sin(angle) * cos(rotation) - radius.y * cos(angle) * sin(rotation),
                y: -radius.x * sin(angle) * sin(rotation) + radius.y * cos(angle) * cos(rotation),
            )
        }
    }

    func curves() -> [SVGPath.Element] {
        let ellipse = ellipse()
        let count = max(1, Int((abs(ellipse.span) / (.pi / 2)).rounded(.up)))
        let step = ellipse.span / Double(count)
        let handle = 4.0 / 3 * tan(step / 4)
        return (0..<count).map { segment in
            let first = ellipse.start + Double(segment) * step
            let second = first + step
            let begin = ellipse.point(first)
            let end = segment == count - 1 ? to : ellipse.point(second)
            let out = ellipse.tangent(first)
            let into = ellipse.tangent(second)
            return .cubic(
                CGPoint(x: begin.x + handle * out.x, y: begin.y + handle * out.y),
                CGPoint(x: end.x - handle * into.x, y: end.y - handle * into.y),
                end,
            )
        }
    }

    private func ellipse() -> Ellipse {
        let cosine = cos(rotation)
        let sine = sin(rotation)
        let half = CGPoint(x: (from.x - to.x) / 2, y: (from.y - to.y) / 2)
        let prime = CGPoint(x: cosine * half.x + sine * half.y, y: -sine * half.x + cosine * half.y)
        var radius = radii
        let lambda = prime.x * prime.x / (radius.x * radius.x) + prime.y * prime.y / (radius.y * radius.y)
        if lambda > 1 {
            radius.x *= lambda.squareRoot()
            radius.y *= lambda.squareRoot()
        }
        let wide = radius.x * radius.x
        let tall = radius.y * radius.y
        let numerator = wide * tall - wide * prime.y * prime.y - tall * prime.x * prime.x
        let denominator = wide * prime.y * prime.y + tall * prime.x * prime.x
        let coefficient = (large == sweep ? -1 : 1) * max(0, numerator / denominator).squareRoot()
        let centerPrime = CGPoint(x: coefficient * radius.x * prime.y / radius.y, y: -coefficient * radius.y * prime.x / radius.x)
        let center = CGPoint(
            x: cosine * centerPrime.x - sine * centerPrime.y + (from.x + to.x) / 2,
            y: sine * centerPrime.x + cosine * centerPrime.y + (from.y + to.y) / 2,
        )
        let startAngle = atan2((prime.y - centerPrime.y) / radius.y, (prime.x - centerPrime.x) / radius.x)
        var sweepAngle = atan2((-prime.y - centerPrime.y) / radius.y, (-prime.x - centerPrime.x) / radius.x) - startAngle
        if !sweep, sweepAngle > 0 {
            sweepAngle -= 2 * .pi
        } else if sweep, sweepAngle < 0 {
            sweepAngle += 2 * .pi
        }
        return Ellipse(center: center, radius: radius, rotation: rotation, start: startAngle, span: sweepAngle)
    }
}
