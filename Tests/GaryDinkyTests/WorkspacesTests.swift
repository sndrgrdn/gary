import Foundation
import Testing
import GaryCore
import GarySocket
@testable import GaryDinky

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func space(_ id: UInt64) -> SpaceID { SpaceID(id) }

private func names(_ snapshot: WorkspacesSnapshot) -> [String: String] {
    Dictionary(uniqueKeysWithValues: snapshot.displays.map { display in
        (display.display, display.workspaces.map { $0.name + ($0.focused ? "*" : $0.visible ? "+" : "") }.joined(separator: " "))
    })
}

struct DebugStateTests {
    @Test func mapsEachSpaceToItsWorkspaceOnOneDisplay() throws {
        let map = try WorkspaceMap.parseDebugState(try fixture("debug-state-one-display.json"))
        #expect(map.names == [space(1): "1", space(3): "2", space(4): "3", space(5): "4", space(167): "5"])

        let live = [DisplaySpaces(uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", current: space(3), spaces: [1, 3, 4, 5, 167].map(space))]
        let snapshot = WorkspaceNames.mapped(map).snapshot(live: live, active: space(3))
        #expect(snapshot.source == .dinky)
        #expect(names(snapshot) == ["37D8832A-2D66-02CA-B9F7-8F30A301B230": "1 2* 3 4 5"])
    }

    @Test func splitsWorkspacesByDisplayAndMarksOnlyTheFocusedOne() throws {
        let map = try WorkspaceMap.parseDebugState(try fixture("debug-state-two-displays.json"))
        let live = [
            DisplaySpaces(uuid: "AAAA-BUILTIN", current: space(3), spaces: [1, 3, 4].map(space)),
            DisplaySpaces(uuid: "BBBB-STUDIO", current: space(11), spaces: [10, 11].map(space)),
        ]
        #expect(names(WorkspaceNames.mapped(map).snapshot(live: live, active: space(11))) == ["AAAA-BUILTIN": "1 2+ 3", "BBBB-STUDIO": "4 5*"])
    }

    @Test func throwsWhenDinkyChangesTheShape() throws {
        #expect(throws: DinkyParseError(description: "debug-state has no workspaces object")) {
            try WorkspaceMap.parseDebugState(try fixture("debug-state-reshaped.json"))
        }
        #expect(throws: DinkyParseError.self) { try WorkspaceMap.parseDebugState(try fixture("debug-state-string-ids.json")) }
        #expect(throws: DinkyParseError(description: "debug-state is not a JSON object")) { try WorkspaceMap.parseDebugState("ok") }
    }

    @Test func aSpaceMissingFromTheMapMarksItStale() throws {
        let names = WorkspaceNames.mapped(try WorkspaceMap.parseDebugState(try fixture("debug-state-one-display.json")))
        #expect(names.knows(space(167)))
        #expect(!names.knows(space(200)))
        let live = [DisplaySpaces(uuid: "D", current: space(200), spaces: [1, 200].map(space))]
        #expect(GaryDinkyTests.names(names.snapshot(live: live, active: space(200))) == ["D": "1"])
    }

    @Test func ordersNamesNumericallyThenAlphabetically() {
        let map = WorkspaceMap([space(1): "10", space(2): "web", space(3): "2", space(4): "mail"])
        let live = [DisplaySpaces(uuid: "D", current: space(1), spaces: [1, 2, 3, 4].map(space))]
        #expect(names(WorkspaceNames.mapped(map).snapshot(live: live, active: space(9))) == ["D": "2 10+ mail web"])
    }
}

struct LearnedWorkspacesTests {
    @Test func parsesListWorkspacesRows() throws {
        #expect(try parseWorkspaceRows(try fixture("list-workspaces.txt")) == [
            WorkspaceRow(name: "1", focused: false, monitor: 1), WorkspaceRow(name: "2", focused: true, monitor: 1),
            WorkspaceRow(name: "3", focused: false, monitor: 1), WorkspaceRow(name: "4", focused: false, monitor: 1),
            WorkspaceRow(name: "5", focused: false, monitor: 1),
        ])
        #expect(throws: DinkyParseError.self) { try parseWorkspaceRows("1 false 1\n") }
        #expect(throws: DinkyParseError.self) { try parseWorkspaceRows("1\tyes\t1\n") }
    }

    @Test func parsesTheFocusedWorkspace() {
        #expect(parseFocusedWorkspace("2") == "2")
        #expect(parseFocusedWorkspace("3\n") == "3")
        #expect(parseFocusedWorkspace("") == nil)
    }

    @Test func learnsEachSpaceAsTheBarSeesItFocused() throws {
        let rows = try parseWorkspaceRows(try fixture("list-workspaces-two-displays.txt"))
        let live = [
            DisplaySpaces(uuid: "A", current: space(3), spaces: [1, 3, 4].map(space)),
            DisplaySpaces(uuid: "B", current: space(10), spaces: [10, 11].map(space)),
        ]
        var map = WorkspaceMap()
        #expect(names(WorkspaceNames.learned(rows: rows, map: map).snapshot(live: live, active: space(3))) == ["A": "1 2 3", "B": "4 5"])
        #expect(!WorkspaceNames.learned(rows: rows, map: map).knows(space(3)))

        map.learn("2", on: space(3))
        map.learn("4", on: space(10))
        #expect(names(WorkspaceNames.learned(rows: rows, map: map).snapshot(live: live, active: space(3))) == ["A": "1 2* 3", "B": "4+ 5"])
    }

    @Test func learningMovesANameToItsNewSpace() {
        var map = WorkspaceMap()
        map.learn("2", on: space(3))
        map.learn("2", on: space(7))
        map.learn("5", on: space(7))
        #expect(map.names == [space(7): "5"])
    }
}

