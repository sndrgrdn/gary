import Foundation
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
        """))
        #expect(try await harness.text() == "0")
        harness.runtime.perform("echo", .null)
        #expect(try await harness.text() == "3 out err")
        harness.runtime.perform("empty", .null)
        #expect(try await harness.text() == "host.exec: argv must not be empty")
        harness.runtime.stop()
    }

    @Test func `host exec resolves when the command leaves A child running in the background`() async throws {
        let harness = try Harness(widget("""
        onAction: function () {
          host.exec(["/bin/sh", "-c", "sleep 100 & echo $!"]).then(function (r) { count = r.status + " " + r.stdout.trim(); });
        },
        """))
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        let text = try await harness.text()
        let child = try #require(Int32(text.dropFirst(2)))
        kill(child, SIGTERM)
        #expect(text.hasPrefix("0 "))
        harness.runtime.stop()
    }

    @Test func `stopping the plugin stops its running commands`() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "gary-exec-\(UUID().uuidString)").path
        let harness = try Harness(widget("""
        onAction: function () {
          host.exec(["/bin/sh", "-c", "echo $$ > \(pidFile); exec sleep 100"]);
        },
        """))
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        let pid = try await processID(in: pidFile)
        harness.runtime.stop()
        #expect(try await exits(pid))
    }

    @Test func `a command started by a call that fails never runs`() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "gary-exec-\(UUID().uuidString)").path
        let harness = try Harness(widget("""
        onAction: function () {
          host.exec(["/usr/bin/touch", "\(file)"]);
          throw new Error("failed after exec");
        },
        """))
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test(.timeLimit(.minutes(1))) func `a command that outlives the deadline is stopped and rejects`() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "gary-exec-\(UUID().uuidString)").path
        let queue = DispatchQueue(label: "test.exec")
        nonisolated(unsafe) let runs = ExecRuns(queue: queue, limit: 0.2)
        let outcome = await withCheckedContinuation { continuation in
            queue.async {
                runs.start(["/bin/sh", "-c", "echo $$ > \(pidFile); exec sleep 100"]) { result in
                    continuation.resume(returning: (try? result.get()).map { "\($0)" } ?? "\(result)")
                }
            }
        }
        #expect(outcome.contains("/bin/sh ran longer than 0 seconds and was stopped"))
        #expect(try await exits(processID(in: pidFile)))
    }
}

private func processID(in file: String) async throws -> pid_t {
    for _ in 0..<400 {
        if let text = try? String(contentsOfFile: file, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw RenderError("no pid in \(file)")
}

private func exits(_ pid: pid_t) async throws -> Bool {
    for _ in 0..<400 where kill(pid, 0) == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    return kill(pid, 0) != 0
}
