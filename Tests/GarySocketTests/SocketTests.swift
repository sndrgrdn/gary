import Foundation
import Testing
@testable import GarySocket

struct LineBufferTests {
    @Test func splitsLinesAndHoldsTheRemainder() throws {
        var buffer = LineBuffer()
        #expect(try buffer.append(Array("a\nbc".utf8)) == ["a"])
        #expect(try buffer.append(Array("d\n\ne\n".utf8)) == ["bcd", "", "e"])
    }

    @Test func joinsACharacterSplitAcrossReads() throws {
        var buffer = LineBuffer()
        let bytes = Array("é\n".utf8)
        #expect(try buffer.append(bytes[..<1]) == [])
        #expect(try buffer.append(bytes[1...]) == ["é"])
    }

    @Test func rejectsInvalidUTF8AndOversizedLines() {
        var invalid = LineBuffer()
        #expect(throws: SocketError.invalidUTF8) { try invalid.append([0xff, 10]) }
        var huge = LineBuffer()
        #expect(throws: SocketError.tooLarge) { try huge.append([UInt8](repeating: 65, count: maxMessageBytes + 1)) }
    }
}

struct LineServerTests {
    private let path = FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID().uuidString.prefix(8)).sock").path

    @Test func repliesToEachLineOnOneConnection() throws {
        let server = try LineServer(path: path) { "echo:" + $0 }
        defer { server.stop() }
        #expect(try requestLine("ping", path: path, timeout: 2) == "echo:ping")

        let fd = try connectSocket(path)
        defer { close(fd) }
        try writeAll(fd, "one\ntwo\n")
        var buffer = LineBuffer()
        var lines: [String] = []
        var chunk = [UInt8](repeating: 0, count: 256)
        while lines.count < 2 {
            let count = recv(fd, &chunk, chunk.count, 0)
            try #require(count > 0)
            lines += try buffer.append(chunk[..<count])
        }
        #expect(lines == ["echo:one", "echo:two"])
    }

    @Test func onlyTheOwnerCanOpenTheSocket() throws {
        let server = try LineServer(path: path) { $0 }
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func refusesASecondServerAndReplacesAStaleSocket() throws {
        let server = try LineServer(path: path) { _ in "first" }
        #expect(throws: SocketError.inUse(path)) { try LineServer(path: path) { _ in "second" } }
        server.stop()
        Thread.sleep(forTimeInterval: 0.05)

        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: path))

        let replacement = try LineServer(path: path) { _ in "second" }
        defer { replacement.stop() }
        #expect(try requestLine("x", path: path, timeout: 2) == "second")
    }

    @Test func stoppingRemovesTheSocket() throws {
        let server = try LineServer(path: path) { $0 }
        server.stop()
        Thread.sleep(forTimeInterval: 0.05)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: SocketError.unreachable(path)) { try requestLine("ping", path: path, timeout: 1) }
    }

    @Test func aSlowClientDoesNotBlockAnother() throws {
        let server = try LineServer(path: path) { $0 }
        defer { server.stop() }
        let idle = try connectSocket(path)
        defer { close(idle) }
        try writeAll(idle, "no newline yet")
        let start = Date()
        #expect(try requestLine("fast", path: path, timeout: 2) == "fast")
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

struct ExchangeTests {
    private let path = FileManager.default.temporaryDirectory.appendingPathComponent("d-\(UUID().uuidString.prefix(8)).sock").path

    /// A one-shot server framed like dinky's: read to EOF, reply, close.
    private func dinkyLike(reply: @escaping (String) -> String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(bound == 0 && listen(fd, 1) == 0)
        DispatchQueue.global().async {
            let client = accept(fd, nil, nil)
            var data = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 64)
            while true {
                let count = recv(client, &chunk, chunk.count, 0)
                if count <= 0 { break }
                data += chunk[..<count]
            }
            try? writeAll(client, reply(String(decoding: data, as: UTF8.self)))
            close(client)
        }
        return fd
    }

    @Test func sendsOneMessageAndReadsTheReplyToEOF() throws {
        let fd = try dinkyLike { "ok\n" + $0.uppercased() + "\nsecond line" }
        defer { close(fd); unlink(path) }
        #expect(try exchange("list-workspaces --all", path: path, timeout: 2) == "ok\nLIST-WORKSPACES --ALL\nsecond line")
    }

    @Test func aMissingSocketIsUnreachable() {
        #expect(throws: SocketError.unreachable(path)) { try exchange("ping", path: path, timeout: 1) }
    }
}
