import AppKit
import AudioToolbox
import CoreAudio
import GaryCore

extension Capability {
    static let audio = Capability(
        name: "audio",
        summary: "Audio devices, volume, mute, and the apps that use the microphone. Set the volume, mute, and the default device.",
        types: """
        declare namespace Gary {
          type AudioScope = "output" | "input";
          interface State { audio?: Audio }
          interface Audio {
            devices: AudioDeviceSummary[];
            output: AudioDeviceState | null;
            input: AudioDeviceState | null;
            microphone: { pid: number; app: string | null; bundleId: string | null }[];
          }
          interface AudioDeviceSummary { id: string; name: string; transport: string; output: boolean; input: boolean }
          interface AudioDeviceState { id: string; name: string; transport: string; volume: number | null; muted: boolean | null }
          interface Host { audio: AudioApi }
          interface AudioApi {
            setVolume(volume: number, scope?: AudioScope): null;
            setMuted(muted: boolean, scope?: AudioScope): null;
            setDefaultDevice(id: string, scope?: AudioScope): null;
          }
        }
        """,
        example: """
        export default {
          render(state) {
            const output = state.audio?.output;
            if (output?.volume == null) return { type: "text", text: "No output" };
            return { type: "slider", value: output.muted ? 0 : output.volume, action: "volume" };
          },
          onAction(action, payload) {
            if (action === "volume" && typeof payload === "number") host.audio.setVolume(payload);
          },
        } satisfies Gary.Panel;
        """,
        install: { host, plugin in
            plugin.installAPI(host, "audio", AudioRequest.methods) { call in
                switch try AudioRequest.parse(call) {
                case let .setVolume(volume, scope):
                    try apply(scope, "volume") { setProperty(
                        $0,
                        address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope.scope),
                        Float32(volume),
                    ) }
                case let .setMuted(muted, scope):
                    try apply(scope, "mute") { setProperty($0, address(kAudioDevicePropertyMute, scope.scope), UInt32(muted ? 1 : 0)) }
                case let .setDefaultDevice(id, scope):
                    guard let device = AudioDevice.all().first(where: { $0.uid == id && $0.has(scope) })
                    else { throw HostFailure("no \(scope.rawValue) device \(id)") }
                    let status = setProperty(AudioObjectID(kAudioObjectSystemObject), address(scope.defaultSelector), device.id) ??
                        kAudioHardwareUnsupportedOperationError
                    guard status == noErr else { throw HostFailure("cannot make \(device.name) the default \(scope.rawValue) device (\(status))") }
                }
                return .now(.null)
            }
        },
        topic: { AudioTopic($0) },
    )
}

extension AudioScope {
    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }

    var defaultSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

private func apply(_ scope: AudioScope, _ what: String, _ write: (AudioObjectID) -> OSStatus?) throws {
    guard let device = defaultDevice(scope) else { throw HostFailure("there is no default \(scope.rawValue) device") }
    guard let status = write(device) else { throw HostFailure("\(AudioDevice(device)?.name ?? "the device") has no \(what) control") }
    guard status == noErr else { throw HostFailure("cannot set \(what) (\(status))") }
}

private func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func property<T: BitwiseCopyable>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var address = address
    var value = initial
    var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectHasProperty(object, &address),
          AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
}

private func setProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: some BitwiseCopyable) -> OSStatus? {
    var address = address
    var value = value
    var settable: DarwinBoolean = false
    guard AudioObjectHasProperty(object, &address), AudioObjectIsPropertySettable(object, &address, &settable) == noErr,
          settable.boolValue else { return nil }
    return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value)
}

private func stringProperty(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
    property(object, address, nil as Unmanaged<CFString>?)??.takeRetainedValue() as String?
}

