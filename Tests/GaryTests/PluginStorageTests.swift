import Foundation
@testable import gary
import GaryCore
import Testing

struct PluginStorageTests {
    private static let source = widget("""
    render: function () { return { type: "text", text: JSON.stringify([count, host.storage.get("a"), host.storage.get("b")]) }; },
    onAction: function (name, payload) { count += 1; host.storage.set(name, payload === null ? undefined : payload); },
    """)

    @Test func `two runtimes of one plugin share storage without losing writes`() async throws {
        let id = "test.storage-shared"
        let file = Paths.storage.appending(path: "\(id).json")
        try? FileManager.default.removeItem(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let widgetSide = try Harness(Self.source, id: id)
        let panelSide = try Harness(Self.source, id: id)
        #expect(try await widgetSide.text() == "[0,null,null]")
        #expect(try await panelSide.text() == "[0,null,null]")
        widgetSide.runtime.perform("a", .number(1))
        #expect(try await widgetSide.text() == "[1,1,null]")
        panelSide.runtime.perform("b", .number(2))
        let panelSees = try await panelSide.text()
        #expect(panelSees == "[1,1,2]")
        widgetSide.runtime.perform("a", .number(3))
        let widgetSees = try await widgetSide.text()
        #expect(widgetSees == "[2,3,2]")
        let stored = try JSON.parse(Data(contentsOf: file))
        #expect(stored == .object(["a": .number(3), "b": .number(2)]))
        widgetSide.runtime.stop()
        panelSide.runtime.stop()
    }

    @Test func `storage reads values already on disk and deletes a key set to undefined`() async throws {
        let id = "test.storage-file"
        let file = Paths.storage.appending(path: "\(id).json")
        try FileManager.default.createDirectory(at: Paths.storage, withIntermediateDirectories: true)
        try Data(#"{"a":{"x":[1,"y"]},"b":true}"#.utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = try Harness(Self.source, id: id)
        #expect(try await harness.text() == #"[0,{"x":[1,"y"]},true]"#)
        harness.runtime.perform("b", .null)
        #expect(try await harness.text() == #"[1,{"x":[1,"y"]},null]"#)
        #expect(try JSON.parse(Data(contentsOf: file)) == .object(["a": .object(["x": .array([.number(1), .string("y")])])]))
        harness.runtime.stop()
    }

    @Test func `a missing storage file reads empty and sets nothing aside`() async throws {
        let id = "test.storage-missing"
        let file = Paths.storage.appending(path: "\(id).json")
        try? FileManager.default.removeItem(at: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let harness = try Harness(Self.source, id: id)
        #expect(try await harness.text() == "[0,null,null]")
        #expect(try Self.asides(id).isEmpty)
        harness.runtime.stop()
    }

    @Test(arguments: [("test.storage-garbage", "not json{"), ("test.storage-array", "[1,2]")])
    func `an unreadable storage file is moved aside intact before storage starts empty`(id: String, contents: String) async throws {
        let file = Paths.storage.appending(path: "\(id).json")
        try FileManager.default.createDirectory(at: Paths.storage, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            for aside in (try? Self.asides(id)) ?? [] {
                try? FileManager.default.removeItem(at: aside)
            }
        }
        let harness = try Harness(Self.source, id: id)
        #expect(try await harness.text() == "[0,null,null]")
        harness.runtime.perform("a", .number(1))
        #expect(try await harness.text() == "[1,1,null]")
        #expect(try JSON.parse(Data(contentsOf: file)) == .object(["a": .number(1)]))
        let asides = try Self.asides(id)
        #expect(asides.count == 1)
        #expect(try asides.map { try String(contentsOf: $0, encoding: .utf8) } == [contents])
        harness.runtime.stop()
    }

    private static func asides(_ id: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: Paths.storage, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("\(id).corrupt-") }
    }
}
