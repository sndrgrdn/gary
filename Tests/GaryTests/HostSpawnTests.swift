import Foundation
@testable import gary
import Testing

private func settled(_ harness: Harness) async throws -> String {
    var text = try await harness.text()
    while text == "0" {
        text = try await harness.text()
    }
    return text
}

struct HostSpawnTests {
    @Test func `host spawn calls onLine with each stdout line and resolves exited with the status and stderr`() async throws {
        let harness = try Harness(widget("""
        onAction: function () {
          var lines = [];
          var command = "printf 'one\\\\ntwo\\\\n'; printf 'three\\\\nfour'; echo err >&2; exit 2";
          host.spawn(["/bin/sh", "-c", command], function (line) { lines.push(line); })
            .exited.then(function (r) { count = lines.join(",") + " " + r.status + " " + r.stderr.trim(); });
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        #expect(try await settled(harness) == "one,two,three,four 2 err")
        harness.runtime.stop()
    }

    @Test func `host spawn joins A line written across several reads`() async throws {
        let harness = try Harness(widget("""
        onAction: function () {
          var lines = [];
          var command = "printf x; yes \\"$(printf '\\\\303\\\\251')\\" | head -n 100000 | tr -d '\\\\n'; echo; echo next";
          host.spawn(["/bin/sh", "-c", command], function (line) { lines.push(line === "x" + "é".repeat(100000) ? "whole" : line); })
            .exited.then(function () { count = lines.join(","); });
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        let lines = try await settled(harness)
        #expect(lines == "whole,next")
        harness.runtime.stop()
    }

    @Test func `host spawn cuts A line longer than 1 MB to its first 1 MB and drops the rest of it`() async throws {
        let harness = try Harness(widget("""
        onAction: function () {
          var lines = [];
          var command = "head -c 20000000 /dev/zero | tr '\\\\0' a; echo; echo next";
          host.spawn(["/bin/sh", "-c", command], function (line) { lines.push(line.replace(/^a+$/, function (run) { return run.length; })); })
            .exited.then(function () { count = lines.join(","); });
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        let lines = try await settled(harness)
        #expect(lines == "\(1 << 20),next")
        harness.runtime.stop()
    }

    @Test func `stop ends A spawned command, and stopping before it starts never runs it`() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "gary-spawn-\(UUID().uuidString)").path
        let harness = try Harness(widget("""
        onAction: function (name) {
          if (name === "early") {
            var early = host.spawn(["/usr/bin/touch", "\(file)"], function () {});
            early.stop();
            early.exited.then(function (r) { count = "early " + r.status; });
            return;
          }
          var spawned = host.spawn(["/bin/sh", "-c", "echo ready; exec tail -f /dev/null"], function () { spawned.stop(); });
          spawned.exited.then(function (r) { count = "stopped " + r.status; });
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("early", .null)
        #expect(try await settled(harness) == "early -1")
        harness.runtime.perform("run", .null)
        var text = try await harness.text()
        while text.hasPrefix("early") {
            text = try await harness.text()
        }
        #expect(text == "stopped \(SIGTERM)")
        #expect(!FileManager.default.fileExists(atPath: file))
        harness.runtime.stop()
    }

    @Test func `stopping the plugin stops its spawned commands`() async throws {
        let pidFile = try pidPipe()
        let harness = try Harness(widget("""
        onAction: function () {
          host.spawn(["/bin/sh", "-c", "echo $$ > \(pidFile); exec tail -f /dev/null"], function () {});
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        let pid = try await processID(in: pidFile)
        harness.runtime.stop()
        #expect(await exits(pid))
    }

    @Test func `stop ends every process A spawned command started`() async throws {
        let pidFile = try pidPipe()
        let harness = try Harness(widget("""
        onAction: function () {
          var spawned = host.spawn(["/bin/sh", "-c", "tail -f /dev/null | tail -f /dev/null & echo $! > \(pidFile); echo ready; wait"], function () {
            spawned.stop();
          });
          spawned.exited.then(function (r) { count = "stopped " + r.status; });
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("run", .null)
        let pid = try await processID(in: pidFile)
        #expect(try await settled(harness) == "stopped \(SIGTERM)")
        #expect(await exits(pid))
        harness.runtime.stop()
    }

    @Test func `host spawn throws for arguments that are not a command`() async throws {
        let harness = try Harness(widget("""
        onAction: function (name) {
          try {
            host.spawn(name === "empty" ? [] : ["/bin/echo"], name === "empty" ? function () {} : null);
          } catch (e) {
            count = e.message;
          }
        },
        """), uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("empty", .null)
        #expect(try await harness.text() == "host.spawn: argv must not be empty")
        harness.runtime.perform("callback", .null)
        #expect(try await harness.text() == "host.spawn: onLine must be a function")
        harness.runtime.stop()
    }

    @Test func `gary effect host spawn is A stream of lines that fails on A nonzero status and stops the command when interrupted`() async throws {
        let pidFile = try pidPipe()
        let harness = try Harness("""
        import { Effect, Stream, host } from "gary:effect";
        let text = "0";
        const collect = (command) => Stream.runCollect(host.spawn(["/bin/sh", "-c", command])).pipe(
          Effect.map((lines) => lines.join(",")),
          Effect.catchTag("HostError", (error) => Effect.succeed(error.message)),
        );
        export default {
          onAction(name) {
            if (name === "ok") Effect.runFork(Effect.map(collect("echo a; echo b"), (lines) => { text = lines; }));
            if (name === "fail") Effect.runFork(Effect.map(collect("echo a; echo oops >&2; exit 3"), (lines) => { text = lines; }));
            if (name === "take") {
              const command = "echo $$ > \(pidFile); echo first; exec tail -f /dev/null";
              Effect.runFork(Effect.map(Stream.runCollect(Stream.take(host.spawn(["/bin/sh", "-c", command]), 1)), (lines) => { text = lines.join(","); }));
            }
          },
          render: () => ({ type: "text", text }),
        };
        """, uses: ["exec"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("ok", .null)
        #expect(try await settled(harness) == "a,b")
        harness.runtime.perform("fail", .null)
        var text = try await harness.text()
        while text == "a,b" {
            text = try await harness.text()
        }
        #expect(text == "/bin/sh exited with status 3: oops")
        harness.runtime.perform("take", .null)
        async let pid = processID(in: pidFile)
        while text != "first" {
            text = try await harness.text()
        }
        #expect(try await exits(pid))
        harness.runtime.stop()
    }
}
