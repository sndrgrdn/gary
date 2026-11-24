import Foundation
@testable import gary
import GaryCore
import Testing

private func scratchFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appending(path: "gary-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

struct HostFilesTests {
    @Test func `mkdir returns true when it creates the folder and its parents, and false when the folder exists`() async throws {
        let path = try scratchFolder().appending(path: "a/b").path
        let harness = try Harness(widget("""
        onAction: function () { count = [host.mkdir(\(JSON.string(path).text)), host.mkdir(\(JSON.string(path).text))].join(" "); },
        """), uses: ["files"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("make", .null)
        #expect(try await harness.text() == "true false")
        var isFolder: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue)
        harness.runtime.stop()
    }

    @Test func `mkdir throws for A path that holds A file`() async throws {
        let file = try scratchFolder().appending(path: "notes.txt")
        try Data("notes".utf8).write(to: file)
        let harness = try Harness(widget("""
        onAction: function () {
          try { host.mkdir(\(JSON.string(file.path).text)); } catch (e) { count = e.message; }
        },
        """), uses: ["files"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("make", .null)
        #expect(try await harness.text() == "host.mkdir: \(file.path): File exists")
        harness.runtime.stop()
    }

    @Test func `two plugins that race to create the same folders get exactly one true for each folder`() async throws {
        let folder = try scratchFolder().path
        let source = widget("""
        onAction: function () {
          var made = 0;
          for (var i = 0; i < 300; i++) if (host.mkdir(\(JSON.string(folder).text) + "/" + i)) made++;
          count = made;
        },
        """)
        let first = try Harness(source, uses: ["files"], engine: PluginEngine(effect: vendor.appending(path: "effect.js")))
        let second = try Harness(source, uses: ["files"], engine: PluginEngine(effect: vendor.appending(path: "effect.js")))
        #expect(try await first.text() == "0")
        #expect(try await second.text() == "0")
        first.runtime.perform("race", .null)
        second.runtime.perform("race", .null)
        let made = try await [first.text(), second.text()].compactMap { Int($0) }
        #expect(made.count == 2 && made.reduce(0, +) == 300)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder).count == 300)
        first.runtime.stop()
        second.runtime.stop()
    }

    @Test func `list gives each entry the time of its last change in milliseconds`() async throws {
        let folder = try scratchFolder()
        let new = folder.appending(path: "new.txt")
        try Data("new".utf8).write(to: new)
        let written = try #require(FileManager.default.attributesOfItem(atPath: new.path)[.modificationDate] as? Date)
        let old = folder.appending(path: "old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000.25)], ofItemAtPath: old.path)
        let harness = try Harness(widget("""
        onAction: function () {
          count = host.list(\(JSON.string(folder.path).text)).map(function (entry) {
            return entry.name + " " + entry.modified;
          }).join(", ");
        },
        """), uses: ["files"])
        #expect(try await harness.text() == "0")
        harness.runtime.perform("list", .null)
        #expect(try await harness.text() == "new.txt \(Int((written.timeIntervalSince1970 * 1000).rounded(.down))), old 1700000000250")
        harness.runtime.stop()
    }
}
