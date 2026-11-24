import AppKit
@testable import gary
import GaryCore
import Testing

@MainActor
struct BarWindowTests {
    private static let theme = try? Theme.parse(
        JSON.parse(Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "Resources/theme.json"))),
        palette: Palette(nil, system: .dark),
    ).inBar

    private func view(_ text: String, theme: Theme) -> TreeHostingView {
        TreeHostingView(
            tree: MountedTree(root: Node(.text(text)), theme: theme),
            onAction: { _ in Issue.record("unexpected action") },
            onDismiss: { Issue.record("unexpected dismiss") },
        )
    }

    private func minX(_ view: NSView, in bar: BarWindow) -> CGFloat {
        bar.content.layoutSubtreeIfNeeded()
        return view.convert(view.bounds, to: nil).minX
    }

    @Test func `a bar widget that renders null leaves no gap and comes back with one when it renders a node`() throws {
        let theme = try #require(Self.theme)
        let bar = BarWindow(display: display, level: 0)
        defer { bar.close() }
        bar.layout(theme: theme)
        let clock = view("12:00", theme: theme)
        let indicator = view("●", theme: theme)
        bar.setSection(.center, [clock])
        let alone = minX(clock, in: bar)

        _ = indicator.apply(nil)
        bar.setSection(.center, [indicator, clock])
        #expect(minX(clock, in: bar) == alone)

        #expect(indicator.apply(Node(.text("●"))))
        let shown = minX(clock, in: bar)
        let gap: Double = shown - indicator.convert(indicator.bounds, to: nil).maxX
        #expect(gap == theme.spacing.section)

        #expect(indicator.apply(nil))
        #expect(minX(clock, in: bar) == alone)
    }

    @Test func `notchLeft ends and center starts at the notch, and without one center is centred with notchLeft beside it`() throws {
        let theme = try #require(Self.theme)
        for notch in [nil, 760.0...968.0] {
            let screen = DisplayInfo(id: "built-in", index: 0, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), band: 32, notch: notch)
            let bar = BarWindow(display: screen, level: 0)
            defer { bar.close() }
            bar.layout(theme: theme)
            let menu = view("menu", theme: theme)
            let music = view("music", theme: theme)
            let indicator = view("●", theme: theme)
            let clock = view("12:00", theme: theme)
            let battery = view("battery", theme: theme)
            bar.setSection(.left, [menu])
            bar.setSection(.notchLeft, [music])
            bar.setSection(.center, [indicator, clock])
            bar.setSection(.right, [battery])
            bar.content.layoutSubtreeIfNeeded()
            let frames = [menu, music, indicator, clock, battery].map { $0.convert($0.bounds, to: nil) }
            let gap = theme.bar.gap

            #expect(frames[0].maxX < frames[1].minX && frames[3].maxX < frames[4].minX)
            if let notch {
                #expect(abs(frames[1].maxX - (notch.lowerBound - gap)) < 0.001)
                #expect(abs(frames[2].minX - (notch.upperBound + gap)) < 0.001)
            } else {
                #expect(abs((frames[2].minX + frames[3].maxX) / 2 - 864) < 0.001)
                #expect(abs(frames[2].minX - frames[1].maxX - gap) < 0.001)
            }
        }
    }

    @Test func `crowded sections truncate inside the screen, the notch and each other, and left and right keep their width`() throws {
        let theme = try #require(Self.theme)
        let sections: [BarSection] = [.left, .notchLeft, .center, .right]
        let crowds = sections.map { [$0] } + sections.indices.flatMap { index in sections[(index + 1)...].map { [sections[index], $0] } } + [sections]
        for notch in [nil, 760.0...968.0] {
            let screen = DisplayInfo(id: "built-in", index: 0, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117), band: 32, notch: notch)
            func frames(wide: [BarSection]) -> [BarSection: CGRect] {
                let bar = BarWindow(display: screen, level: 0)
                defer { bar.close() }
                bar.layout(theme: theme)
                let views = sections.map { section in
                    let text = wide.contains(section) ? String(repeating: "A very long title ", count: 40) : "\(section)"
                    let widget = view(text, theme: theme)
                    bar.setSection(section, [widget])
                    return (section, widget)
                }
                bar.content.layoutSubtreeIfNeeded()
                return Dictionary(uniqueKeysWithValues: views.map { ($0, $1.convert($1.bounds, to: nil)) })
            }
            let roomy = frames(wide: [])
            for wide in crowds {
                let crowded = frames(wide: wide)
                let left = try #require(crowded[.left])
                let notchLeft = try #require(crowded[.notchLeft])
                let center = try #require(crowded[.center])
                let right = try #require(crowded[.right])
                let edge = theme.bar.edge
                #expect(left.minX >= edge - 0.5 && right.maxX <= screen.frame.width - edge + 0.5, "\(wide) \(crowded)")
                #expect(
                    left.maxX <= notchLeft.minX + 0.5 && notchLeft.maxX <= center.minX + 0.5 && center.maxX <= right.minX + 0.5,
                    "\(wide) \(crowded)",
                )
                if let notch {
                    #expect(notchLeft.maxX <= notch.lowerBound + 0.5 && center.minX >= notch.upperBound - 0.5, "\(wide) \(crowded)")
                }
                for section in [BarSection.left, .right] where !wide.contains(section) {
                    #expect(abs((crowded[section]?.width ?? 0) - (roomy[section]?.width ?? 0)) < 0.5, "\(wide) \(section) \(crowded)")
                }
            }
        }
    }
}
