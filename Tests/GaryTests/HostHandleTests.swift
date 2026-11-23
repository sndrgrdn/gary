@testable import gary
import Testing

struct HostHandleTests {
    @Test func `each host API that takes A callback names itself when an argument is bad`() async throws {
        let harness = try Harness(widget("""
        onAction: function (name) {
          var calls = {
            spawn: function () { host.spawn("ls", function () {}); },
            hotkeys: function () { host.hotkeys(["hyper+m"]); },
            hyperkey: function () { host.hyperkey("capsLock"); },
          };
          try {
            calls[name]();
          } catch (e) {
            count = e.message;
          }
        },
        """), id: "test.handles", uses: ["exec", "hotkeys", "hyperkey"])
        #expect(try await harness.text() == "0")
        let expected = [
            "spawn": "host.spawn: argv must be an array of strings",
            "hotkeys": "host.hotkeys: onPress must be a function",
            "hyperkey": #"host.hyperkey: options must be an object such as { key: "capsLock", shift: true }"#,
        ]
        for (name, message) in expected.sorted(by: { $0.key < $1.key }) {
            harness.runtime.perform(name, .null)
            #expect(try await harness.text() == message)
        }
        harness.runtime.stop()
    }
}
