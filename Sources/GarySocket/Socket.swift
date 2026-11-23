import Foundation

public enum SocketError: Error, Equatable, CustomStringConvertible {
    case unreachable(String)
    case timedOut
    case tooLarge
    case closed
    case invalidUTF8
    case system(Int32)

    public var description: String {
        switch self {
        case let .unreachable(path): "nothing is listening on \(path)"
        case .timedOut: "socket timed out"
        case .tooLarge: "message exceeds \(maxMessageBytes) bytes"
        case .closed: "connection closed before a full line"
        case .invalidUTF8: "message is not valid UTF-8"
        case let .system(code): "socket: \(String(cString: strerror(code)))"
        }
    }
}

public let maxMessageBytes = 1 << 20
public let maxClients = 128

public struct LineBuffer {
    private var pending: [UInt8]

    public init() {
        pending = []
    }

    public mutating func append(_ bytes: some Sequence<UInt8>) throws -> [String] {
        var unscanned = pending.count
        pending.append(contentsOf: bytes)
        var lines: [String] = []
        while let newline = pending[unscanned...].firstIndex(of: 10) {
            guard let line = String(bytes: pending[..<newline], encoding: .utf8) else { throw SocketError.invalidUTF8 }
            lines.append(line)
            pending.removeSubrange(...newline)
            unscanned = 0
        }
        guard pending.count <= maxMessageBytes else { throw SocketError.tooLarge }
        return lines
    }
}

public final class LineServer {
    private let source: DispatchSourceRead
    private let path: String

    @preconcurrency
    public init(path: String, handle: @escaping @Sendable (String) -> String) throws {
        self.path = path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system(errno) }
        guard withAddress(path, { bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {
            let code = errno
            close(fd)
            throw SocketError.system(code)
        }
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "gary.socket.accept"))
        let clients = ClientCount()
        source.setEventHandler { [weak source] in
            guard let source else { return }
            for _ in 0..<max(1, source.data) {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                guard clients.enter() else {
                    close(client)
                    continue
                }
                let thread = Thread {
                    serve(client, handle)
                    clients.leave()
                }
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    public func stop() {
        unlink(path)
        source.cancel()
    }
}

private final class ClientCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func enter() -> Bool {
        lock.withLock {
            guard count < maxClients else { return false }
            count += 1
            return true
        }
    }

    func leave() {
        lock.withLock { count -= 1 }
    }
}

private func serve(_ client: Int32, _ handle: (String) -> String) {
    defer { close(client) }
    setTimeouts(client, seconds: 5)
    var buffer = LineBuffer()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = recv(client, &chunk, chunk.count, 0)
        if count < 0, errno == EINTR {
            continue
        }
        guard count > 0, let lines = try? buffer.append(chunk[..<count]) else { return }
        for line in lines where !line.isEmpty {
            guard (try? writeAll(client, handle(line) + "\n")) != nil else { return }
        }
    }
}

public func requestLine(_ line: String, path: String, timeout: TimeInterval) throws -> String {
    let fd = try connectSocket(path)
    defer { close(fd) }
    setTimeouts(fd, seconds: timeout)
    try writeAll(fd, line + "\n")
    var buffer = LineBuffer()
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = recv(fd, &chunk, chunk.count, 0)
        if count < 0, errno == EINTR {
            continue
        }
        if count < 0 {
            throw errno == EAGAIN ? SocketError.timedOut : SocketError.system(errno)
        }
        guard count > 0 else { throw SocketError.closed }
        if let reply = try buffer.append(chunk[..<count]).first {
            return reply
        }
    }
}

func connectSocket(_ path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.system(errno) }
    var enabled: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    guard withAddress(path, { connect(fd, $0, $1) }) == 0 else {
        close(fd)
        throw SocketError.unreachable(path)
    }
    return fd
}

func writeAll(_ fd: Int32, _ string: String) throws {
    var bytes = Array(string.utf8)[...]
    while !bytes.isEmpty {
        let count = bytes.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, MSG_NOSIGNAL) }
        if count < 0, errno == EINTR {
            continue
        }
        guard count > 0 else { throw errno == EAGAIN ? SocketError.timedOut : SocketError.system(errno) }
        bytes = bytes.dropFirst(count)
    }
}

private func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
    var time = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
}

private func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path), !bytes.contains(0) else {
        errno = ENAMETOOLONG
        return -1
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
