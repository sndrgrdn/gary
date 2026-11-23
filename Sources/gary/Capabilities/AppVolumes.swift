import CoreAudio
import GaryCore
import Synchronization

nonisolated let appVolumes = AppVolumes()
nonisolated let tapDevicePrefix = "com.sndrgrdn.gary.app-volume."

private nonisolated struct TapRoute: Equatable {
    let process: AudioObjectID
    let output: AudioObjectID
    let rate: Float64
}

final nonisolated class AppVolumes: @unchecked Sendable {
    let queue: DispatchQueue
    private var volumes: [pid_t: Double] = [:]
    private var taps: [pid_t: ProcessTap] = [:]
    private var observer: (@Sendable ([pid_t: Double]) -> Void)?
    private let listeners: AudioListeners

    init() {
        queue = DispatchQueue(label: "gary.audio.apps", qos: .userInitiated)
        listeners = AudioListeners(queue)
        listeners.changed = { [weak self] in self?.reconcile() }
    }

    func observe(_ observer: @escaping @Sendable ([pid_t: Double]) -> Void) {
        queue.async {
            self.observer = observer
            observer(self.volumes)
        }
    }

    func set(_ pid: pid_t, _ volume: Double) throws {
        guard pid != getpid(), processObject(pid) != nil else { throw HostFailure("process \(pid) has no audio") }
        if volume < 1 {
            let grant = Permission.audioCapture.grant
            guard grant == .granted || grant == .notAsked else { throw HostFailure(missingGrant(.audioCapture, "audio.setAppVolume")) }
        }
        volumes[pid] = volume < 1 ? volume : nil
        if let failure = reconcile()[pid] {
            throw failure
        }
    }

    @discardableResult
    private func reconcile() -> [pid_t: Error] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let output = defaultDevice(.output)
        let rate = output.flatMap { property($0, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) } ?? 0
        var routes: [pid_t: TapRoute] = [:]
        for pid in volumes.keys {
            guard let process = processObject(pid) else {
                volumes[pid] = nil
                continue
            }
            routes[pid] = output.map { TapRoute(process: process, output: $0, rate: rate) }
        }
        for (pid, tap) in taps where routes[pid] != tap.route {
            taps[pid] = nil
            log("audio: removed the volume tap of pid \(pid)")
        }
        var failures: [pid_t: Error] = [:]
        for (pid, route) in routes {
            let volume = volumes[pid] ?? 1
            do {
                let tap = try taps[pid] ?? ProcessTap(route, volume: volume)
                if taps[pid] == nil {
                    log("audio: tapped pid \(pid) at volume \(volume) into \(AudioDevice(route.output)?.name ?? "the output") at \(route.rate) Hz")
                }
                taps[pid] = tap
                tap.gain.set(volume)
                try tap.run(property(route.process, address(kAudioProcessPropertyIsRunningOutput), UInt32(0)) == 1)
            } catch {
                log("audio: cannot set the volume of pid \(pid): \(error)")
                failures[pid] = error
                volumes[pid] = nil
                taps[pid] = nil
            }
        }
        var wanted: Set<Listener> = volumes.isEmpty ? [] : [
            Listener(object: system, selector: kAudioHardwarePropertyDevices),
            Listener(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice),
            Listener(object: system, selector: kAudioHardwarePropertyProcessObjectList),
        ]
        if let output, !volumes.isEmpty {
            wanted.insert(Listener(object: output, selector: kAudioDevicePropertyNominalSampleRate))
        }
        for route in routes.values {
            wanted.insert(Listener(object: route.process, selector: kAudioProcessPropertyIsRunningOutput))
        }
        listeners.listen(to: wanted)
        observer?(volumes)
        return failures
    }
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
    let gain: Gain
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private var running = false

    init(_ route: TapRoute, volume: Double) throws {
        self.route = route
        gain = Gain(volume)
        guard let output = stringProperty(route.output, address(kAudioDevicePropertyDeviceUID)) else {
            throw HostFailure("the output device has no UID")
        }
        let description = CATapDescription(stereoMixdownOfProcesses: [route.process])
        description.uuid = UUID()
        description.muteBehavior = .muted
        description.isPrivate = true
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the process tap")
        let aggregate: NSDictionary = [
            kAudioAggregateDeviceNameKey: "Gary app volume",
            kAudioAggregateDeviceUIDKey: tapDevicePrefix + description.uuid.uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate, &device), "create the aggregate device")
        let gain = gain
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, output, _ in
            render(input, output, gain.value)
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

private nonisolated func render(_ input: UnsafePointer<AudioBufferList>, _ output: UnsafeMutablePointer<AudioBufferList>, _ gain: Float32) {
    guard let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).last,
          let samples = source.mData?.assumingMemoryBound(to: Float32.self) else { return }
    let width = Int(max(source.mNumberChannels, 1))
    let frames = Int(source.mDataByteSize) / (MemoryLayout<Float32>.size * width)
    var first = 0
    for target in UnsafeMutableAudioBufferListPointer(output) where first < width {
        let channels = Int(target.mNumberChannels)
        if let into = target.mData?.assumingMemoryBound(to: Float32.self), channels > 0 {
            let count = min(frames, Int(target.mDataByteSize) / (MemoryLayout<Float32>.size * channels))
            for channel in 0..<min(channels, width - first) {
                for frame in 0..<count {
                    into[frame * channels + channel] = samples[frame * width + first + channel] * gain
                }
            }
        }
        first += channels
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
