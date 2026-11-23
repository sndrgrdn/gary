@preconcurrency import JavaScriptCore

nonisolated enum Stage: String, CaseIterable {
    case evaluate, encode
    case jsParse = "js_parse"
    case handler, render, stringify
    case swiftParse = "swift_parse"
    case nodeParse = "node_parse"
    case compare, apply, layout, display, flush
}

nonisolated struct Timings {
    private var seconds: [Stage: Double] = [:]

    mutating func add(_ stage: Stage, _ duration: Double) {
        seconds[stage, default: 0] += duration
    }

    mutating func merge(_ other: Self) {
        seconds.merge(other.seconds, uniquingKeysWith: +)
    }

    var fields: String {
        Stage.allCases.compactMap { stage in seconds[stage].map { String(format: "%@_ms=%.3f", stage.rawValue, $0 * 1000) } }
            .joined(separator: " ")
    }
}

@discardableResult
nonisolated func measure<T>(_ stage: Stage, _ timings: inout Timings, _ body: () throws -> T) rethrows -> T {
    guard tracing else { return try body() }
    let start = now()
    defer { timings.add(stage, now() - start) }
    return try body()
}

nonisolated extension JSValue {
    func call(_ arguments: [Any], timing stages: [Stage], into timings: inout Timings) -> JSValue? {
        guard tracing, !stages.isEmpty else { return call(withArguments: arguments) }
        var marks = [now()]
        let mark: @convention(block) () -> Void = { marks.append(now()) }
        let result = call(withArguments: stages.count > 1 ? arguments + [mark] : arguments)
        marks.append(now())
        for (stage, (start, end)) in zip(stages, zip(marks, marks.dropFirst())) {
            timings.add(stage, end - start)
        }
        return result
    }
}
