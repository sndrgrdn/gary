import Foundation
import GaryCore
import Synchronization

private nonisolated struct EqualizerStage {
    var bandCount = 0
    var preamp = 1.0
    var release: Float32 = 1
    var biquads = InlineArray<16, Biquad>(repeating: .identity)
    var generation = 0
}

final nonisolated class EqualizerFilter: @unchecked Sendable {
    private static let channels = 8
    private static let ceiling: Float32 = 0.891
    private static let releaseSeconds = 0.2
    private let pending = Mutex(EqualizerStage())
    private var applied: (equalizer: Equalizer?, sampleRate: Double)?
    private var stage = EqualizerStage()
    private let history: UnsafeMutablePointer<Double>
    private var envelope: Float32 = 1

    init() {
        let size = Equalizer.maxBands * Self.channels * 2
        history = .allocate(capacity: size)
        history.initialize(repeating: 0, count: size)
    }

    deinit {
        history.deallocate()
    }

    func update(_ equalizer: Equalizer?, sampleRate: Double) {
        if let applied, applied.equalizer == equalizer, applied.sampleRate == sampleRate {
            return
        }
        applied = (equalizer, sampleRate)
        let biquads = equalizer?.biquads(sampleRate: sampleRate) ?? []
        pending.withLock { next in
            next.bandCount = biquads.count
            next.preamp = equalizer?.preampScale ?? 1
            next.release = Float32(1 - exp(-1 / (Self.releaseSeconds * max(sampleRate, 1))))
            for (index, biquad) in biquads.enumerated() {
                next.biquads[index] = biquad
            }
            next.generation &+= 1
        }
    }

    func prepare() {
        guard let next = pending.withLockIfAvailable({ $0 }), next.generation != stage.generation else { return }
        if next.bandCount != stage.bandCount {
            history.update(repeating: 0, count: Equalizer.maxBands * Self.channels * 2)
        }
        stage = next
    }

    var active: Bool {
        stage.bandCount > 0 || stage.preamp != 1
    }

    func limit(_ peak: Float32) -> Float32 {
        let target = peak > Self.ceiling ? Self.ceiling / peak : 1
        envelope = target < envelope ? target : envelope + (target - envelope) * stage.release
        return envelope
    }

    func filter(_ sample: Float32, channel: Int) -> Float32 {
        guard channel < Self.channels else { return sample }
        var value = Double(sample) * stage.preamp
        for band in 0..<stage.bandCount {
            let biquad = stage.biquads[band]
            let state = history + (channel * Equalizer.maxBands + band) * 2
            let result = biquad.forward0 * value + state[0]
            state[0] = biquad.forward1 * value - biquad.back1 * result + state[1]
            state[1] = biquad.forward2 * value - biquad.back2 * result
            value = result
        }
        return Float32(value)
    }
}
