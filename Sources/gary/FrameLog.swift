import AppKit
import GaryCore
import os

final class FrameLog: NSObject {
    static let shared = FrameLog()

    private static let settle = 0.25
    private static let listedHitches = 50
    private static let signposter = OSSignposter(subsystem: "com.sndrgrdn.gary", category: .pointsOfInterest)

    private struct Display {
        let name: String
        let rate: Int
        let link: CADisplayLink
        var shown: Double?
        var frames: [Frame] = []
    }

    private struct Open {
        let work: FrameWork
        var since: Double
        let signpost: OSSignpostIntervalState
    }

    private var displays: [String: Display] = [:]
    private var spans: [FrameSpan] = []
    private var open: [Open] = []
    private var armed: Double?
    private var until = 0.0
    private var watchedUntil = 0.0
    private var asleepSince: Double?
    private var observers: [CFRunLoopObserver] = []

    func record<T>(_ work: FrameWork, _ body: () throws -> T) rethrows -> T {
        extend()
        begin(work)
        defer {
            end()
            extend()
        }
        return try body()
    }

    func watch(for seconds: Double) {
        watchedUntil = max(watchedUntil, CACurrentMediaTime() + seconds)
        arm(for: seconds)
    }

    private func extend() {
        if armed != nil || CACurrentMediaTime() < watchedUntil {
            arm(for: 0)
        }
    }

    func arm(for seconds: Double) {
        let now = CACurrentMediaTime()
        until = max(until, now + seconds + Self.settle)
        if armed == nil {
            start(at: now)
        }
    }

    private func begin(_ work: FrameWork) {
        let now = CACurrentMediaTime()
        if let parent = open.last, armed != nil {
            spans.append(FrameSpan(parent.work, from: parent.since, to: now))
        }
        open.append(Open(work: work, since: now, signpost: Self.beginSignpost(work)))
    }

    private func end() {
        let now = CACurrentMediaTime()
        let span = open.removeLast()
        Self.signposter.endInterval("frame-work", span.signpost)
        if armed != nil {
            spans.append(FrameSpan(span.work, from: span.since, to: now))
        }
        if !open.isEmpty {
            open[open.count - 1].since = now
        }
    }

    private static func beginSignpost(_ work: FrameWork) -> OSSignpostIntervalState {
        let label = work.label
        return signposter.beginInterval("frame-work", id: signposter.makeSignpostID(), "\(label, privacy: .public)")
    }

    private func start(at now: Double) {
        armed = now
        let screens = NSScreen.screens
        let ids = Set(screens.map(\.uuid))
        for (id, display) in displays where !ids.contains(id) {
            display.link.invalidate()
            displays[id] = nil
        }
        for screen in screens where displays[screen.uuid] == nil {
            let link = screen.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displays[screen.uuid] = Display(name: screen.localizedName, rate: screen.maximumFramesPerSecond, link: link)
        }
        for id in displays.keys {
            displays[id]?.shown = nil
            displays[id]?.link.isPaused = false
        }
        observers = [
            observer(.beforeWaiting, order: 1_999_999) { log, _ in log.begin(.commit) },
            observer([.beforeWaiting, .afterWaiting], order: CFIndex.max) { log, activity in log.sleep(activity == .beforeWaiting) },
        ]
        for observer in observers {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        }
    }

