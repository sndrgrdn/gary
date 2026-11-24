import Foundation
@testable import gary
import GaryCore
import Testing

private func scratchLock() throws -> String {
    let folder = FileManager.default.temporaryDirectory.appending(path: "gary-lock-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appending(path: "auth.json.lock")
    try Data("pid 42".utf8).write(to: file)
    return file.path
}

private func lockedByAnotherProcess(_ path: String) throws -> Bool {
    let probe = try Process.run(URL(fileURLWithPath: "/usr/bin/lockf"), arguments: ["-k", "-s", "-t", "0", path, "/usr/bin/true"])
    probe.waitUntilExit()
    return probe.terminationStatus == EX_TEMPFAIL
}

private struct Holder {
    let process: Process
    let input: FileHandle

    func letGo() throws {
        try input.close()
        process.waitUntilExit()
    }
}

private func holdInAnotherProcess(_ path: String) throws -> Holder {
    let input = Pipe()
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/lockf")
    process.arguments = ["-k", path, "/bin/sh", "-c", "echo held; exec cat"]
    process.standardInput = input
    process.standardOutput = output
    try process.run()
    _ = output.fileHandleForReading.availableData
    return Holder(process: process, input: input.fileHandleForWriting)
}

private func text(of path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

private func locking(_ path: String) throws -> Harness {
    try Harness(widget("""
    onAction: function () { lock.release(); count = "released"; },
    """, setup: """
    var lock;
    host.lockFile(\(JSON.string(path).text)).then(
      function (held) { lock = held; count = "held"; },
      function (e) { count = e.message; }
    );
    """), uses: ["files"])
}

struct HostLockFileTests {
    @Test func `a lock Gary holds blocks flock in another process until release, and leaves the file's text alone`() async throws {
        let path = try scratchLock()
        let harness = try locking(path)
        #expect(try await harness.text() == "0")
        #expect(try await harness.text() == "held")
        #expect(try lockedByAnotherProcess(path))
        harness.runtime.perform("release", .null)
        #expect(try await harness.text() == "released")
        #expect(try !lockedByAnotherProcess(path))
        #expect(try text(of: path) == "pid 42")
        harness.runtime.stop()
    }

    @Test func `lockFile creates A missing file and leaves it empty`() async throws {
        let path = try scratchLock()
        try FileManager.default.removeItem(atPath: path)
        let harness = try locking(path)
        #expect(try await harness.text() == "0")
        #expect(try await harness.text() == "held")
        #expect(try text(of: path).isEmpty)
        harness.runtime.stop()
    }

    @Test func `a second lockFile of the same file waits until the first lock is released`() async throws {
        let path = try scratchLock()
        let harness = try Harness(widget("""
        onAction: function () { first.release(); seen.push("released"); count = seen.join(","); },
        """, setup: """
        var first, seen = [];
        host.lockFile(\(JSON.string(path).text)).then(function (lock) {
          first = lock;
          seen.push("first");
          count = seen.join(",");
          host.lockFile(\(JSON.string(path).text)).then(function () { seen.push("second"); count = seen.join(","); });
        });
        """), uses: ["files"])
        #expect(try await harness.text() == "0")
        #expect(try await harness.text() == "first")
        await harness.settled()
        harness.timers.advance(by: 5000)
        await harness.settled()
        #expect(harness.events.isEmpty)
        harness.runtime.perform("release", .null)
        #expect(try await harness.text() == "first,released")
        harness.timers.advance(by: 50)
        #expect(try await harness.text() == "first,released,second")
        harness.runtime.stop()
    }

    @Test func `lockFile waits while another process holds the lock and resolves once it lets go`() async throws {
        let path = try scratchLock()
        let holder = try holdInAnotherProcess(path)
        let harness = try locking(path)
        #expect(try await harness.text() == "0")
        await harness.settled()
        harness.timers.advance(by: 9900)
        await harness.settled()
        #expect(harness.events.isEmpty)
        try holder.letGo()
        harness.timers.advance(by: 50)
        #expect(try await harness.text() == "held")
        #expect(try text(of: path) == "pid 42")
        harness.runtime.stop()
    }

    @Test func `lockFile locks the file at the path when another process replaced it during the wait`() async throws {
        let path = try scratchLock()
        let holder = try holdInAnotherProcess(path)
        let harness = try locking(path)
        #expect(try await harness.text() == "0")
        await harness.settled()
        try FileManager.default.removeItem(atPath: path)
        try Data("pid 43".utf8).write(to: URL(fileURLWithPath: path))
        try holder.letGo()
        harness.timers.advance(by: 50)
        #expect(try await harness.text() == "held")
        #expect(try lockedByAnotherProcess(path))
        #expect(try text(of: path) == "pid 43")
        harness.runtime.stop()
    }

    @Test func `lockFile rejects after 10 seconds when another process keeps the lock`() async throws {
        let path = try scratchLock()
        let holder = try holdInAnotherProcess(path)
        defer { try? holder.letGo() }
        let harness = try locking(path)
        #expect(try await harness.text() == "0")
        await harness.settled()
        harness.timers.advance(by: 9950)
        await harness.settled()
        #expect(harness.events.isEmpty)
        harness.timers.advance(by: 50)
        #expect(try await harness.text() == "host.lockFile: \(path) is locked by another process")
        #expect(try text(of: path) == "pid 42")
        harness.runtime.stop()
    }

    @Test func `stopping the plugin releases the locks it holds`() async throws {
        let path = try scratchLock()
        let harness = try locking(path)
        #expect(try await harness.text() == "0")
        #expect(try await harness.text() == "held")
        #expect(try lockedByAnotherProcess(path))
        harness.runtime.stop()
        await harness.settled()
        #expect(try !lockedByAnotherProcess(path))
    }

    @Test func `gary:effect holds A lock until its scope closes`() async throws {
        let path = try scratchLock()
        let harness = try Harness("""
        import { Effect, host } from "gary:effect";
        let text = "none";
        let done = () => {};
        export default {
          effect: Effect.scoped(
            host.lockFile(\(JSON.string(path).text)).pipe(
              Effect.andThen(Effect.sync(() => { text = "held"; })),
              Effect.andThen(Effect.promise(() => new Promise((resolve) => { done = resolve; }))),
            ),
          ).pipe(Effect.andThen(Effect.sync(() => { text = "released"; }))),
          render: () => ({ type: "text", text }),
          onAction: () => done(),
        };
        """, uses: ["files"])
        #expect(try await harness.text() == "none")
        #expect(try await harness.text() == "held")
        #expect(try lockedByAnotherProcess(path))
        harness.runtime.perform("close", .null)
        #expect(try await harness.text() == "released")
        #expect(try !lockedByAnotherProcess(path))
        #expect(harness.isRunning)
        harness.runtime.stop()
    }
}