struct NativeWorkspacesTests {
    @Test func numbersEachDisplaysSpacesFromOne() {
        let live = [
            DisplaySpaces(uuid: "A", current: space(3), spaces: [1, 3].map(space)),
            DisplaySpaces(uuid: "B", current: space(10), spaces: [10, 11, 12].map(space)),
        ]
        let snapshot = WorkspaceNames.native.snapshot(live: live, active: space(10))
        #expect(snapshot.source == .native)
        #expect(names(snapshot) == ["A": "1 2+", "B": "1* 2 3"])
    }
}

struct DinkyClientTests {
    @Test func parsesOkAndErrorReplies() throws {
        #expect(try DinkyClient.parseReply("ok\n2") == "2")
        #expect(try DinkyClient.parseReply("ok\n") == "")
        #expect(throws: DinkyError.failed("unknown command 'x'")) { try DinkyClient.parseReply("error\nunknown command 'x'") }
        #expect(throws: DinkyError.malformedReply("pong")) { try DinkyClient.parseReply("pong") }
    }

    @Test func speaksDinkysFramingOverTheSocket() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("k-\(UUID().uuidString.prefix(8)).sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(bound == 0 && listen(fd, 1) == 0)
        defer { close(fd); unlink(path) }
        let received = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var request = ""
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil)
            var data = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 64)
            while true {
                let count = recv(client, &chunk, chunk.count, 0)
                if count <= 0 { break }
                data += chunk[..<count]
            }
            request = String(decoding: data, as: UTF8.self)
            _ = "ok\n3".withCString { send(client, $0, 4, 0) }
            close(client)
            received.signal()
        }
        #expect(try DinkyClient(path: path).run(focusedWorkspaceCommand) == "3")
        received.wait()
        #expect(request == "list-workspaces --focused --format '%{workspace}'")
    }

    @Test func aMissingSocketMeansDinkyIsNotRunning() {
        let client = DinkyClient(path: "/tmp/no-such-dinky.sock")
        #expect(throws: SocketError.unreachable("/tmp/no-such-dinky.sock")) { try client.run("list-workspaces") }
    }
}
