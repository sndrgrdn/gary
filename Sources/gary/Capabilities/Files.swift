import Foundation
import GaryCore
@preconcurrency import JavaScriptCore

nonisolated extension Capability {
    static let files = Capability(
        name: "files",
        summary: """
        Read, write, list, remove, watch, and lock files. A path that does not start with `/` or `~` is relative to the plugin folder. \
        `host.mkdir(path)` creates the folder and any missing parents, and returns true when this call created the folder and false when \
        it already existed, so when two processes race to create the same folder, exactly one gets true. \
        Each `host.list` entry has `modified`, the time of the entry's last change in milliseconds since 1970. \
        `host.watchFile(path, callback)` calls `callback` with the file's text, or null when the file is gone, each time the text \
        changes, also when the file is created after the call or deleted and created again, until `stop()` or the plugin stops. \
        `host.lockFile(path)` takes an exclusive `flock` lock on the file, creating it when missing and leaving its contents alone, \
        and resolves once it holds the lock, so another process or plugin that locks the same file waits until `release()`. \
        It waits up to 10 seconds, then rejects with `host.lockFile: <path> is locked by another process`. Gary releases every lock when the plugin stops. \
        In `gary:effect`, `host.lockFile(path)` holds the lock until its scope closes.
        """,
        types: """
        declare namespace Gary {
          interface Host {
            readFile(path: string): string;
            writeFile(path: string, text: string): null;
            mkdir(path: string): boolean;
            remove(path: string): boolean;
            list(path: string): FileEntry[];
            watchFile(path: string, callback: (text: string | null) => void): WatchFileApi;
            lockFile(path: string): Promise<LockFileApi>;
          }
          interface WatchFileApi { stop(): void }
          interface LockFileApi { release(): void }
          type FileEntry = { name: string; type: "file" | "directory" | "link" | "other"; size: number; modified: number }
        }
        """,
        example: """
        const path = "~/Documents/scratch.txt";
        const placeholder = host.readFile("placeholder.txt").trim();
        let text = "";
        host.watchFile(path, (contents) => {
          text = contents ?? "";
        });

        export default {
          render() {
            return { type: "input", value: text, placeholder, submit: "save" };
          },
          onAction(action, payload) {
            if (action === "save" && typeof payload === "string") host.writeFile(path, payload);
          },
        } satisfies Gary.Menu;
        """,
        install: { host, plugin in
            let folder = plugin.bundle.directory.path
            plugin.installAPI(host, nil, FilesRequest.methods) { call in try .now(perform(FilesRequest.parse(call, home: home, folder: folder))) }
            let queue = plugin.queue
            plugin.installHandle(host, "watchFile") { [weak plugin] call, arguments in
                let path = try call.path(0, home: home, folder: folder)
                let callback = try call.function(1, "callback", in: arguments)
                let watch = FileWatch(path, queue: queue) { text in
                    plugin?.assumeIsolated { $0.callBack(callback, [text ?? NSNull()], Trace("file")) }
                }
                return HostHandle(stop: watch.stop)
            }
            installLockFile(host, plugin, folder: folder)
        },
    )
}

private func installLockFile(_ host: JSValue, _ plugin: isolated PluginRuntime, folder: String) {
    let queue = plugin.queue
    let startTimer = plugin.startTimer
    plugin.installHandle(host, "lockFile", stop: "release") { [weak plugin] call, arguments in
        let path = try call.path(0, home: home, folder: folder)
        let context: JSContext = arguments.context
        var settle: (resolve: JSValue, reject: JSValue)?
        let ready = JSValue(newPromiseIn: context) { resolve, reject in
            if let resolve, let reject {
                settle = (resolve, reject)
            }
        }
        let lock = FileLock(path) { failure in
            guard let settle else { return }
            plugin?.assumeIsolated { runtime in
                if let failure {
                    runtime.callBack(settle.reject, [context.newError("\(call.name): \(failure)")], Trace("lockFile"))
                } else {
                    runtime.callBack(settle.resolve, [], Trace("lockFile"))
                }
            }
        }
        queue.async { lock.take(queue: queue, startTimer: startTimer) }
        return HostHandle(stop: lock.release, ready: ready)
    }
}

