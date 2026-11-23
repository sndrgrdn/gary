import Carbon
import GaryCore

nonisolated struct HotkeyBinding: Hashable {
    let owner: PluginID
    let hotkey: Hotkey
}

final class HotkeyCenter {
    private var registered: [HotkeyBinding: (number: UInt32, ref: EventHotKeyRef)] = [:]
    private var owners: [UInt32: HotkeyBinding] = [:]
    private var nextNumber: UInt32 = 1
    private var handler: EventHandlerRef?
    private let onPress: (HotkeyBinding) -> Void

    init(onPress: @escaping (HotkeyBinding) -> Void) {
        self.onPress = onPress
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, info in
            guard let info else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &id,
            )
            let center = Unmanaged<HotkeyCenter>.fromOpaque(info).takeUnretainedValue()
            if let binding = center.owners[id.id] {
                center.onPress(binding)
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func registered(by owner: PluginID, as combo: KeyCombo) -> HotkeyBinding? {
        registered.keys.first { $0.owner == owner && $0.hotkey.keys == combo }
    }

    func update(_ wanted: [HotkeyBinding]) {
        let keep = Set(wanted)
        for (binding, entry) in registered where !keep.contains(binding) {
            UnregisterEventHotKey(entry.ref)
            owners[entry.number] = nil
            registered[binding] = nil
        }
        var taken = Dictionary(uniqueKeysWithValues: registered.keys.map { ($0.hotkey.keys, $0) })
        for binding in wanted where registered[binding] == nil {
            if let holder = taken[binding.hotkey.keys] {
                log("hotkey \(binding.hotkey.keys) of \(binding.owner) is already taken by \(holder.owner)")
                continue
            }
            var ref: EventHotKeyRef?
            let number = nextNumber
            nextNumber += 1
            let status = RegisterEventHotKey(
                binding.hotkey.keys.keyCode,
                UInt32(binding.hotkey.keys.modifiers.held.reduce(0) { $0 | $1.carbonFlag }),
                EventHotKeyID(signature: OSType(0x4761_7279), id: number),
                GetEventDispatcherTarget(),
                0,
                &ref,
            )
            guard status == noErr, let ref else {
                let reason = status == eventHotKeyExistsErr ? "is already taken by another app" : "could not be registered (\(status))"
                log("hotkey \(binding.hotkey.keys) of \(binding.owner) \(reason)")
                continue
            }
            registered[binding] = (number, ref)
            owners[number] = binding
            taken[binding.hotkey.keys] = binding
            log("hotkey \(binding.hotkey.keys) registered for \(binding.owner)/\(binding.hotkey.id)")
        }
    }
}
