import CoreGraphics
@testable import GaryCore
import Testing

struct SVGPathTests {
    private func parse(_ text: String) throws -> [SVGPath.Element] {
        try SVGPath(text, path: "root.paths[0].d").elements
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: x, y: y)
    }

    private func end(_ element: SVGPath.Element?) -> CGPoint? {
        switch element {
        case let .move(point)?, let .line(point)?, let .quad(_, point)?, let .cubic(_, _, point)?: point
        case .close, nil: nil
        }
    }

    private func near(_ first: CGPoint?, _ second: CGPoint, within tolerance: Double = 1e-9) -> Bool {
        guard let first else { return false }
        return abs(first.x - second.x) <= tolerance && abs(first.y - second.y) <= tolerance
    }

    @Test func `reads absolute lines and closes the path`() throws {
        #expect(try parse("M1 2 L3 4 H10 V-1.5 Z") == [
            .move(point(1, 2)), .line(point(3, 4)), .line(point(10, 4)), .line(point(10, -1.5)), .close,
        ])
    }

    @Test func `relative commands move from the current point and z returns to the subpath start`() throws {
        #expect(try parse("m10,10 l5,0 h-2 v3 z m1 1 l1 1") == [
            .move(point(10, 10)), .line(point(15, 10)), .line(point(13, 10)), .line(point(13, 13)), .close,
            .move(point(11, 11)), .line(point(12, 12)),
        ])
    }

    @Test func `pairs after a move are lines and other commands repeat`() throws {
        #expect(try parse("M0 0 1 1 2 0") == [.move(point(0, 0)), .line(point(1, 1)), .line(point(2, 0))])
        #expect(try parse("m1 1 1 1") == [.move(point(1, 1)), .line(point(2, 2))])
        #expect(try parse("M0 0 L1 1 2 2") == [.move(point(0, 0)), .line(point(1, 1)), .line(point(2, 2))])
    }

    @Test func `numbers may run together with signs dots and exponents`() throws {
        #expect(try parse("M-1-2L.5.5l1e1-1E-1") == [.move(point(-1, -2)), .line(point(0.5, 0.5)), .line(point(10.5, 0.4))])
    }

    @Test func `cubic and quad curves reflect the previous control point for s and t`() throws {
        #expect(try parse("M0 0 C1 1 2 1 3 0 S5 -1 6 0") == [
            .move(point(0, 0)),
            .cubic(point(1, 1), point(2, 1), point(3, 0)),
            .cubic(point(4, -1), point(5, -1), point(6, 0)),
        ])
        #expect(try parse("M0 0 Q1 1 2 0 T4 0 t2 0") == [
            .move(point(0, 0)), .quad(point(1, 1), point(2, 0)), .quad(point(3, -1), point(4, 0)), .quad(point(5, 1), point(6, 0)),
        ])
        #expect(try parse("M0 0 L1 0 S2 1 3 0 T4 0") == [
            .move(point(0, 0)), .line(point(1, 0)), .cubic(point(1, 0), point(2, 1), point(3, 0)), .quad(point(3, 0), point(4, 0)),
        ])
        #expect(try parse("m1 1 c1 1 2 1 3 0 q1 1 2 0") == [
            .move(point(1, 1)), .cubic(point(2, 2), point(3, 2), point(4, 1)), .quad(point(5, 2), point(6, 1)),
        ])
    }

    @Test func `an arc becomes cubics that end where the arc ends and stay on the circle`() throws {
        let elements = try parse("M12 2 A10 10 0 1 1 11.99 2")
        #expect(elements.count == 5)
        #expect(near(end(elements.last), point(11.99, 2)))
        for element in elements.dropFirst() {
            let point = try #require(end(element))
            #expect(abs(hypot(point.x - 12, point.y - 12) - 10) < 0.01)
        }
        let half = try parse("M0 0 a5 5 0 0 1 10 0")
        #expect(half.count == 3)
        #expect(near(end(half[1]), point(5, -5), within: 1e-6))
        #expect(near(end(half[2]), point(10, 0)))
    }

    @Test func `s and t after an arc start from the current point`() throws {
        let smooth = try parse("M0 0 A5 5 0 0 1 10 0 S15 5 20 0")
        #expect(smooth.last == .cubic(point(10, 0), point(15, 5), point(20, 0)))
        let skipped = try parse("M0 0 C1 1 2 1 3 0 A5 5 0 0 1 3 0 S5 1 6 0 Q7 1 8 0 A5 5 0 0 1 8 0 T10 0")
        #expect(skipped.dropFirst(2) == [
            .cubic(point(3, 0), point(5, 1), point(6, 0)),
            .quad(point(7, 1), point(8, 0)),
            .quad(point(8, 0), point(10, 0)),
        ])
    }

    @Test func `the arc flags pick the side and the sweep and may run together`() throws {
        let below = try parse("M0 0 A5 5 0 0 0 10 0")
        #expect(near(end(below[1]), point(5, 5), within: 1e-6))
        #expect(try parse("M0 0 a5 5 0 0010 0") == below)
    }

    @Test func `a small arc radius grows to reach the end point and a zero radius draws a line`() throws {
        let grown = try parse("M0 0 A1 1 0 0 1 10 0")
        #expect(near(end(grown[1]), point(5, -5), within: 1e-6))
        #expect(try parse("M0 0 A0 5 0 0 1 10 0") == [.move(point(0, 0)), .line(point(10, 0))])
        #expect(try parse("M3 3 A5 5 0 0 1 3 3") == [.move(point(3, 3))])
    }

    @Test func `an empty path draws nothing`() throws {
        #expect(try parse("  ").isEmpty)
    }

    @Test(arguments: [
        ("L1 1", "must start with M or m at \"L\", character 1"),
        ("M0 0 X1 1", "unknown command at \"X\", character 6"),
        ("M0 0 L1", "expected a number at the end"),
        ("M0 0 Lfoo", "expected a number at \"foo\", character 7"),
        ("M0 0 A5 5 0 2 1 10 0", "expected an arc flag, 0 or 1 at \"2\", character 13"),
        ("M0 0 L1 1e", "unknown command at \"e\", character 10"),
    ])
    func `a bad token fails with its text and position`(_ text: String, _ reason: String) {
        #expect(throws: NodeError(path: "root.paths[0].d", reason: reason)) { try parse(text) }
    }
}
