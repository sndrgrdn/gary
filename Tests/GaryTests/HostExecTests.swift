@testable import gary
import Testing

struct HostExecTests {
    @Test func `host exec resolves with the result and throws for arguments that are not a command`() async throws {
        let harness = try Harness(widget("""
        onAction: function (name) {
          var argv = name === "echo" ? ["/bin/sh", "-c", "echo out; echo err >&2; exit 3"] : [];
          try {
            host.exec(argv).then(function (r) { count = r.status + " " + r.stdout.trim() + " " + r.stderr.trim(); });
          } catch (e) {
            count = e.message;
          }
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("echo", .null)
        #expect(try await harness.text() == "3 out err")
        harness.runtime.perform("empty", .null)
        #expect(try await harness.text() == "host.exec: argv must not be empty")
        harness.runtime.stop()
    }
}