    private func observer(
        _ activities: CFRunLoopActivity,
        order: CFIndex,
        _ run: @escaping (FrameLog, CFRunLoopActivity) -> Void,
    ) -> CFRunLoopObserver {
        CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, order) { [weak self] _, activity in
            MainActor.assumeIsolated {
                if let self {
                    run(self, activity)
                }
            }
        }
    }

    private func sleep(_ falling: Bool) {
        if falling {
            if open.last?.work == .commit {
                end()
            }
            asleepSince = CACurrentMediaTime()
        } else if let since = asleepSince {
            spans.append(FrameSpan(.asleep, from: since, to: CACurrentMediaTime()))
            asleepSince = nil
        }
    }

    private func stop(at now: Double) {
        armed = nil
        asleepSince = nil
        for observer in observers {
            CFRunLoopObserverInvalidate(observer)
        }
        observers = []
        for display in displays.values {
            display.link.isPaused = true
        }
        let kept = now - Frame.kept
        spans.removeAll { $0.end < kept }
        for id in displays.keys {
            displays[id]?.frames.removeAll { $0.end < kept }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard let armed, let id = displays.first(where: { $0.value.link === link })?.key, let display = displays[id] else { return }
        let interval = link.targetTimestamp - link.timestamp
        let frame = display.shown.map { Frame(start: $0, end: link.timestamp, interval: interval) }
            ?? Frame.afterArming(armed, shown: link.timestamp, interval: interval)
        if let frame, frame.duration > 0 {
            displays[id]?.frames.append(frame)
        }
        if link.timestamp > display.shown ?? 0 {
            displays[id]?.shown = link.timestamp
        }
        if now > until {
            stop(at: now)
        } else if let oldest = display.frames.first, oldest.end < now - 2 * Frame.kept {
            displays[id]?.frames.removeAll { $0.end < now - Frame.kept }
            spans.removeAll { $0.end < now - Frame.kept }
        }
    }

    func report(since: Double?) -> String {
        let from = since ?? CACurrentMediaTime() - Frame.kept
        let sorted = displays.values.sorted { $0.name < $1.name }
        guard !sorted.isEmpty else { return "no frames recorded: no surface has changed or animated since Gary started" }
        return sorted.map { display in
            let frames = display.frames.filter { $0.end > from }
            return Self.describe(display, FrameSummary(frames, spans: spans), origin: since ?? frames.first?.start ?? from)
        }.joined(separator: "\n\n")
    }

    func hitches(since start: Double) -> [(time: Double, fields: [String: JSON])] {
        displays.values.flatMap { display in
            FrameSummary(display.frames.filter { $0.end > start }, spans: spans).hitches.map { hitch in
                (hitch.frame.start, [
                    "display": .string(display.name),
                    "ms": .number((hitch.frame.duration * 1e6).rounded() / 1000),
                    "missed": .number(Double(hitch.frame.missed)),
                    "causes": .object(Dictionary(uniqueKeysWithValues: hitch.causes
                            .map { ($0.work.label, .number(($0.seconds * 1e6).rounded() / 1000)) })),
                ])
            }
        }
    }

    private static func describe(_ display: Display, _ summary: FrameSummary, origin: Double) -> String {
        let head = "\(display.name) at \(display.rate) Hz"
        guard summary.frames > 0 else { return "\(head): no frames recorded, since no surface changed or animated" }
        var lines = [
            "\(head): \(summary.isSmooth ? "holds its refresh rate" : "drops frames"), "
                + "\(format(summary.hitchRatio)) ms of hitches per second over \(format(summary.seconds, 2)) s recorded",
            "  \(summary.frames) frames, frame time p50 \(ms(summary.p50)), p99 \(ms(summary.p99)), max \(ms(summary.max)), "
                + "\(summary.hitches.count) hitch\(summary.hitches.count == 1 ? "" : "es")",
        ]
        let listed = summary.hitches.sorted { $0.frame.duration > $1.frame.duration }.prefix(listedHitches).sorted { $0.frame.end < $1.frame.end }
        lines += listed.map { hitch in
            let causes = hitch.causes.map { "\($0.work.label) \(ms($0.seconds))" }.joined(separator: ", ")
            return "  +\(format(hitch.frame.start - origin, 3)) s  \(ms(hitch.frame.duration)), "
                + "\(hitch.frame.missed) missed: \(causes)"
        }
        if summary.hitches.count > listed.count {
            lines.append("  and \(summary.hitches.count - listed.count) shorter hitches")
        }
        return lines.joined(separator: "\n")
    }

    private static func ms(_ seconds: Double) -> String {
        "\(format(seconds * 1000)) ms"
    }

    private static func format(_ value: Double, _ digits: Int = 1) -> String {
        String(format: "%.\(digits)f", value)
    }
}
