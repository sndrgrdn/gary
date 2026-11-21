import Foundation
@testable import GarySocket
import Testing

struct LineBufferTests {
    @Test func `splits lines and holds the remainder`() throws {
        var buffer = LineBuffer()
        #expect(try buffer.append(Array("a\nbc".utf8)) == ["a"])
        #expect(try buffer.append(Array("d\n\ne\n".utf8)) == ["bcd", "", "e"])
    }

    @Test func `joins A character split across reads`() throws {
        var buffer = LineBuffer()
        let bytes = Array("é\n".utf8)
        #expect(try buffer.append(bytes[..<1]) == [])
        #expect(try buffer.append(bytes[1...]) == ["é"])
    }

    @Test func `rejects invalid UTF 8 and oversized lines`() {
        var invalid = LineBuffer()
        #expect(throws: SocketError.invalidUTF8) { try invalid.append([0xFF, 10]) }
        var huge = LineBuffer()
        #expect(throws: SocketError.tooLarge) { try huge.append([UInt8](repeating: 65, count: maxMessageBytes + 1)) }
    }
}

struct LineServerTests {
    private let path = FileManager.default.temporaryDirectory.appendingPathComponent("g-\(UUID().uuidString.prefix(8)).sock").path

    @Test func `replies to each line on one connection`() throws {
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

    @Test func `only the owner can open the socket`() throws {
        let server = try LineServer(path: path) { $0 }
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func `refuses A second server and replaces A stale socket`() throws {
        let server = try LineServer(path: path) { _ in "first" }
        #expect(throws: SocketError.inUse(path)) { try LineServer(path: path) { _ in "second" } }
        server.stop()
        Thread.sleep(forTimeInterval: 0.05)

        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(
            stale,
            $0,
            socklen_t(MemoryLayout<sockaddr_un>.size),
        ) } }
        close(stale)
        #expect(FileManager.default.fileExists(atPath: path))

        let replacement = try LineServer(path: path) { _ in "second" }
        defer { replacement.stop() }
        #expect(try requestLine("x", path: path, timeout: 2) == "second")
    }

    @Test func `stopping removes the socket`() throws {
        let server = try LineServer(path: path) { $0 }
        server.stop()
        Thread.sleep(forTimeInterval: 0.05)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: SocketError.unreachable(path)) { try requestLine("ping", path: path, timeout: 1) }
    }

    @Test func `a slow client does not block another`() throws {
        let server = try LineServer(path: path) { $0 }
        defer { server.stop() }
        let idle = try connectSocket(path)
        defer { close(idle) }
        try writeAll(idle, "no newline yet")
        let start = Date()
        #expect(try requestLine("fast", path: path, timeout: 2) == "fast")
        #expect(Date().timeIntervalSince(start) < 1)
    }

    @Test func `a client that hangs up before the reply does not kill the server`() throws {
        let server = try LineServer(path: path) { line in
            Thread.sleep(forTimeInterval: 0.1)
            return String(repeating: line, count: 200_000)
        }
        defer { server.stop() }
        for _ in 0..<5 {
            let fd = try connectSocket(path)
            try writeAll(fd, "x\n")
            close(fd)
        }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(try requestLine("y", path: path, timeout: 2).count == 200_000)
    }

    @Test func `garbage closes only that connection`() throws {
        let server = try LineServer(path: path) { "echo:" + $0 }
        defer { server.stop() }
        for garbage: [UInt8] in [[0xFF, 0xFE, 10], [UInt8](repeating: 65, count: maxMessageBytes + 10), [0, 0, 0, 10]] {
            let fd = try connectSocket(path)
            var rest = garbage[...]
            while !rest.isEmpty {
                let sent = rest.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
                guard sent > 0 else { break }
                rest = rest.dropFirst(sent)
            }
            close(fd)
        }
        #expect(try requestLine("ping", path: path, timeout: 2) == "echo:ping")
    }

    @Test func `many concurrent clients all get their own reply`() throws {
        let server = try LineServer(path: path) { "echo:" + $0 }
        defer { server.stop() }
        let replies = Replies()
        DispatchQueue.concurrentPerform(iterations: 300) { index in
            replies.add(index, (try? requestLine("\(index)", path: path, timeout: 5)) ?? "failed")
        }
        #expect(replies.all == Dictionary(uniqueKeysWithValues: (0..<300).map { ($0, "echo:\($0)") }))
    }

    @Test func `idle clients beyond the thread pool do not block A request`() throws {
        let server = try LineServer(path: path) { $0 }
        defer { server.stop() }
        let idle = try (0..<maxClients - 1).map { _ in try connectSocket(path) }
        defer { for fd in idle {
            close(fd)
        } }
        Thread.sleep(forTimeInterval: 0.2)
        let start = Date()
        #expect(try requestLine("fast", path: path, timeout: 4) == "fast")
        #expect(Date().timeIntervalSince(start) < 1)
    }
}

private final class Replies: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Int: String] = [:]

    func add(_ index: Int, _ reply: String) {
        lock.withLock { replies[index] = reply }
    }

    var all: [Int: String] {
        lock.withLock { replies }
    }
}