private nonisolated func perform(_ request: FilesRequest) throws -> JSON {
    let files = FileManager.default
    do {
        switch request {
        case let .read(path):
            return try .string(String(contentsOfFile: path, encoding: .utf8))
        case let .write(path, text):
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        case let .makeDirectory(path):
            try files.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard mkdir(path, 0o777) != 0 else { return .bool(true) }
            let code = errno
            var isFolder: ObjCBool = false
            guard code == EEXIST, files.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue else {
                throw HostFailure("\(path): \(String(cString: strerror(code)))")
            }
            return .bool(false)
        case let .remove(path):
            guard (try? files.attributesOfItem(atPath: path)) != nil else { return .bool(false) }
            try files.removeItem(atPath: path)
            return .bool(true)
        case let .list(path):
            return try .array(files.contentsOfDirectory(atPath: path).sorted().map { name in
                let attributes = try? files.attributesOfItem(atPath: path + "/" + name)
                let type = attributes?[.type] as? FileAttributeType
                return .object([
                    "name": .string(name),
                    "type": .string(type == .typeDirectory ? "directory" : type == .typeSymbolicLink ? "link" : type == .typeRegular ? "file" :
                        "other"),
                    "size": .number(Double(attributes?[.size] as? Int ?? 0)),
                    "modified": .number((((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000).rounded(.down)),
                ])
            })
        }
    } catch let error as HostFailure {
        throw error
    } catch {
        throw HostFailure(error.localizedDescription)
    }
    return .null
}

private final nonisolated class FileWatch: @unchecked Sendable {
    private let path: String
    private let changed: (String?) -> Void
    private var text: String?
    private var watch: PathWatch?

    init(_ path: String, queue: DispatchQueue, changed: @escaping (String?) -> Void) {
        self.path = path
        self.changed = changed
        text = try? String(contentsOfFile: path, encoding: .utf8)
        watch = PathWatch([path, (path as NSString).deletingLastPathComponent], queue: queue) { [weak self] in self?.check() }
    }

    func stop() {
        watch?.stop()
        watch = nil
    }

    private func check() {
        let now = try? String(contentsOfFile: path, encoding: .utf8)
        guard watch != nil, now != text else { return }
        text = now
        changed(now)
    }
}

private final nonisolated class FileLock: @unchecked Sendable {
    private static let interval = 0.05
    private static let retries = 200
    private let path: String
    private var settle: ((String?) -> Void)?
    private var descriptor: Int32 = -1
    private var retried = 0
    private var stopRetrying: (@Sendable () -> Void)?

    init(_ path: String, settle: @escaping (String?) -> Void) {
        self.path = path
        self.settle = settle
    }

    func take(queue: DispatchQueue, startTimer: StartTimer) {
        guard attempt() else { return }
        stopRetrying = startTimer(Self.interval, true, queue) { [weak self] in self?.attempt() }
    }

    func release() {
        finish()
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    @discardableResult
    private func attempt() -> Bool {
        guard settle != nil else { return false }
        if descriptor < 0 {
            descriptor = open(path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else { return fail("\(path): \(String(cString: strerror(errno)))") }
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) != 0 else {
            guard isCurrent else {
                close(descriptor)
                descriptor = -1
                return attempt()
            }
            finish()?(nil)
            return false
        }
        guard errno == EWOULDBLOCK else { return fail("\(path): \(String(cString: strerror(errno)))") }
        retried += 1
        guard retried <= Self.retries else { return fail("\(path) is locked by another process") }
        return true
    }

    private var isCurrent: Bool {
        var held = stat()
        var named = stat()
        return fstat(descriptor, &held) == 0 && stat(path, &named) == 0 && held.st_dev == named.st_dev && held.st_ino == named.st_ino
    }

    private func fail(_ reason: String) -> Bool {
        let settle = settle
        release()
        settle?(reason)
        return false
    }

    @discardableResult
    private func finish() -> ((String?) -> Void)? {
        let settle = settle
        self.settle = nil
        stopRetrying?()
        stopRetrying = nil
        return settle
    }
}
