import Foundation

public struct Equalizer: Equatable, Sendable {
    public enum Filter: String, CaseIterable, Sendable {
        case peak, lowShelf, highShelf
    }

    public struct Band: Equatable, Sendable {
        public let filter: Filter
        public let frequency: Double
        public let gain: Double
        public let qFactor: Double

        public init(_ filter: Filter, frequency: Double, gain: Double, qFactor: Double = Equalizer.defaultQFactor) {
            self.filter = filter
            self.frequency = frequency
            self.gain = gain
            self.qFactor = qFactor
        }
    }

    public static let maxBands = 16
    public static let defaultQFactor = 0.707
    static let frequencies = 20.0...20000.0
    static let gains = -30.0...30.0
    static let qFactors = 0.1...20.0

    public let preamp: Double
    public let bands: [Band]

    public init(preamp: Double, bands: [Band]) {
        self.preamp = preamp
        self.bands = bands
    }

    public var json: JSON {
        .object([
            "preamp": .number(preamp),
            "bands": .array(bands.map { .object([
                "type": .string($0.filter.rawValue),
                "frequency": .number($0.frequency),
                "gain": .number($0.gain),
                "q": .number($0.qFactor),
            ]) }),
        ])
    }

    public var preampScale: Double {
        pow(10, preamp / 20)
    }

    public func biquads(sampleRate: Double) -> [Biquad] {
        bands.map { Biquad($0, sampleRate: sampleRate) }
    }

    static func parse(_ call: HostCall) throws -> Equalizer? {
        guard let value = call.arguments.first, value != .null else { return nil }
        guard let fields = value.object else { throw call.fail("equalizer must be an object or null") }
        try rejectUnknown(fields, ["preamp", "bands"], call, "equalizer")
        let preamp = try number(fields["preamp"], "preamp", gains, call, "dB") ?? 0
        guard let items = fields["bands"]?.array else { throw call.fail("bands must be an array") }
        guard items.count <= maxBands else { throw call.fail("bands must have at most \(maxBands) entries") }
        return try Equalizer(preamp: preamp, bands: items.enumerated().map { index, item in
            let label = "bands[\(index)]"
            guard let band = item.object else { throw call.fail("\(label) must be an object") }
            try rejectUnknown(band, ["type", "frequency", "gain", "q"], call, label)
            guard let raw = band["type"]?.string, let filter = Filter(rawValue: raw) else {
                throw call.fail("\(label).type must be " + Filter.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or "))
            }
            guard let frequency = try number(band["frequency"], "\(label).frequency", frequencies, call, "Hz") else {
                throw call.fail("\(label).frequency must be a number")
            }
            return try Band(
                filter,
                frequency: frequency,
                gain: number(band["gain"], "\(label).gain", gains, call, "dB") ?? 0,
                qFactor: number(band["q"], "\(label).q", qFactors, call, nil) ?? defaultQFactor,
            )
        })
    }

    private static func rejectUnknown(_ fields: [String: JSON], _ keys: [String], _ call: HostCall, _ label: String) throws {
        if let unknown = fields.keys.sorted().first(where: { !keys.contains($0) }) {
            throw call.fail("unknown field \"\(unknown)\" in \(label); use " + keys.joined(separator: ", "))
        }
    }

    private static func number(_ value: JSON?, _ label: String, _ range: ClosedRange<Double>, _ call: HostCall, _ unit: String?) throws -> Double? {
        guard let value, value != .null else { return nil }
        guard let number = value.number, number.isFinite, range.contains(number) else {
            let bounds = String(format: "%g to %g", range.lowerBound, range.upperBound) + (unit.map { " \($0)" } ?? "")
            throw call.fail("\(label) must be a number from \(bounds)")
        }
        return number
    }
}

public struct Biquad: Equatable, Sendable {
    public let forward0: Double
    public let forward1: Double
    public let forward2: Double
    public let back1: Double
    public let back2: Double

    public static let identity = Biquad(forward: [1, 0, 0], back: [1, 0, 0])

    init(forward: [Double], back: [Double]) {
        forward0 = forward[0] / back[0]
        forward1 = forward[1] / back[0]
        forward2 = forward[2] / back[0]
        back1 = back[1] / back[0]
        back2 = back[2] / back[0]
    }

    init(_ band: Equalizer.Band, sampleRate: Double) {
        guard sampleRate > 0, band.frequency < sampleRate / 2 else {
            self = .identity
            return
        }
        let amplitude = pow(10, band.gain / 40)
        let omega = 2 * Double.pi * band.frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * band.qFactor)
        let shelf = 2 * amplitude.squareRoot() * alpha
        let plus = amplitude + 1
        let minus = amplitude - 1
        switch band.filter {
        case .peak:
            self.init(
                forward: [1 + alpha * amplitude, -2 * cosine, 1 - alpha * amplitude],
                back: [1 + alpha / amplitude, -2 * cosine, 1 - alpha / amplitude],
            )
        case .lowShelf:
            self.init(
                forward: [
                    amplitude * (plus - minus * cosine + shelf),
                    2 * amplitude * (minus - plus * cosine),
                    amplitude * (plus - minus * cosine - shelf),
                ],
                back: [plus + minus * cosine + shelf, -2 * (minus + plus * cosine), plus + minus * cosine - shelf],
            )
        case .highShelf:
            self.init(
                forward: [
                    amplitude * (plus + minus * cosine + shelf),
                    -2 * amplitude * (minus + plus * cosine),
                    amplitude * (plus + minus * cosine - shelf),
                ],
                back: [plus - minus * cosine + shelf, 2 * (minus - plus * cosine), plus - minus * cosine - shelf],
            )
        }
    }

    public func decibels(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(omega)
        let sin1 = sin(omega)
        let cos2 = cos(2 * omega)
        let sin2 = sin(2 * omega)
        let numerator = hypot(forward0 + forward1 * cos1 + forward2 * cos2, forward1 * sin1 + forward2 * sin2)
        let denominator = hypot(1 + back1 * cos1 + back2 * cos2, back1 * sin1 + back2 * sin2)
        return 20 * log10(numerator / denominator)
    }
}
