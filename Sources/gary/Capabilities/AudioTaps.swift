import CoreAudio
import GaryCore
import Synchronization

nonisolated let audioTaps = AudioTaps()
nonisolated let tapDevicePrefix = "com.sndrgrdn.gary.tap."

nonisolated struct AudioTapsState {
    let volumes: [pid_t: Double]
    let equalizer: Equalizer?
}

private nonisolated enum TapKey: Hashable {
    case app(pid_t)
    case system
}

private nonisolated struct TapRoute: Equatable {
    enum Source: Equatable {
        case process(AudioObjectID)
        case allExcept([AudioObjectID])
    }

    let source: Source
    let output: AudioObjectID
    let rate: Float64
}

final nonisolated class AudioTaps: @unchecked Sendable {
    private let queue: DispatchQueue
    private var volumes: [pid_t: Double] = [:]
    private var equalizer: Equalizer?
    private var taps: [TapKey: ProcessTap] = [:]
    private var observer: (@Sendable (AudioTapsState) -> Void)?
    private let listeners: AudioListeners

    init() {
        queue = DispatchQueue(label: "gary.audio.taps", qos: .userInitiated)
        listeners = AudioListeners(queue)
        listeners.changed = { [weak self] in self?.reconcile() }
    }

    private var state: AudioTapsState {
        AudioTapsState(volumes: volumes, equalizer: equalizer)
    }

    func observe(_ observer: @escaping @Sendable (AudioTapsState) -> Void) {
        queue.async {
            self.observer = observer
            observer(self.state)
        }
    }

    func later(_ change: @escaping @Sendable (AudioTaps) throws -> Void) -> HostResult {
        .later(queue) {
            try change(self)
            return .null
        }
    }

    func setVolume(_ pid: pid_t, _ volume: Double) throws {
        guard pid != getpid(), processObject(pid) != nil else { throw HostFailure("process \(pid) has no audio") }
        if volume < 1 {
            try requireAudioCapture("audio.setAppVolume")
        }
        volumes[pid] = volume < 1 ? volume : nil
        if let failure = reconcile()[.app(pid)] {
            throw failure
        }
    }

    func setEqualizer(_ equalizer: Equalizer?) throws {
        if equalizer != nil {
            try requireAudioCapture("audio.setEqualizer")
        }
        self.equalizer = equalizer
        if let failure = reconcile()[.system] {
            throw failure
        }
    }

    private func requireAudioCapture(_ call: String) throws {
        let grant = Permission.audioCapture.grant
        guard grant == .granted || grant == .notAsked else { throw HostFailure(missingGrant(.audioCapture, call)) }
    }

    @discardableResult
    private func reconcile() -> [TapKey: Error] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let output = defaultDevice(.output)
        let rate = output.flatMap { property($0, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) } ?? 0
        let processes = audioObjects(system, address(kAudioHardwarePropertyProcessObjectList))
        var failures: [TapKey: Error] = [:]
        var routes: [TapKey: TapRoute] = [:]
        var tapped: [AudioObjectID] = []
        for pid in volumes.keys {
            guard let process = processObject(pid) else {
                volumes[pid] = nil
                continue
            }
            tapped.append(process)
            routes[.app(pid)] = output.map { TapRoute(source: .process(process), output: $0, rate: rate) }
        }
        var excluded: [AudioObjectID] = []
        if equalizer != nil {
            if let own = processObject(getpid()) {
                excluded = (tapped + [own]).sorted()
                routes[.system] = output.map { TapRoute(source: .allExcept(excluded), output: $0, rate: rate) }
            } else {
                failures[.system] = HostFailure("Gary has no audio process to leave out of the equalizer")
                log("audio: cannot start the equalizer: Gary has no audio process")
                equalizer = nil
            }
        }
        for (key, tap) in taps where routes[key] != tap.route {
            taps[key] = nil
            log("audio: removed the \(key.label) tap")
        }
        for (key, route) in routes {
            do {
                try start(key, route, processes: processes)
            } catch {
                log("audio: cannot run the \(key.label) tap: \(error)")
                failures[key] = error
                taps[key] = nil
                if let pid = key.pid {
                    volumes[pid] = nil
                } else {
                    equalizer = nil
                }
            }
        }
        listeners.listen(to: listeners(output, routes: routes, processes: equalizer == nil ? [] : processes.filter { !excluded.contains($0) }))
        observer?(state)
        return failures
    }

    private func start(_ key: TapKey, _ route: TapRoute, processes: [AudioObjectID]) throws {
        let tap = try taps[key] ?? ProcessTap(route, name: key == .system ? "Gary equalizer" : "Gary app volume")
        if taps[key] == nil {
            log("audio: started the \(key.label) tap into \(AudioDevice(route.output)?.name ?? "the output") at \(route.rate) Hz")
        }
        taps[key] = tap
        tap.gain.set(key.pid.flatMap { volumes[$0] } ?? 1)
        tap.equalizer.update(equalizer, sampleRate: route.rate)
        let playing = switch route.source {
        case let .process(process): isRunningOutput(process)
        case let .allExcept(excluded): processes.contains { !excluded.contains($0) && isRunningOutput($0) }
        }
        try tap.run(playing)
    }

    private func listeners(_ output: AudioObjectID?, routes: [TapKey: TapRoute], processes: [AudioObjectID]) -> Set<Listener> {
        guard !volumes.isEmpty || equalizer != nil else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var wanted: Set<Listener> = [
            Listener(object: system, selector: kAudioHardwarePropertyDevices),
            Listener(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice),
            Listener(object: system, selector: kAudioHardwarePropertyProcessObjectList),
        ]
        if let output {
            wanted.insert(Listener(object: output, selector: kAudioDevicePropertyNominalSampleRate))
        }
        for route in routes.values {
            if case let .process(process) = route.source {
                wanted.insert(Listener(object: process, selector: kAudioProcessPropertyIsRunningOutput))
            }
        }
        for process in processes {
            wanted.insert(Listener(object: process, selector: kAudioProcessPropertyIsRunningOutput))
        }
        return wanted
    }
}

