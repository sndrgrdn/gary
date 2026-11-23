@testable import gary
import GaryCore
import Testing

private func bindings(of id: String) -> [String] {
    HotkeyListeners.shared.bindings.filter { $0.owner.rawValue == id }.map { "\($0.hotkey.id)=\($0.hotkey.keys)" }
}

private func press(_ keys: String, of id: String) throws -> Bool {
    let combo = try #require(KeyCombo.parse(keys))
    let owner = try #require(PluginID(id))
    return HotkeyListeners.shared.press(HotkeyBinding(owner: owner, hotkey: Hotkey(id: keys, keys: combo)))
}

private func listening(_ id: String, _ keys: String = #"["hyper+shift+m", "ctrl+alt+space"]"#) throws -> Harness {
    try Harness(widget(setup: "var listening = host.hotkeys(\(keys), function (keys) { count = keys; });"), id: id, uses: ["hotkeys"])
}

struct HotkeyListenerTests {
    @Test func `a plugin's hotkeys register under its id, and A press calls onPress with the keys as the plugin wrote them`() async throws {
        let harness = try listening("test.listen")
        #expect(try await harness.text() == "0")
        #expect(bindings(of: "test.listen") == ["ctrl+alt+space=ctrl+alt+space", "hyper+shift+m=ctrl+alt+shift+cmd+m"])
        #expect(try press("ctrl+alt+cmd+shift+m", of: "test.listen"))
        #expect(try await harness.text() == "hyper+shift+m")
        #expect(try !press("ctrl+alt+cmd+m", of: "test.listen"))
        harness.runtime.stop()
    }

    @Test func `stopping the plugin releases its hotkeys`() async throws {
        let harness = try listening("test.release")
        #expect(try await harness.text() == "0")
        harness.runtime.stop()
        #expect(harness.runtime.queue.sync { !harness.runtime.isRunning })
        #expect(bindings(of: "test.release").isEmpty)
        #expect(try !press("hyper+shift+m", of: "test.release"))
    }

    @Test func `stop releases the hotkeys of one call`() async throws {
        let harness = try Harness(widget("""
        onAction: function () { listening.stop(); },
        """, setup: #"var listening = host.hotkeys(["hyper+m"], function () {});"#), id: "test.stop", uses: ["hotkeys"])
        #expect(try await harness.text() == "0")
        #expect(bindings(of: "test.stop") == ["hyper+m=ctrl+alt+cmd+m"])
        harness.runtime.perform("stop", .null)
        #expect(harness.runtime.queue.sync { harness.runtime.isRunning })
        #expect(bindings(of: "test.stop").isEmpty)
        harness.runtime.stop()
    }

    @Test func `while A reload overlaps, A press goes to the newer runtime of the plugin`() async throws {
        let old = try listening("test.reload")
        #expect(try await old.text() == "0")
        let new = try listening("test.reload")
        #expect(try await new.text() == "0")
        #expect(try press("hyper+shift+m", of: "test.reload"))
        #expect(try await new.text() == "hyper+shift+m")
        #expect(old.events.isEmpty)
        old.runtime.stop()
        #expect(old.runtime.queue.sync { !old.runtime.isRunning })
        #expect(bindings(of: "test.reload") == ["ctrl+alt+space=ctrl+alt+space", "hyper+shift+m=ctrl+alt+shift+cmd+m"])
        new.runtime.stop()
    }

    @Test func `a hotkey that is not valid, or two that are the same, fail the call with the keys named`() async throws {
        let harness = try Harness(widget("""
        onAction: function (keys) {
          try {
            host.hotkeys(JSON.parse(keys), function () {});
          } catch (e) {
            count = e.message;
          }
        },
        """), id: "test.invalid", uses: ["hotkeys"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform(#"["hyper+shift+spacebar"]"#, .null)
        #expect(try await harness.text().hasPrefix(#"host.hotkeys: "hyper+shift+spacebar" is not a hotkey"#))
        harness.runtime.perform(#"["hyper+m", "ctrl+alt+cmd+m"]"#, .null)
        #expect(try await harness.text() == #"host.hotkeys: "hyper+m" and "ctrl+alt+cmd+m" are the same hotkey"#)
        #expect(bindings(of: "test.invalid").isEmpty)
        harness.runtime.stop()
    }

    @Test func `gary:effect streams the presses and releases the hotkeys when the plugin's scope closes`() async throws {
        let harness = try Harness("""
        import { Effect, Stream, host } from "gary:effect";
        let pressed = "none";
        export default {
          effect: host.hotkeys(["hyper+return"]).pipe(Stream.runForEach((keys) => Effect.sync(() => { pressed = keys; }))),
          render: () => ({ type: "text", text: pressed }),
        };
        """, id: "test.stream", uses: ["hotkeys"])
        #expect(try await harness.text() == "none")
        while bindings(of: "test.stream").isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(try press("hyper+return", of: "test.stream"))
        #expect(try await harness.text() == "hyper+return")
        harness.runtime.stop()
        #expect(harness.runtime.queue.sync { !harness.runtime.isRunning })
        #expect(bindings(of: "test.stream").isEmpty)
    }

    @Test func `host hyperkey rejects options that are not A shift flag before it touches the keyboard`() async throws {
        let harness = try Harness(widget("""
        onAction: function (options) {
          try {
            host.hyperkey(JSON.parse(options));
          } catch (e) {
            count = e.message;
          }
        },
        """), id: "test.hyperkey", uses: ["hyperkey"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform(#"{"shift":"yes"}"#, .null)
        #expect(try await harness.text() == "host.hyperkey: options.shift must be true or false")
        harness.runtime.perform("true", .null)
        #expect(try await harness.text() == "host.hyperkey: options must be an object such as { shift: true }")
        harness.runtime.stop()
    }
}
