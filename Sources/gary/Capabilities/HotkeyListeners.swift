import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

nonisolated extension Capability {
    static let hotkeys = Capability(
        name: "hotkeys",
        summary: """
        Register global hotkeys while the plugin runs, such as ones read from its settings, next to the fixed `hotkeys` of the manifest. \
        `host.hotkeys(keys, onPress)` registers each combination, written as in the manifest such as `hyper+shift+m`, and calls \
        `onPress` with the combination as given each time one is pressed, until `stop()` or the plugin stops. It throws for a \
        combination that is not valid. Gary logs a combination that another plugin or app already holds and leaves it unregistered.
        """,
        types: """
        declare namespace Gary {
          interface Host { hotkeys(keys: string[], onPress: (keys: string) => void): HotkeysApi }
          interface HotkeysApi { stop(): void }
        }
        """,
        example: """
        host.hotkeys(["hyper+shift+m", "hyper+return"], (keys) => {
          host.log(`${keys} pressed`);
        });

        export default {} satisfies Gary.Service;
        """,
        install: { host, plugin in
            let owner = plugin.id
            plugin.installHandle(host, "hotkeys") { [weak plugin] call, arguments in
                let onPress = try call.function(1, "onPress", in: arguments)
                var keys: [KeyCombo: String] = [:]
                for name in try call.strings(0, "keys") {
                    guard let combo = KeyCombo.parse(name) else {
                        throw call.fail("\"\(name)\" is not a hotkey; write modifiers and a key, such as hyper+shift+m or ctrl+alt+space")
                    }
                    if let other = keys[combo] {
                        throw call.fail("\"\(other)\" and \"\(name)\" are the same hotkey")
                    }
                    keys[combo] = name
                }
                let id = HotkeyListeners.shared.add(owner: owner, keys: keys) { [weak plugin] name in
                    plugin?.onQueue { $0.callBack(onPress, [name], Trace("hotkey"), cause: .action) }
                }
                return HostHandle { HotkeyListeners.shared.remove(id) }
            }
        },
    )
}

final nonisolated class HotkeyListeners: @unchecked Sendable {
    private struct Listener {
        let owner: PluginID
        let keys: [KeyCombo: String]
        let press: @Sendable (String) -> Void
    }

    static let shared = HotkeyListeners()
    private let lock = NSLock()
    private var listeners: [Int: Listener] = [:]
    private var nextID = 1
    var changed: (() -> Void)?

    func add(owner: PluginID, keys: [KeyCombo: String], press: @escaping @Sendable (String) -> Void) -> Int {
        let id = lock.withLock {
            let id = nextID
            nextID += 1
            listeners[id] = Listener(owner: owner, keys: keys, press: press)
            return id
        }
        DispatchQueue.main.async { self.changed?() }
        return id
    }

    func remove(_ id: Int) {
        guard lock.withLock({ listeners.removeValue(forKey: id) }) != nil else { return }
        DispatchQueue.main.async { self.changed?() }
    }

    var bindings: [HotkeyBinding] {
        lock.withLock {
            listeners.sorted { $0.key < $1.key }.flatMap { _, listener in
                listener.keys.sorted { $0.value < $1.value }.map { HotkeyBinding(owner: listener.owner, hotkey: Hotkey(id: $0.value, keys: $0.key)) }
            }
        }
    }

    func press(_ binding: HotkeyBinding) -> Bool {
        let found = lock.withLock {
            listeners.filter { $0.value.owner == binding.owner }.sorted { $0.key > $1.key }.lazy
                .compactMap { _, listener in listener.keys[binding.hotkey.keys].map { (listener.press, $0) } }.first
        }
        guard let (press, name) = found else { return false }
        press(name)
        return true
    }
}