private func objects(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var address = address
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
    var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
    return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

private func defaultDevice(_ scope: AudioScope) -> AudioObjectID? {
    property(AudioObjectID(kAudioObjectSystemObject), address(scope.defaultSelector), AudioObjectID(0)).flatMap { $0 == 0 ? nil : $0 }
}

private let transports: [UInt32: String] = [
    kAudioDeviceTransportTypeBuiltIn: "builtin", kAudioDeviceTransportTypeUSB: "usb", kAudioDeviceTransportTypeBluetooth: "bluetooth",
    kAudioDeviceTransportTypeBluetoothLE: "bluetooth", kAudioDeviceTransportTypeHDMI: "hdmi", kAudioDeviceTransportTypeDisplayPort: "displayport",
    kAudioDeviceTransportTypeAirPlay: "airplay", kAudioDeviceTransportTypeVirtual: "virtual", kAudioDeviceTransportTypeAggregate: "aggregate",
    kAudioDeviceTransportTypeThunderbolt: "thunderbolt", kAudioDeviceTransportTypeContinuityCaptureWired: "continuity",
    kAudioDeviceTransportTypeContinuityCaptureWireless: "continuity",
]

private struct AudioDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let transport: String
    let scopes: Set<AudioScope>

    init?(_ id: AudioObjectID) {
        guard let uid = stringProperty(id, address(kAudioDevicePropertyDeviceUID)),
              property(id, address(kAudioDevicePropertyIsHidden), UInt32(0)) != 1 else { return nil }
        self.id = id
        self.uid = uid
        name = stringProperty(id, address(kAudioObjectPropertyName)) ?? uid
        transport = property(id, address(kAudioDevicePropertyTransportType), UInt32(0)).flatMap { transports[$0] } ?? "other"
        scopes = Set(AudioScope.allCases.filter { !objects(id, address(kAudioDevicePropertyStreams, $0.scope)).isEmpty })
    }

    static func all() -> [AudioDevice] {
        objects(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices)).compactMap(AudioDevice.init)
            .sorted { $0.name < $1.name }
    }

    func has(_ scope: AudioScope) -> Bool {
        scopes.contains(scope)
    }

    var summary: JSON {
        .object([
            "id": .string(uid),
            "name": .string(name),
            "transport": .string(transport),
            "output": .bool(has(.output)),
            "input": .bool(has(.input)),
        ])
    }

    func state(_ scope: AudioScope) -> JSON {
        let volume = property(id, address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope.scope), Float32(0))
        let muted = property(id, address(kAudioDevicePropertyMute, scope.scope), UInt32(0))
        return .object([
            "id": .string(uid), "name": .string(name), "transport": .string(transport),
            "volume": volume.map { .number((Double($0) * 1000).rounded() / 1000) } ?? .null,
            "muted": muted.map { .bool($0 != 0) } ?? .null,
        ])
    }
}

private struct Listener: Hashable {
    let object: AudioObjectID
    let selector: AudioObjectPropertySelector
    let scope: AudioObjectPropertyScope
}

private final class AudioTopic: TopicFeed {
    private let publish: (JSON, Trace) -> Void
    private let queue = DispatchQueue(label: "gary.audio")
    private var listeners: [Listener: AudioObjectPropertyListenerBlock] = [:]
    private var scheduled = false
    private var poll: DispatchWorkItem?

    init(_ publish: @escaping (JSON, Trace) -> Void) {
        self.publish = publish
        queue.async { [weak self] in self?.refresh(Trace("audio-start")) }
    }

    deinit {
        poll?.cancel()
        listen(to: [])
    }

    private func changed() {
        guard !scheduled else { return }
        scheduled = true
        let trace = Trace("audio")
        queue.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.scheduled = false
            self?.refresh(trace)
        }
    }

    private func refresh(_ trace: Trace) {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var wanted: Set<Listener> = [
            Listener(object: system, selector: kAudioHardwarePropertyDevices, scope: kAudioObjectPropertyScopeGlobal),
            Listener(object: system, selector: kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeGlobal),
            Listener(object: system, selector: kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeGlobal),
            Listener(object: system, selector: kAudioHardwarePropertyProcessObjectList, scope: kAudioObjectPropertyScopeGlobal),
        ]
        let devices = AudioDevice.all()
        for device in devices where device.has(.input) {
            wanted.insert(Listener(object: device.id, selector: kAudioDevicePropertyDeviceIsRunningSomewhere, scope: kAudioObjectPropertyScopeGlobal))
        }
        var state: [String: JSON] = ["devices": .array(devices.map(\.summary))]
        for scope in AudioScope.allCases {
            let device = defaultDevice(scope).flatMap(AudioDevice.init)
            state[scope.rawValue] = device?.state(scope) ?? .null
            guard let device else { continue }
            wanted.insert(Listener(object: device.id, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope.scope))
            wanted.insert(Listener(object: device.id, selector: kAudioDevicePropertyMute, scope: scope.scope))
        }
        var microphone: [JSON] = []
        for process in objects(system, address(kAudioHardwarePropertyProcessObjectList)) {
            guard property(process, address(kAudioProcessPropertyIsRunningInput), UInt32(0)) == 1,
                  let pid = property(process, address(kAudioProcessPropertyPID), pid_t(0)) else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let bundleID = stringProperty(process, address(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 } ?? app?.bundleIdentifier
            microphone.append(.object([
                "pid": .number(Double(pid)),
                "app": app?.localizedName.map(JSON.string) ?? .null,
                "bundleId": bundleID.map(JSON.string) ?? .null,
            ]))
        }
        state["microphone"] = .array(microphone)
        listen(to: wanted)
        publish(.object(state), trace)
        poll?.cancel()
        poll = microphone.isEmpty ? nil : DispatchWorkItem { [weak self] in self?.changed() }
        if let poll {
            queue.asyncAfter(deadline: .now() + 2, execute: poll)
        }
    }

    private func listen(to wanted: Set<Listener>) {
        for (listener, block) in listeners where !wanted.contains(listener) {
            var address = address(listener.selector, listener.scope)
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, queue, block)
            listeners[listener] = nil
        }
        for listener in wanted where listeners[listener] == nil {
            var address = address(listener.selector, listener.scope)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
            if AudioObjectAddPropertyListenerBlock(listener.object, &address, queue, block) == noErr {
                listeners[listener] = block
            }
        }
    }
}