private nonisolated extension TapKey {
    var pid: pid_t? {
        if case let .app(pid) = self {
            pid
        } else {
            nil
        }
    }

    var label: String {
        switch self {
        case let .app(pid): "volume of pid \(pid)"
        case .system: "equalizer"
        }
    }
}

private nonisolated func isRunningOutput(_ process: AudioObjectID) -> Bool {
    property(process, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) == 1
}

private final nonisolated class Gain: Sendable {
    private let bits: Atomic<UInt32>

    init(_ volume: Double) {
        bits = Atomic(Float32(volume).bitPattern)
    }

    var value: Float32 {
        Float32(bitPattern: bits.load(ordering: .relaxed))
    }

    func set(_ volume: Double) {
        bits.store(Float32(volume).bitPattern, ordering: .relaxed)
    }
}

private final nonisolated class ProcessTap {
    let route: TapRoute
    let gain = Gain(1)
    let equalizer = EqualizerFilter()
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var running = false

    init(_ route: TapRoute, name: String) throws {
        self.route = route
        guard let output = stringProperty(route.output, address(kAudioDevicePropertyDeviceUID)) else {
            throw HostFailure("the output device has no UID")
        }
        let description = switch route.source {
        case let .process(process): CATapDescription(stereoMixdownOfProcesses: [process])
        case let .allExcept(excluded): CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        }
        description.uuid = UUID()
        description.muteBehavior = .muted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the process tap")
        let aggregate: NSDictionary = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: tapDevicePrefix + description.uuid.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate, &device), "create the aggregate device")
        let gain = gain
        let equalizer = equalizer
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, output, _ in
            render(input, output, gain.value, equalizer)
        }, "add the IO proc")
    }

    deinit {
        if let proc {
            if running {
                AudioDeviceStop(device, proc)
            }
            AudioDeviceDestroyIOProcID(device, proc)
        }
        if device != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    func run(_ playing: Bool) throws {
        guard playing != running, let proc else { return }
        try check(playing ? AudioDeviceStart(device, proc) : AudioDeviceStop(device, proc), playing ? "start the tap" : "stop the tap")
        running = playing
    }
}

private nonisolated func check(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw HostFailure("cannot \(what) (\(status))") }
}

private nonisolated func render(
    _ input: UnsafePointer<AudioBufferList>,
    _ output: UnsafeMutablePointer<AudioBufferList>,
    _ gain: Float32,
    _ equalizer: EqualizerFilter,
) {
    guard let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).last,
          let samples = source.mData?.assumingMemoryBound(to: Float32.self) else { return }
    equalizer.prepare()
    let width = Int(max(source.mNumberChannels, 1))
    let frames = Int(source.mDataByteSize) / (MemoryLayout<Float32>.size * width)
    let targets = UnsafeMutableAudioBufferListPointer(output)
    let active = equalizer.active
    withUnsafeTemporaryAllocation(of: Float32.self, capacity: width) { frame in
        for index in 0..<frames {
            var peak: Float32 = 0
            for channel in 0..<width {
                let sample = samples[index * width + channel]
                frame[channel] = active ? equalizer.filter(sample, channel: channel) : sample
                peak = max(peak, abs(frame[channel]))
            }
            let level = (active ? equalizer.limit(peak) : 1) * gain
            var first = 0
            for target in targets where first < width {
                let channels = Int(target.mNumberChannels)
                if let into = target.mData?.assumingMemoryBound(to: Float32.self), channels > 0,
                   index < Int(target.mDataByteSize) / (MemoryLayout<Float32>.size * channels)
                {
                    for channel in 0..<min(channels, width - first) {
                        into[index * channels + channel] = frame[first + channel] * level
                    }
                }
                first += channels
            }
        }
    }
}

private nonisolated func processObject(_ pid: pid_t) -> AudioObjectID? {
    var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
    var pid = pid
    var object = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object,
    ) == noErr, object != kAudioObjectUnknown else { return nil }
    return object
}
