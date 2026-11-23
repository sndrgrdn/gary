import Foundation
@testable import gary
import GaryCore
import Testing

private func scratchFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "gary-watch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "notes.txt")
}

private func write(_ text: String, to file: URL) throws {
    try Data(text.utf8).write(to: file)
}

private func watching(_ file: URL) throws -> Harness {
    try Harness(widget(setup: """
    host.watchFile(\(JSON.string(file.path).text), function (text) { count = text === null ? "missing" : text; });
    """), uses: ["files"])
}

struct HostWatchFileTests {
    @Test func `a file created after the watch starts calls back with its text, and so does each later write`() async throws {
        let file = try scratchFile()
        let harness = try watching(file)
        #expect(try await harness.text() == "0")
        await harness.settled()
        try write("created", to: file)
        #expect(try await harness.text() == "created")
        try write("edited", to: file)
        #expect(try await harness.text() == "edited")
        harness.runtime.stop()
    }

    @Test func `a watched file that is deleted calls back with null, and calls back again when it is created anew`() async throws {
        let file = try scratchFile()
        try write("first", to: file)
        let harness = try watching(file)
        #expect(try await harness.text() == "0")
        await harness.settled()
        try FileManager.default.removeItem(at: file)
        #expect(try await harness.text() == "missing")
        try write("second", to: file)
        #expect(try await harness.text() == "second")
        harness.runtime.stop()
    }

    @Test func `stop ends the callbacks of one watch while another watch of the same file keeps calling back`() async throws {
        let file = try scratchFile()
        try write("first", to: file)
        let path = JSON.string(file.path).text
        let harness = try Harness(widget("""
        onAction: function () { stopped.stop(); },
        """, setup: """
        var seen = [];
        var stopped = host.watchFile(\(path), function (text) { seen.push("stopped " + text); count = seen.join(","); });
        host.watchFile(\(path), function (text) { seen.push("kept " + text); count = seen.join(","); });
        """), uses: ["files"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("stop", .null)
        await harness.settled()
        try write("second", to: file)
        #expect(try await harness.text() == "kept second")
        try write("third", to: file)
        #expect(try await harness.text() == "kept second,kept third")
        harness.runtime.stop()
    }
}
