import Foundation
@testable import gary
import os
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

    @Test func `host exec resolves when the command leaves A child running in the background`() async throws {
        let harness = try Harness(widget("""
        onAction: function () {
          host.exec(["/bin/sh", "-c", "tail -f /dev/null & echo $!"]).then(function (r) { count = r.status + " " + r.stdout.trim(); });
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        let text = try await harness.text()
        let child = try #require(Int32(text.dropFirst(2)))
        kill(child, SIGTERM)
        #expect(text.hasPrefix("0 "))
        harness.runtime.stop()
    }

    @Test func `stopping the plugin stops its running commands`() async throws {
        let pidFile = try pidPipe()
        let harness = try Harness(widget("""
        onAction: function () {
          host.exec(["/bin/sh", "-c", "echo $$ > \(pidFile); exec tail -f /dev/null"]);
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        let pid = try await processID(in: pidFile)
        harness.runtime.stop()
        #expect(await exits(pid))
    }

    @Test func `a command started by a call that fails never runs`() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "gary-exec-\(UUID().uuidString)").path
        let harness = try Harness(widget("""
        onAction: function () {
          host.exec(["/usr/bin/touch", "\(file)"]);
          throw new Error("failed after exec");
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        #expect(try await harness.failure().hasPrefix("Error: failed after exec"))
        await harness.settled()
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test func `a command that outlives the deadline is stopped and rejects`() async {
        let queue = DispatchQueue(label: "test.exec")
        let runs = ExecRuns(queue: queue, limit: 0)
        let outcome = await withCheckedContinuation { continuation in
            queue.async {
                runs.start(["/usr/bin/tail", "-f", "/dev/null"]) { result in
                    continuation.resume(returning: (try? result.get()).map { "\($0)" } ?? "\(result)")
                }
            }
        }
        #expect(outcome.contains("/usr/bin/tail ran longer than 0 seconds and was stopped"))
    }
}

func pidPipe() throws -> String {
    let path = FileManager.default.temporaryDirectory.appending(path: "gary-pid-\(UUID().uuidString)").path
    guard mkfifo(path, 0o600) == 0 else { throw RenderError("mkfifo \(path) failed: \(errno)") }
    return path
}

func processID(in pipe: String) async throws -> pid_t {
    let text = await withCheckedContinuation { done in
        DispatchQueue.global().async {
            done.resume(returning: FileHandle(forReadingAtPath: pipe).map { String(decoding: $0.readDataToEndOfFile(), as: UTF8.self) })
        }
    }
    try? FileManager.default.removeItem(atPath: pipe)
    guard let text, let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RenderError("no pid in \(pipe)") }
    return pid
}

func exits(_ pid: pid_t) async -> Bool {
    await withCheckedContinuation { done in
        let resumed = OSAllocatedUnfairLock(initialState: false)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        let finish: @Sendable () -> Void = {
            guard resumed.withLock({ resumed in
                defer { resumed = true }
                return !resumed
            }) else { return }
            source.cancel()
            done.resume(returning: true)
        }
        source.setEventHandler(handler: finish)
        source.resume()
        if kill(pid, 0) != 0 {
            finish()
        }
    }
}
